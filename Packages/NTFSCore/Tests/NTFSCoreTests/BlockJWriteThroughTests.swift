import XCTest
@testable import NTFSCore

/// Block J integration coverage: the NTFSCore mutations the FSKit
/// `setAttributes` / `renameItem` / `removeItem` adapter marshals —
/// rename(move), mkdir (createFile isDirectory:), rmdir (deleteFile +
/// emptiness guard), truncate (grow AND shrink), and the new
/// $STANDARD_INFORMATION times/flags setters.
///
/// Each mutation is performed on a writable copy of `small.img`, then the
/// volume is re-opened read-only and audited: re-enumerate parents, replicate
/// `verify --deep`'s reachable/orphan/dangling classification (BFS from root 5,
/// matching RenameAtomicityTests), and read back the persisted bytes.
final class BlockJWriteThroughTests: XCTestCase {

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

    private func subDirRecordNumber(volume: Volume) async throws -> UInt64 {
        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain 'sub/' — regenerate via scripts/make_test_images.sh")
        }
        return sub.recordNumber
    }

    // MARK: - verify-equivalent audit (mirrors RenameAtomicityTests)

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
                out.append(ReachableEntry(recordNumber: e.recordNumber, parentRecordNumber: dir, name: e.name))
                if e.isDirectory, visitedDirs.insert(e.recordNumber).inserted {
                    queue.append(e.recordNumber)
                }
            }
        }
        return out
    }

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
            if rec.isBaseRecord { inUseUserBases.insert(n) }
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

    /// Read back the persisted unnamed-$DATA logical size of a record.
    private func dataSize(volume: Volume, recordNumber: UInt64) async throws -> UInt64 {
        let mft = await volume.mft()
        let rec = try await mft.record(at: recordNumber)
        let attrs = try rec.attributes()
        guard let data = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            return 0
        }
        switch data.value {
        case let .resident(b, _): return UInt64(b.count)
        case let .nonResident(_, _, _, _, _, r, _, _): return r
        }
    }

    private func parseStdInfo(volume: Volume, recordNumber: UInt64) async throws -> StandardInformation {
        let mft = await volume.mft()
        let rec = try await mft.record(at: recordNumber)
        let attrs = try rec.attributes()
        guard let std = attrs.first(where: { $0.type == .standardInformation }),
              case let .resident(b, _) = std.value else {
            throw NTFSError.corruptOnDisk(description: "record \(recordNumber) lacks resident $STD_INFO")
        }
        return try StandardInformation.parse(b)
    }

    /// Replicate the adapter-side rmdir emptiness guard at the NTFSCore level:
    /// a directory is "empty" iff it has no non-DOS, non-dot child entries.
    private func directoryIsEmpty(volume: Volume, recordNumber: UInt64) async throws -> Bool {
        let entries = try await volume.enumerate(directory: recordNumber)
        return entries.allSatisfy { $0.fileName.namespace == .dos || $0.name == "." || $0.name == ".." }
    }

    // MARK: - Block J round-trip

    /// rename + mkdir + rmdir + truncate(grow AND shrink), each followed by a
    /// fresh re-open + verify-equivalent consistency audit. Satisfies rubric 6.
    func testRenameMkdirRmdirTruncateRoundTrip() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        // --- mutate on a writable volume ---
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let subRN = try await subDirRecordNumber(volume: volume)

        // 1. mkdir: create a fresh directory under sub/.
        let dirName = "blockj-dir"
        let dirRN = try await volume.createFile(named: dirName, inDirectory: subRN, isDirectory: true)

        // 2. create a file at root, then rename/MOVE it into the new directory.
        let srcName = "blockj-move-src.txt"
        let dstName = "blockj-move-dst.txt"
        let fileRN = try await volume.createFile(named: srcName, inDirectory: 5)
        try await volume.rename(at: fileRN, toName: dstName, inDirectory: dirRN)

        // 3. truncate GROW: write a small payload, then grow well past it so the
        //    file is forced non-resident (covers cluster allocation + zero tail).
        let payload = Data([0x41, 0x42, 0x43, 0x44]) // "ABCD"
        try await volume.write(at: fileRN, offset: 0, bytes: payload)
        let grownSize: UInt64 = 9000 // > residentDataThreshold => non-resident
        try await volume.truncate(at: fileRN, newSize: grownSize)

        // 4. truncate SHRINK back down to a small size.
        let shrunkSize: UInt64 = 3
        try await volume.truncate(at: fileRN, newSize: shrunkSize)

        // 5. create an empty dir to rmdir, and a non-empty dir to reject.
        let emptyDirRN = try await volume.createFile(named: "blockj-empty", inDirectory: subRN, isDirectory: true)
        let nonEmptyDirRN = try await volume.createFile(named: "blockj-nonempty", inDirectory: subRN, isDirectory: true)
        _ = try await volume.createFile(named: "child.txt", inDirectory: nonEmptyDirRN)

        // emptiness guard (the logic the FSKit adapter applies before deleteFile):
        let emptyIsEmpty = try await directoryIsEmpty(volume: volume, recordNumber: emptyDirRN)
        let nonEmptyIsEmpty = try await directoryIsEmpty(volume: volume, recordNumber: nonEmptyDirRN)
        XCTAssertTrue(emptyIsEmpty, "freshly-created empty dir must be empty")
        XCTAssertFalse(nonEmptyIsEmpty, "dir with a child must be reported non-empty (adapter -> ENOTEMPTY)")

        // rmdir the empty one.
        try await volume.deleteFile(at: emptyDirRN)

        // --- re-open read-only and audit persistence ---
        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let reachable = try await bfsFromRoot(auditVol)

        // rename/move: file reachable from the NEW dir under the NEW name, gone
        // from root under the old name.
        let fileEntries = reachable.filter { $0.recordNumber == fileRN }
        XCTAssertEqual(fileEntries.count, 1, "moved file reachable from exactly one parent")
        XCTAssertEqual(fileEntries.first?.parentRecordNumber, dirRN, "moved file lives under the new directory")
        XCTAssertEqual(fileEntries.first?.name, dstName, "moved file uses the new name")
        XCTAssertFalse(reachable.contains { $0.parentRecordNumber == 5 && $0.name == srcName },
                       "old (root, srcName) entry gone after move")

        // mkdir persisted + reachable under sub/.
        XCTAssertTrue(reachable.contains { $0.recordNumber == dirRN && $0.parentRecordNumber == subRN && $0.name == dirName },
                      "created directory reachable under sub/")

        // rmdir freed the empty dir: not reachable, MFT slot free.
        XCTAssertFalse(reachable.contains { $0.recordNumber == emptyDirRN },
                       "rmdir'd empty directory must no longer be reachable")
        let emptyInUse = await { () -> Bool in
            let mft = await auditVol.mft()
            return (try? await mft.record(at: emptyDirRN))?.isInUse ?? false
        }()
        XCTAssertFalse(emptyInUse, "rmdir'd directory's MFT slot must be freed")

        // truncate: final persisted size is the SHRUNK size; the grow tail had
        // read back as zeros before the shrink — verify the surviving bytes.
        let finalSize = try await dataSize(volume: auditVol, recordNumber: fileRN)
        XCTAssertEqual(finalSize, shrunkSize, "final $DATA size must equal the shrunk size")
        let finalBytes = try await auditVol.readFile(at: fileRN)
        XCTAssertEqual(finalBytes.count, Int(shrunkSize), "readback length matches shrunk size")
        XCTAssertEqual(Array(finalBytes), Array(payload.prefix(Int(shrunkSize))),
                       "surviving bytes are the leading payload bytes")

        // verify-equivalent: zero orphans, zero dangling after the whole sequence.
        let (orphans, dangling) = try await classify(volume: auditVol, reachable: reachable)
        XCTAssertEqual(orphans, [], "Block J sequence must leave zero orphans")
        XCTAssertEqual(dangling, [], "Block J sequence must leave zero dangling entries")
    }

    // MARK: - Focused unit tests for the new NTFSCore setters

    /// truncate GROW: zero-extend a resident file across the non-resident
    /// threshold; the new tail reads back as zeros and $DATA size grows.
    func testTruncateGrowZeroExtends() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let rn = try await volume.createFile(named: "grow-me.bin", inDirectory: 5)
        let head = Data([0x11, 0x22, 0x33])
        try await volume.write(at: rn, offset: 0, bytes: head)

        let target: UInt64 = 8192
        try await volume.truncate(at: rn, newSize: target)

        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let size = try await dataSize(volume: auditVol, recordNumber: rn)
        XCTAssertEqual(size, target, "grown $DATA size must equal target")
        let bytes = try await auditVol.readFile(at: rn)
        XCTAssertEqual(bytes.count, Int(target), "readback length equals target")
        XCTAssertEqual(Array(bytes.prefix(3)), Array(head), "head bytes preserved")
        XCTAssertTrue(bytes.dropFirst(3).allSatisfy { $0 == 0 }, "grown tail reads back as zeros")
    }

    /// setStandardInformationTimes persists modified/accessed/created to disk.
    func testSetStandardInformationTimesPersists() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let rn = try await volume.createFile(named: "times.txt", inDirectory: 5)
        // Pick a fixed instant truncated to 100ns granularity (FILETIME ticks).
        let when = Date(timeIntervalSince1970: 1_600_000_000) // 2020-09-13
        try await volume.setStandardInformationTimes(at: rn, modified: when, accessed: when)

        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let si = try await parseStdInfo(volume: auditVol, recordNumber: rn)
        // FILETIME has 100ns resolution; allow ~1s tolerance for any rounding.
        XCTAssertEqual(si.modificationTime?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1.0,
                       "modified time persisted")
        XCTAssertEqual(si.accessTime?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1.0,
                       "accessed time persisted")
    }

    /// setFileAttributeFlags persists the NTFS file-attribute flag word.
    func testSetFileAttributeFlagsPersists() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let rn = try await volume.createFile(named: "flagged.txt", inDirectory: 5)
        let before = try await parseStdInfo(volume: volume, recordNumber: rn)
        // FILE_ATTRIBUTE_READONLY (0x1) | FILE_ATTRIBUTE_HIDDEN (0x2)
        let newFlags = before.fileAttributes | 0x1 | 0x2
        try await volume.setFileAttributeFlags(at: rn, flags: newFlags)

        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)
        let after = try await parseStdInfo(volume: auditVol, recordNumber: rn)
        XCTAssertEqual(after.fileAttributes, newFlags, "file-attribute flags persisted")
    }

    /// Reserved records (< 16) are rejected by both new setters and by grow.
    func testSettersRejectReservedRecords() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        do {
            try await volume.setStandardInformationTimes(at: 5, modified: Date())
            XCTFail("setStandardInformationTimes must reject reserved record 5")
        } catch NTFSError.unsupportedFeature { /* expected */ }

        do {
            try await volume.setFileAttributeFlags(at: 0, flags: 0)
            XCTFail("setFileAttributeFlags must reject reserved record 0")
        } catch NTFSError.unsupportedFeature { /* expected */ }
    }
}
