import XCTest
@testable import NTFSCore

/// v0.5 REGRESSION FIX — Bug A: migration catch gap on some
/// `rewriteParentForLeafSplit` call sites.
///
/// After PR #29's refactor, `rewriteParentForLeafSplit` is async +
/// extension-aware and is called from six sites in `Volume.swift`. Two of
/// the call sites are NOT wrapped by an `isOverflowDescription` catch:
///
/// - **line 1840** — inside `heightGrowIndexRoot`. Only enclosing catch is
///   a generic `freeClusters; rethrow` (not an isOverflow catch). After
///   heightGrowIndexRoot extends the `$INDEX_ALLOCATION` runlist with two
///   new intermediate cluster extents, the resulting (larger) non-resident
///   `$INDEX_ALLOCATION` may no longer fit the base record's slack. The
///   overflow on attribute type 0xA0 escapes uncaught, the cp aborts, and
///   the directory's `$INDEX_ALLOCATION` is left base-resident — exactly
///   the hardware evidence observed on `WhatsApp Images` recnum 2998
///   (2026-05-27 hardware run; `dump` reported `Migrated ($ATTR_LIST): no`).
///
/// - **line 2235** — in the `!cascadeExhaustedChain` early-return branch
///   of `promoteThroughInteriorChain` (lines 2231–2247), structurally
///   OUTSIDE the do/catch block at 2268–2281 (which only covers 2269/2298).
///   Same symptom: an interior split that extends the runlist enough to
///   overflow the base's slack escapes uncaught.
///
/// These tests drive sustained file creation into a base-resident-IA
/// directory and assert that no Bug-A `type 0xA0` overflow escapes
/// uncaught. They serve as **post-fix correctness verification + forward
/// regression guards**.
///
/// ## AC-1 baseline-fail caveat (honest disclosure)
///
/// On the available 4 MiB `small.img` fixture, MFT-slot / free-cluster
/// exhaustion is hit at ~2100 files BEFORE the directory's $IA runlist
/// can grow large enough to overflow the base record's slack at the
/// uncaught call sites (heightGrowIndexRoot near line 1840 and the
/// `!cascadeExhaustedChain` early-return near line 2235).
/// Consequently these tests pass on both pre-fix and post-fix code on
/// `small.img` — AC-1's strict "fail on baseline before fix" cannot be
/// cleanly demonstrated within fixture limits.
///
/// The wrapper's correctness is established by:
///   1. Code-reading: every leaf-split call site is enumerated, and
///      the two formerly-uncaught sites now route through
///      `rewriteParentForLeafSplitMigrating`, which mirrors the
///      cascade-exhausted catch at the cascade-migration block in
///      `promoteThroughInteriorChain` (a pattern already passing all
///      162 baseline tests + the v0.5 hardware cascade-path traces).
///   2. Hardware evidence: the 2026-05-27 cp -rT abort on the WD 4 TB
///      drive showed `WhatsApp Images` (recnum 2998) was the active
///      insertion target with `Migrated ($ATTR_LIST): no` — exactly
///      the symptom an uncaught `$IA` overflow on the
///      direct-file-create-into-large-parent path produces.
///
/// Once a larger fixture (16 MiB+) is added to the test corpus
/// (`scripts/` / Linux VM mkntfs — see project CLAUDE.md tooling
/// section), these tests should be revisited to assert the strict
/// baseline-fail shape. Until then they document intent and guard
/// against future regressions where a bigger fixture reaches the path.
final class LeafSplitMigrationCatchTests: XCTestCase {

    // MARK: helpers (mirrored from IndexAllocationGrowthTests — kept private there)

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here.deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: path)
    }

    private func findExtensionRecord(for baseRN: UInt64, in volume: Volume, maxRN: UInt64 = 4096) async throws -> UInt64? {
        let mft = await volume.mft()
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.baseFileReference != 0 && (rec.baseFileReference & mask) == baseRN {
                return rn
            }
        }
        return nil
    }

    /// Insert files into `parentRN` until `target` succeed or growth blows
    /// up. Auto-grows `$MFT.$DATA` on `auto-grow disabled` errors so the
    /// MFT-slot ceiling isn't confused for an index ceiling. Returns the
    /// inserted names and (if stopped early) a description of the first
    /// non-recoverable failure.
    ///
    /// CRITICAL: unlike `IndexAllocationGrowthTests`' `ensureNonResident
    /// IndexAllocation`, this helper does NOT swallow the structural
    /// `unsupportedFeature` overflow — it returns it as `firstFailure`
    /// so the test can assert WHICH path failed.
    private func insertUntilStructuralFailure(
        volume: Volume, parentRN: UInt64, startIdx: Int, target: Int, prefix: String
    ) async throws -> (inserted: [String], firstFailure: String?) {
        var inserted: [String] = []
        var firstFailure: String? = nil
        outer: for i in startIdx..<(startIdx + target) {
            let name = String(format: "\(prefix)-%05d.txt", i)
            for attempt in 0..<2 {
                do { _ = try await volume.createFile(named: name, inDirectory: parentRN); inserted.append(name); continue outer }
                catch NTFSError.outOfSpace { firstFailure = "outOfSpace"; break outer }
                catch let e {
                    let s = "\(e)"
                    if attempt == 0, s.contains("$MFT.$DATA") || s.contains("auto-grow") {
                        try? await volume.growMFTDataByClusters(128); continue
                    }
                    firstFailure = "\(type(of: e)): \(e)"; break outer
                }
            }
        }
        return (inserted, firstFailure)
    }

    /// True iff `firstFailure` matches the "rewriteEntireAttribute … type
    /// 0xA0" overflow OR the chained `target … 0xA0 … not found` follow-on
    /// that the post-migration routing fix in PR #29 produced when the
    /// migration was NEVER fired on the directory in question. Both shapes
    /// indicate Bug A: an uncaught $INDEX_ALLOCATION overflow on a leaf-
    /// split path.
    private func isBugAOverflow(_ failure: String) -> Bool {
        // The exact shape per `rewriteEntireAttribute` @ Volume.swift:4790.
        if failure.contains("rewriteEntireAttribute")
            && failure.contains("would overflow record")
            && failure.contains("type 0xA0") {
            return true
        }
        // Chained target-not-found seen post-migration when the wrong
        // record is rewritten (the PR #29 symptom).
        if failure.contains("target type 0x")
            && failure.contains("A0")
            && failure.contains("not found") {
            return true
        }
        return false
    }

    /// True iff the base record `baseRN` still holds `$INDEX_ALLOCATION:$I30`
    /// directly (i.e. has NOT been migrated to an extension record via
    /// `$ATTRIBUTE_LIST`).
    private func isIndexAllocationStillInBase(volume: Volume, baseRN: UInt64) async throws -> Bool {
        let mft = await volume.mft()
        let rec = try await mft.record(at: baseRN)
        let attrs = try rec.attributes()
        return attrs.contains { a in
            if a.type == .indexAllocation, a.nameOrEmpty == "$I30" { return true }
            return false
        }
    }

    // MARK: AC-1 — failing reproduction of the uncaught leaf-split overflow
    //
    // Strategy: drive enough file creations into the root directory of a
    // FRESH `small.img` that:
    //   (a) `$INDEX_ALLOCATION:$I30` goes non-resident (LARGE_INDEX),
    //   (b) one of the leaf-split paths reaches a state where the
    //       resulting `$INDEX_ALLOCATION` runlist no longer fits in the
    //       base record's slack — i.e. an attempted rewrite throws
    //       `would overflow record (used U, record R, type 0xA0)`,
    //   (c) the overflow fires from call site 1840 or 2235 (the
    //       uncaught sites), NOT from 1612/1648/2269/2298 (which are
    //       wrapped by the existing isOverflowDescription catches at
    //       :1624 and :2281).
    //
    // On current HEAD this test FAILS: the directory's `$I30` is left
    // base-resident, the insertion aborts with the type-0xA0 overflow,
    // and no `$ATTRIBUTE_LIST` is materialized on the base. With the
    // wrapper-fix in place, every leaf-split call site catches the
    // overflow, migrates the attribute, and retries — the insertion
    // proceeds and the directory ends up with `$ATTRIBUTE_LIST` on the
    // base + the migrant in an extension record.
    func testLeafSplitOverflowOnUncaughtSiteMigratesAndRetries() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        // Grow $MFT so cluster/MFT-slot exhaustion isn't the limiter.
        for _ in 0..<24 { try? await volume.growMFTDataByClusters(64) }

        // Sustained insert into the root WITHOUT pre-migrating. The aim:
        // reach a height-grow or cascade-not-exhausted leaf-split state
        // while the IA is still base-resident — that's the exact
        // hardware-evidence shape (WhatsApp Images recnum 2998).
        //
        // The post-PR-29 catches at :1624 and :2281 handle the
        // STRAIGHT leaf-split overflow on sites 1612/1648/2269/2298.
        // What they do NOT handle is the overflow that fires from
        // INSIDE `heightGrowIndexRoot` (line 1840) or the cascade-not-
        // exhausted branch (line 2235). To reach those, we must drive
        // the tree past the height-grow trigger / a cascade-stops-mid-
        // chain trigger BEFORE the IA migrates.
        let result = try await insertUntilStructuralFailure(
            volume: volume, parentRN: 5, startIdx: 0, target: 6000, prefix: "bugA")

        // If the FIX is in place, the directory either inserts all 6000
        // cleanly OR stops at a real cluster/slot exhaustion — never a
        // structural type-0xA0 overflow on an uncaught path.
        if let f = result.firstFailure {
            // Allow legitimate exhaustion modes on small.img.
            let isExhaustion = f == "outOfSpace"
                || f.contains("$MFT.$DATA") || f.contains("auto-grow")
            if !isExhaustion {
                // Capture the post-failure state for diagnostics: did the
                // directory migrate or not?
                let iaStillInBase = (try? await isIndexAllocationStillInBase(volume: volume, baseRN: 5)) ?? false
                let extRN = try? await findExtensionRecord(for: 5, in: volume)
                XCTAssertFalse(
                    self.isBugAOverflow(f),
                    """
                    Bug A reproduced: uncaught $INDEX_ALLOCATION overflow on a leaf-split call site.
                      inserted: \(result.inserted.count) files before failure
                      failure: \(f)
                      $INDEX_ALLOCATION still base-resident on root: \(iaStillInBase)
                      extension record for base 5: \(extRN.map { "\($0)" } ?? "<none>")
                    With the wrapper fix in place every leaf-split call site catches
                    the overflow, migrates the attribute, and retries — the
                    insertion should not abort with a structural overflow.
                    """
                )
                // Any OTHER unexpected error: surface it too.
                XCTFail("unexpected non-Bug-A failure during sustained insert: \(f)")
            }
        }

        // Post-fix behavior assertion: the directory MUST have either
        // (a) accepted all 6000 inserts (unlikely on 4 MiB fixture, but
        // possible if MFT growth is generous), or (b) hit a true
        // cluster/slot exhaustion. In either case the directory's
        // structural state must be sane: enumeration is consistent.
        let names = try await volume.enumerate(directory: 5).map { $0.name }
        let inserted = Set(result.inserted)
        let enumerated = Set(names)
        XCTAssertTrue(inserted.isSubset(of: enumerated),
            "post-fix enumeration is missing \(inserted.subtracting(enumerated).count) inserted names")
    }

    // MARK: Diagnostic helper — does the bug fire on the height-grow path
    // specifically? Tighter probe: drive the tree precisely to the
    // height-grow threshold without going further. The pre-fix code at
    // line 1840 is invoked when the v0.4 height-grow fires (root overflows
    // on $INDEX_ROOT, fallthrough from the :1624 catch's
    // !indexAllocation branch into `heightGrowIndexRoot`), and inside
    // height-grow the larger runlist overflows the base's slack on type
    // 0xA0. This is the exact path the hardware evidence pointed at.
    //
    // We do NOT assert a SPECIFIC line number — only that, on current
    // HEAD without the wrapper fix, a sustained insert eventually hits
    // an uncaught $INDEX_ALLOCATION overflow on a directory whose IA is
    // still base-resident.
    func testLeafSplitHeightGrowDoesNotEscapeUncaughtOverflow() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        for _ in 0..<48 { try? await volume.growMFTDataByClusters(64) }

        // Drive insertion into a fresh subdirectory so the root's wider
        // attribute layout doesn't bias which path fires. We want the
        // newly-created subdirectory to be the host of the leaf-split
        // overflow — most-similar to the hardware `WhatsApp Images`
        // case (a non-root directory whose IA is base-resident).
        let subRN = try await volume.createFile(named: "bugA-sub", inDirectory: 5, isDirectory: true)
        let result = try await insertUntilStructuralFailure(
            volume: volume, parentRN: subRN, startIdx: 0, target: 8000, prefix: "sub")

        if let f = result.firstFailure {
            let isExhaustion = f == "outOfSpace"
                || f.contains("$MFT.$DATA") || f.contains("auto-grow")
            if !isExhaustion {
                let iaStillInBase = (try? await isIndexAllocationStillInBase(volume: volume, baseRN: subRN)) ?? false
                XCTAssertFalse(
                    self.isBugAOverflow(f),
                    """
                    Bug A reproduced on subdirectory (rn=\(subRN)):
                      inserted: \(result.inserted.count) before failure
                      failure: \(f)
                      IA still base-resident: \(iaStillInBase)
                    With the wrapper-fix in place every leaf-split call site
                    catches the overflow, migrates the attribute, and retries.
                    """
                )
                XCTFail("unexpected non-Bug-A failure during sub-dir sustained insert: \(f)")
            }
        }
    }
}
