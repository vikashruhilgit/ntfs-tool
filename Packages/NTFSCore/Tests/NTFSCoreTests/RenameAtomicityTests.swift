import XCTest
@testable import NTFSCore

/// v0.7 AUDIT-TODO(rename-i30-atomicity) regression guard.
///
/// `Volume.rename` moves a file/directory by (a) inserting a new $I30 entry
/// under the target parent, (b) rewriting the record's $FILE_NAME, and
/// (c) removing the old $I30 entry from the source parent. The fix this
/// file guards is the COMMIT ORDERING: insert-before-remove. Under the old
/// remove-then-insert ordering, a throw between the remove and the insert
/// left the file UNREACHABLE FROM BOTH parents — a silent orphan that
/// `verify --deep` flags (in-use base record not reachable from root's $I30).
///
/// `verify --deep` defines "clean" as ZERO orphans (in-use base record not
/// reachable from root's $I30 tree) and ZERO dangling entries ($I30 entry
/// pointing at a free MFT slot). It does NOT cross-check a $I30 key against
/// the target record's $FILE_NAME, so the transient "reachable from BOTH
/// parents" state insert-before-remove produces mid-flight is verify-clean.
///
/// These tests drive the `_setRenameFaultHook(.afterInsertBeforeRemove)`
/// `#if DEBUG` seam to force a throw in the dangerous window and audit the
/// resulting volume by BFS-enumerating from root (5) and replicating
/// verify's reachable/orphan/dangling classification against the MFT
/// in-use set (mirroring `Verify.swift`).
final class RenameAtomicityTests: XCTestCase {

    // MARK: - Fixture helpers

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Pull `sub/`'s MFT record number out of the fixture. `sub/` is a
    /// committed small-$I30 directory in `small.img`. Mirrors
    /// CreateFileAtomicityTests.subDirRecordNumber.
    private func subDirRecordNumber(volume: Volume) async throws -> UInt64 {
        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain 'sub/' — regenerate via scripts/make_test_images.sh")
        }
        return sub.recordNumber
    }

    // MARK: - BFS / verify-equivalent audit

    /// BFS over the directory tree from root (5) using `Volume.enumerate`.
    /// Returns, for every reachable directory entry, the (recordNumber,
    /// parentRecordNumber, name) tuple. The root itself (5) is not an entry
    /// but is always reachable. Cycle-guarded on directory record numbers.
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
                // Skip the DOS-namespace alias so each object is counted once.
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

    /// Replicate `Verify.swift`'s classification: walk the MFT up to its
    /// logical size, collect the IN_USE user base records (recnum >= 16),
    /// then compare against the set reachable from root.
    ///   orphan  := in-use user base record NOT in the reachable set
    ///   dangling := reachable entry whose record is NOT in-use in the MFT
    /// Returns (orphans, dangling). Both empty == verify-clean.
    private func classify(
        volume: Volume,
        reachable: [ReachableEntry]
    ) async throws -> (orphans: [UInt64], dangling: [UInt64]) {
        let mft = await volume.mft()

        // Infer the MFT logical record count from $MFT (record 0)'s $DATA,
        // exactly as Verify does, so we don't read past the real MFT end.
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

        // In-use USER base records (recnum >= 16). We only consider base
        // records: an extension record (BASE_FILE_RECORD != 0) is not a
        // tree-reachable object, matching Verify's base-vs-extension split.
        var inUseUserBases: Set<UInt64> = []
        for n in 16..<mftLogicalRecords {
            guard let rec = try? await mft.record(at: n) else { continue }
            guard rec.isInUse else { continue }
            // A base record (not a migration extension) is a tree-reachable
            // object — matching Verify's base-vs-extension split.
            if rec.isBaseRecord {
                inUseUserBases.insert(n)
            }
        }

        let reachableRecs = Set(reachable.map { $0.recordNumber })

        // Orphans: in-use user base record not reachable from root.
        let orphans = inUseUserBases.subtracting(reachableRecs)
            .sorted()

        // Dangling: a reachable entry (recnum >= 16) pointing at a record
        // that is NOT in-use in the MFT.
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

    private func mftRecordIsInUse(volume: Volume, recordNumber: UInt64) async throws -> Bool {
        let mft = await volume.mft()
        let rec = try await mft.record(at: recordNumber)
        return rec.isInUse
    }

    // MARK: - Tests

    /// Happy-path control (no fault hook): create a file in `sub/`, then
    /// move it to root (5) under a new name. After success a BFS from root
    /// must show: the record IS reachable, reachable from the TARGET parent
    /// (root) under the NEW name, and NOT reachable from the source parent
    /// (`sub/`) under the old name. Confirms the move completed and the
    /// fault seam never leaks into the normal flow.
    func testHappyPathMoveLeavesReachableFromTargetOnly() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let subRN = try await subDirRecordNumber(volume: volume)

        let oldName = "rename-move-src.txt"
        let newName = "rename-move-dst.txt"
        let recnum = try await volume.createFile(named: oldName, inDirectory: subRN)

        // Move sub/oldName -> /newName.
        try await volume.rename(at: recnum, toName: newName, inDirectory: 5)

        // Audit on a freshly re-opened volume.
        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let reachable = try await bfsFromRoot(auditVol)

        let entriesForRec = reachable.filter { $0.recordNumber == recnum }
        XCTAssertEqual(entriesForRec.count, 1,
                       "after a successful move the record must be reachable from exactly one parent")
        let only = try XCTUnwrap(entriesForRec.first)
        XCTAssertEqual(only.parentRecordNumber, 5,
                       "moved record must be reachable from the TARGET parent (root)")
        XCTAssertEqual(only.name, newName,
                       "moved record must appear under the NEW name")

        XCTAssertFalse(
            reachable.contains { $0.parentRecordNumber == subRN && $0.name == oldName },
            "old (sourceParent, oldName) entry must be gone after a successful move"
        )

        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [], "successful move must leave zero orphans")
        XCTAssertEqual(dangling, [], "successful move must leave zero dangling entries")
    }

    /// Happy-path SAME-DIRECTORY rename (pure name change, oldParent ==
    /// targetParent). Exercises the path where insert and remove touch the
    /// same parent's $I30.
    func testHappyPathSameDirectoryRename() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let subRN = try await subDirRecordNumber(volume: volume)

        let oldName = "same-dir-old.txt"
        let newName = "same-dir-new.txt"
        let recnum = try await volume.createFile(named: oldName, inDirectory: subRN)

        // Pure rename within sub/ (no inDirectory => oldParent == target).
        try await volume.rename(at: recnum, toName: newName)

        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let reachable = try await bfsFromRoot(auditVol)

        let entriesForRec = reachable.filter { $0.recordNumber == recnum }
        XCTAssertEqual(entriesForRec.count, 1,
                       "after a same-dir rename the record must be reachable from exactly one parent")
        let only = try XCTUnwrap(entriesForRec.first)
        XCTAssertEqual(only.parentRecordNumber, subRN, "record stays under the same parent")
        XCTAssertEqual(only.name, newName, "record appears under the new name")
        XCTAssertFalse(
            reachable.contains { $0.parentRecordNumber == subRN && $0.name == oldName },
            "old name entry must be gone after a same-dir rename"
        )

        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [], "same-dir rename must leave zero orphans")
        XCTAssertEqual(dangling, [], "same-dir rename must leave zero dangling entries")
    }

    /// Fault in the dangerous window: `_setRenameFaultHook(.afterInsertBeforeRemove)`
    /// forces a throw AFTER the new $I30 entry is committed under the target
    /// parent and the record is rewritten, but BEFORE the old entry is
    /// removed. Under INSERT-BEFORE-REMOVE the file is reachable from BOTH
    /// parents at this point — NEVER from neither.
    ///
    /// Asserts, on a freshly re-opened volume:
    ///   - the renamed record is reachable from AT LEAST one parent (it will
    ///     be reachable from both — the core "never unreachable-from-both"
    ///     guarantee),
    ///   - the record's MFT slot is still IN_USE (no dangling),
    ///   - zero orphans / zero dangling (verify-equivalent classification).
    func testFaultInDangerousWindowNeverUnreachableFromBoth() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let subRN = try await subDirRecordNumber(volume: volume)

        // Known file in a known source dir (sub/). Note its recnum.
        let oldName = "fault-move-src.txt"
        let newName = "fault-move-dst.txt"
        let recnum = try await volume.createFile(named: oldName, inDirectory: subRN)

        // Attempt the faulted move sub/oldName -> /newName.
        await volume._setRenameFaultHook(.afterInsertBeforeRemove)
        do {
            try await volume.rename(at: recnum, toName: newName, inDirectory: 5)
            XCTFail("rename must throw under afterInsertBeforeRemove fault hook")
        } catch {
            // expected — the dangerous-window throw
        }

        // Audit on a fresh device.
        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let reachable = try await bfsFromRoot(auditVol)

        // Core guarantee: the renamed record is reachable from AT LEAST one
        // parent (never unreachable-from-both). Under insert-before-remove it
        // is reachable from BOTH the target (root, new name) and the source
        // (sub/, old name) here.
        let entriesForRec = reachable.filter { $0.recordNumber == recnum }
        XCTAssertFalse(
            entriesForRec.isEmpty,
            "INVARIANT VIOLATION: after a throw in the rename dangerous window the record \(recnum) is reachable from NEITHER parent — the pre-fix remove-before-insert orphaning bug. Insert-before-remove must keep it reachable from at least one parent."
        )
        // Confirm it is the expected reachable-from-both transient state.
        XCTAssertTrue(
            reachable.contains { $0.recordNumber == recnum && $0.parentRecordNumber == 5 && $0.name == newName },
            "new (target, newName) edge should be committed before the throw"
        )
        XCTAssertTrue(
            reachable.contains { $0.recordNumber == recnum && $0.parentRecordNumber == subRN && $0.name == oldName },
            "old (source, oldName) edge should still be present (remove happens after the throw point)"
        )

        // No dangling: the record's MFT slot is still IN_USE.
        let inUse = try await mftRecordIsInUse(volume: auditVol, recordNumber: recnum)
        XCTAssertTrue(inUse, "renamed record's MFT slot must stay IN_USE (rename never frees the source record)")

        // verify-equivalent: zero orphans, zero dangling.
        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [],
                       "post-abort volume must have zero orphans (record stays reachable)")
        XCTAssertEqual(dangling, [],
                       "post-abort volume must have zero dangling entries (record stays in-use)")
    }
}
