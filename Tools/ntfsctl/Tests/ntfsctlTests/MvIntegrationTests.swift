import XCTest
import NTFSCore
@testable import ntfsctl

/// End-to-end tests of `mv` skip/replace conflict semantics through the REAL
/// CLI code path (parse + run `Mv` against a writable copy of `small.img`),
/// plus a direct-on-volume transactional-abort test for the AC-7
/// "source is never lost" guarantee.
///
/// Coverage:
///   1. default REPLACE: `/b.txt` ("NEW") moved onto `/a.txt` ("OLD") → a.txt
///      reads "NEW", b.txt gone, zero orphans / zero dangling.
///   2. `-n` SKIP: same seed, a.txt stays "OLD", b.txt still resolves, exit 0.
///   3. replace transactional ABORT (the key safety test): replicate
///      deleteFile(existing) + faulted rename on the live Volume; assert the
///      SOURCE record is still reachable and the volume is verify-clean.
///   4. replace refuses a NON-EMPTY directory destination.
final class MvIntegrationTests: XCTestCase {

    // MARK: - Fixture plumbing (mirrors CpMergeIntegrationTests)

    private func fixturePath(_ file: String = #filePath) -> String {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // ntfsctlTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ntfsctl
            .deletingLastPathComponent()  // Tools
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img")
            .path
    }

    private func mutableFixtureCopy() throws -> String {
        let source = fixturePath()
        guard FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("fixture missing at \(source); run scripts/make_test_images.sh")
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsctl-mv-\(UUID().uuidString)-small.img")
        try FileManager.default.copyItem(atPath: source, toPath: copy.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy.path
    }

    // MARK: - Seed / readback helpers

    private func childRecnum(_ volume: Volume, parent: UInt64, name: String) async throws -> UInt64? {
        let entries = try await volume.enumerate(directory: parent)
        let needle = name.lowercased()
        return entries.first {
            $0.fileName.namespace != .dos && $0.name.lowercased() == needle
        }?.recordNumber
    }

    /// Create-or-replace a regular file `name` under `parent` with `contents`.
    private func seedFile(_ volume: Volume, parent: UInt64, name: String, contents: String) async throws -> UInt64 {
        if let prior = try await childRecnum(volume, parent: parent, name: name) {
            try await volume.deleteFile(at: prior)
        }
        let rn = try await volume.createFile(named: name, inDirectory: parent, isDirectory: false)
        try await volume.write(at: rn, offset: 0, bytes: Data(contents.utf8))
        return rn
    }

    /// Seed `/a.txt`=a and `/b.txt`=b at the volume root, in a write session.
    /// Opens its own (non-exclusive) device and lets it deinit before returning
    /// so the CLI run can re-open the image cleanly.
    private func seedAB(imagePath: String, a: String, b: String) async throws {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let volume = try await Volume(device: device)
        try await volume.beginWriteSession()
        _ = try await seedFile(volume, parent: 5, name: "a.txt", contents: a)
        _ = try await seedFile(volume, parent: 5, name: "b.txt", contents: b)
        try await volume.endWriteSession()
    }

    private func readFileString(imagePath: String, path: String) async throws -> String? {
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let volume = try await Volume(device: device)
        guard let rn = try await volume.resolvePath(path) else { return nil }
        var out = Data()
        var offset: UInt64 = 0
        let chunk = 1 << 16
        while true {
            let slice = try await volume.readFileSlice(at: rn, offset: offset, length: chunk)
            if slice.isEmpty { break }
            out.append(slice)
            offset += UInt64(slice.count)
            if slice.count < chunk { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - BFS / verify-equivalent audit (copied from RenameAtomicityTests)

    private struct ReachableEntry {
        let recordNumber: UInt64
        let parentRecordNumber: UInt64
        let name: String
    }

    private func bfsFromRoot(_ volume: Volume) async throws -> [ReachableEntry] {
        var out: [ReachableEntry] = []
        var visitedDirs: Set<UInt64> = [5]
        var queue: [UInt64] = [5]
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            let entries = try await volume.enumerate(directory: dir)
            for e in entries {
                if e.fileName.namespace == .dos { continue }
                if e.name == "." || e.name == ".." { continue }
                out.append(ReachableEntry(
                    recordNumber: e.recordNumber,
                    parentRecordNumber: dir,
                    name: e.name
                ))
                if e.isDirectory, visitedDirs.insert(e.recordNumber).inserted {
                    queue.append(e.recordNumber)
                }
            }
        }
        return out
    }

    /// Replicate Verify's reachable/orphan/dangling classification.
    /// Both empty == verify-clean.
    private func classify(
        volume: Volume,
        reachable: [ReachableEntry]
    ) async throws -> (orphans: [UInt64], dangling: [UInt64]) {
        let mft = await volume.mft()

        var mftLogicalRecords: UInt64 = 4096
        if let mftRec = try? await mft.record(at: 0),
           let attrs = try? mftRec.attributes(),
           let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) {
            let realSize: UInt64
            switch dataAttr.value {
            case let .resident(b, _): realSize = UInt64(b.count)
            case let .nonResident(_, _, _, _, _, r, _, _): realSize = r
            }
            mftLogicalRecords = realSize / UInt64(volume.mftRecordSizeBytes)
        }

        var inUseUserBases: Set<UInt64> = []
        for n in 16..<mftLogicalRecords {
            guard let rec = try? await mft.record(at: n) else { continue }
            guard rec.isInUse else { continue }
            if rec.isBaseRecord {
                inUseUserBases.insert(n)
            }
        }

        let reachableRecs = Set(reachable.map { $0.recordNumber })
        let orphans = inUseUserBases.subtracting(reachableRecs).sorted()

        var dangling: [UInt64] = []
        for e in reachable where e.recordNumber >= 16 {
            guard let rec = try? await mft.record(at: e.recordNumber) else {
                dangling.append(e.recordNumber)
                continue
            }
            if !rec.isInUse { dangling.append(e.recordNumber) }
        }
        return (orphans, dangling.sorted())
    }

    // MARK: - Tests

    /// AC-6/AC-8 default REPLACE (happy): mv /b.txt onto /a.txt.
    /// a.txt becomes "NEW", b.txt gone, zero orphans / zero dangling.
    func testMvDefaultReplace() async throws {
        let imagePath = try mutableFixtureCopy()
        try await seedAB(imagePath: imagePath, a: "OLD", b: "NEW")

        let cmd = try Mv.parse([imagePath, "/b.txt", "/a.txt"])
        try await cmd.run()

        let aBytes = try await readFileString(imagePath: imagePath, path: "/a.txt")
        XCTAssertEqual(aBytes, "NEW", "default policy must REPLACE /a.txt with the moved source bytes")

        // Source name no longer resolves.
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let auditVol = try await Volume(device: device)
        let bRN = try await auditVol.resolvePath("/b.txt")
        XCTAssertNil(bRN, "source /b.txt must be gone after the move")

        let reachable = try await bfsFromRoot(auditVol)
        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [], "mv replace must leave zero orphans")
        XCTAssertEqual(dangling, [], "mv replace must leave zero dangling entries")
    }

    /// AC-6 `-n` SKIP: a.txt stays "OLD", b.txt still resolves, exit 0 (no throw).
    func testMvNoClobberSkips() async throws {
        let imagePath = try mutableFixtureCopy()
        try await seedAB(imagePath: imagePath, a: "OLD", b: "NEW")

        let cmd = try Mv.parse([imagePath, "/b.txt", "/a.txt", "-n"])
        try await cmd.run()   // must NOT throw (exit 0)

        let aBytes = try await readFileString(imagePath: imagePath, path: "/a.txt")
        XCTAssertEqual(aBytes, "OLD", "-n must SKIP: /a.txt stays 'OLD'")

        let bBytes = try await readFileString(imagePath: imagePath, path: "/b.txt")
        XCTAssertEqual(bBytes, "NEW", "-n must leave the SOURCE /b.txt intact")
    }

    /// AC-7 replace transactional ABORT — the key safety test.
    /// Replicate the mv-replace sequence directly on a live Volume with the
    /// rename fault hook armed: beginWriteSession -> deleteFile(existing) ->
    /// _setRenameFaultHook(.afterInsertBeforeRemove) -> rename (throws).
    /// On a freshly re-opened volume assert: the SOURCE record is STILL
    /// reachable (its data was not lost — reachable from at least one $I30 edge
    /// in the insert-before-remove window), and the volume is verify-clean.
    func testMvReplaceTransactionalAbortNeverLosesSource() async throws {
        let imagePath = try mutableFixtureCopy()

        // Seed source + an existing dest on a volume we keep a handle to so we
        // can reach the actor and arm the fault hook.
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath)
        let volume = try await Volume(device: device)

        let srcName = "mv-abort-src.txt"
        let destName = "mv-abort-dst.txt"
        try await volume.beginWriteSession()
        let srcRN = try await seedFile(volume, parent: 5, name: srcName, contents: "SOURCE")
        let existingDestRN = try await seedFile(volume, parent: 5, name: destName, contents: "OLDDEST")
        try await volume.endWriteSession()

        // Replicate mv-replace with the fault armed in the dangerous window.
        try await volume.beginWriteSession()
        try await volume.deleteFile(at: existingDestRN)
        await volume._setRenameFaultHook(.afterInsertBeforeRemove)
        do {
            try await volume.rename(at: srcRN, toName: destName, inDirectory: 5)
            XCTFail("rename must throw under the afterInsertBeforeRemove fault hook")
        } catch {
            // expected — the dangerous-window throw. We deliberately do NOT
            // endWriteSession (the abort leaves the volume dirty, as a crash
            // would); the audit re-opens a fresh handle.
        }

        // Audit on a freshly re-opened volume.
        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let reachable = try await bfsFromRoot(auditVol)

        // Core AC-7 guarantee: the SOURCE record is still reachable — its data
        // was NEVER lost despite the rename aborting mid-flight. Under
        // insert-before-remove the record is reachable via at least one $I30
        // edge here (both the new dest key and the old source key were
        // committed under the same parent, root). NOTE: source and dest share
        // root as their parent, and `enumerate` dedups by fileReference, so it
        // yields exactly ONE named edge for the record (whichever sorts first
        // in root's $I30 B-tree). We therefore assert reachability + that the
        // surviving name is one of {srcName, destName}, not both — both keys
        // physically exist in $I30 but enumeration collapses them. The
        // never-unreachable-from-both invariant is what matters for AC-7.
        let entriesForRec = reachable.filter { $0.recordNumber == srcRN }
        XCTAssertFalse(
            entriesForRec.isEmpty,
            "AC-7 VIOLATION: after a mid-flight rename abort the source record \(srcRN) is reachable from NEITHER parent — the source was lost. Insert-before-remove must keep it reachable."
        )
        XCTAssertTrue(
            entriesForRec.allSatisfy { $0.parentRecordNumber == 5 },
            "the surviving edge(s) must be under root (the shared parent)"
        )
        XCTAssertTrue(
            entriesForRec.allSatisfy { $0.name == srcName || $0.name == destName },
            "the surviving edge must be keyed by either the old source name or the new dest name; got \(entriesForRec.map { $0.name })"
        )

        // The source's MFT slot is still IN_USE (never freed).
        let mft = await auditVol.mft()
        let srcRec = try await mft.record(at: srcRN)
        XCTAssertTrue(srcRec.isInUse, "source record must stay IN_USE after the abort")

        // verify-equivalent: zero orphans / zero dangling.
        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [], "post-abort volume must have zero orphans")
        XCTAssertEqual(dangling, [], "post-abort volume must have zero dangling entries")
    }

    /// AC-7 safety guard: replace refuses a NON-EMPTY directory destination,
    /// leaving the dir + its child untouched.
    func testMvReplaceRefusesNonEmptyDirectory() async throws {
        let imagePath = try mutableFixtureCopy()

        // Seed a source file /mv-src.txt and an existing dest DIR /mv-dst with
        // a child, on a volume we let deinit before the CLI run.
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
            let volume = try await Volume(device: device)
            try await volume.beginWriteSession()
            _ = try await seedFile(volume, parent: 5, name: "mv-src.txt", contents: "SRC")
            let dstDirRN: UInt64
            if let existing = try await childRecnum(volume, parent: 5, name: "mv-dst") {
                dstDirRN = existing
            } else {
                dstDirRN = try await volume.createFile(named: "mv-dst", inDirectory: 5, isDirectory: true)
            }
            _ = try await seedFile(volume, parent: dstDirRN, name: "child.txt", contents: "CHILD")
            try await volume.endWriteSession()
        }

        // mv default (replace) onto the populated dir → must throw (refuse).
        let cmd = try Mv.parse([imagePath, "/mv-src.txt", "/mv-dst"])
        do {
            try await cmd.run()
            XCTFail("mv replace onto a non-empty directory must throw")
        } catch {
            // expected refusal
        }

        // Dir + child untouched; source still present.
        let childBytes = try await readFileString(imagePath: imagePath, path: "/mv-dst/child.txt")
        XCTAssertEqual(childBytes, "CHILD", "the populated dest dir's child must be untouched")
        let srcBytes = try await readFileString(imagePath: imagePath, path: "/mv-src.txt")
        XCTAssertEqual(srcBytes, "SRC", "the source must be untouched after a refused replace")
    }

    /// DATA-LOSS REGRESSION: exact self-move `mv /x.txt /x.txt` must be a clean
    /// no-op, NOT a delete-then-failed-rename that destroys the file. Without the
    /// existingRN == srcRN guard, the case-insensitive dest lookup resolves to the
    /// source itself, the .replace branch deletes it, the rename then throws
    /// "source record not in use", and /x.txt reads nil — confirmed data loss.
    func testMvExactSelfMoveIsNoOpNotDataLoss() async throws {
        let imagePath = try mutableFixtureCopy()
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
            let volume = try await Volume(device: device)
            try await volume.beginWriteSession()
            _ = try await seedFile(volume, parent: 5, name: "x.txt", contents: "DATA")
            try await volume.endWriteSession()
        }

        let cmd = try Mv.parse([imagePath, "/x.txt", "/x.txt"])
        try await cmd.run()  // must NOT throw — clean no-op

        let bytes = try await readFileString(imagePath: imagePath, path: "/x.txt")
        XCTAssertEqual(bytes, "DATA", "exact self-move must leave the source file intact (no data loss)")

        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let auditVol = try await Volume(device: device)
        let reachable = try await bfsFromRoot(auditVol)
        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [], "exact self-move must leave zero orphans")
        XCTAssertEqual(dangling, [], "exact self-move must leave zero dangling entries")
    }

    /// DATA-LOSS REGRESSION: case-only rename `mv /X.txt /x.txt` is a legitimate
    /// everyday op and must survive as a plain rename, NOT a delete of the
    /// (case-insensitively matched) source. Without the guard the source record
    /// is deleted and the rename throws → file destroyed.
    func testMvCaseOnlyRenameKeepsData() async throws {
        let imagePath = try mutableFixtureCopy()
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
            let volume = try await Volume(device: device)
            try await volume.beginWriteSession()
            _ = try await seedFile(volume, parent: 5, name: "X.txt", contents: "DATA")
            try await volume.endWriteSession()
        }

        let cmd = try Mv.parse([imagePath, "/X.txt", "/x.txt"])
        try await cmd.run()  // must NOT throw

        // File survives and resolves (case-insensitively) with its bytes intact.
        let bytes = try await readFileString(imagePath: imagePath, path: "/x.txt")
        XCTAssertEqual(bytes, "DATA", "case-only rename must keep the source bytes")

        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let auditVol = try await Volume(device: device)

        // The stored casing changed to lowercase.
        let entries = try await auditVol.enumerate(directory: 5)
        let stored = entries.first {
            $0.fileName.namespace != .dos && $0.name.lowercased() == "x.txt"
        }
        XCTAssertEqual(stored?.name, "x.txt", "case-only rename must update the stored name casing to lowercase")

        let reachable = try await bfsFromRoot(auditVol)
        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [], "case-only rename must leave zero orphans")
        XCTAssertEqual(dangling, [], "case-only rename must leave zero dangling entries")
    }

    /// Sanity: simple rename onto a NON-existent destination still works (the
    /// unchanged path). Confirms the new conflict logic didn't break the basic
    /// case.
    func testMvSimpleRenameNoConflictStillWorks() async throws {
        let imagePath = try mutableFixtureCopy()
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
            let volume = try await Volume(device: device)
            try await volume.beginWriteSession()
            _ = try await seedFile(volume, parent: 5, name: "mv-plain-src.txt", contents: "HELLO")
            try await volume.endWriteSession()
        }

        let cmd = try Mv.parse([imagePath, "/mv-plain-src.txt", "/mv-plain-dst.txt"])
        try await cmd.run()

        let dst = try await readFileString(imagePath: imagePath, path: "/mv-plain-dst.txt")
        XCTAssertEqual(dst, "HELLO", "plain rename must move bytes to the new name")
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let auditVol = try await Volume(device: device)
        let srcGone = try await auditVol.resolvePath("/mv-plain-src.txt")
        XCTAssertNil(srcGone, "source name must be gone after a plain rename")
    }
}
