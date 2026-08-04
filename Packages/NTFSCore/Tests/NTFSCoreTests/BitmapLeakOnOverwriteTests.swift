import XCTest
@testable import NTFSCore

/// Does overwriting an existing file leak its previous clusters?
///
/// Windows `chkdsk` reported "The Volume Bitmap is incorrect" on a volume
/// whose files had been copied twice (the second `cp` replacing existing
/// files). The first copy alone passed chkdsk clean. Our `verify --deep`
/// passed both, because `RunlistBitmapAudit` only checks that clusters
/// REFERENCED by files are marked allocated — it never checks the reverse,
/// that every allocated bit has an owner. A leak is invisible to it.
final class BitmapLeakOnOverwriteTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        return FileManager.default.fileExists(
            atPath: here.deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent(name).path
        )
    }

    private func write(_ volume: Volume, _ rn: UInt64, bytes total: Int, seed: UInt8) async throws {
        var payload = Data(count: total)
        for i in 0..<total { payload[i] = UInt8((i &* 13 &+ Int(seed)) & 0xFF) }
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(total)) {
            if cursor >= total { return Data() }
            let take = min(1 << 16, total - cursor)
            defer { cursor += take }
            return payload.subdata(in: cursor..<(cursor + take))
        }
    }

    /// The reverse audit must be silent on a pristine volume — otherwise it
    /// is useless as a leak detector. A `mkntfs` fixture references every
    /// allocated cluster through $Boot / $MFT / metafiles / INDX blocks, so
    /// allocated and referenced must agree exactly.
    func testReverseAuditReportsNoLeakOnPristineVolume() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )
        let audit = try await volume.auditBitmapForUnreferencedClusters()
        XCTAssertEqual(
            audit.leakedClusters, 0,
            "pristine fixture reported \(audit.leakedClusters) leaked clusters — false positive; "
            + "ranges: \(audit.largestLeakedRanges)"
        )
        XCTAssertEqual(
            audit.allocatedInBitmap, audit.referencedByAttributes,
            "every allocated cluster on a pristine volume must have an owner"
        )
        XCTAssertTrue(audit.isClean)
    }

    /// And it must actually SEE a leak — clusters allocated with no owner are
    /// exactly the state chkdsk calls "The Volume Bitmap is incorrect", and
    /// the forward audit is blind to them.
    func testReverseAuditDetectsClustersAllocatedWithNoOwner() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )

        // Allocate without attaching the clusters to any attribute — a leak
        // by construction.
        let leakSize: UInt64 = 10
        _ = try await volume.allocateClusters(leakSize)

        let audit = try await volume.auditBitmapForUnreferencedClusters()
        XCTAssertEqual(
            audit.leakedClusters, leakSize,
            "reverse audit must report exactly the \(leakSize) ownerless clusters"
        )
        XCTAssertFalse(audit.isClean, "a leaking volume must not audit clean")

        // The forward audit stays clean — documenting precisely the blind spot
        // that let a leaking volume pass verify --deep while chkdsk failed it.
        let forward = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertTrue(
            forward.isClean,
            "forward audit is expected to be blind to leaks; if it now catches them, update this test"
        )
    }

    /// Hardware leak: 2,564 contiguous clusters allocated with no owner after
    /// a corpus was copied twice, the second copy replacing files whose
    /// contents had changed *size*. Same-size overwrite is covered below and
    /// is clean, so size change is the remaining suspect.
    func testOverwritingAFileWithADifferentSizeDoesNotLeak() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )
        let cluster = Int(volume.bytesPerCluster)
        let rn = try await volume.createFile(named: "resize.bin", inDirectory: 5)

        // Grow, shrink, grow again — after each, free space must equal
        // baseline minus exactly the clusters the file currently owns.
        let baseline = try await volume.allocationStats().freeClusters
        for clusters in [20, 5, 30, 12] {
            try await self.write(volume, rn, bytes: clusters * cluster, seed: UInt8(clusters))

            let free = try await volume.allocationStats().freeClusters
            let consumed = Int64(baseline) - Int64(free)
            XCTAssertEqual(
                consumed, Int64(clusters),
                """
                after rewriting the file at \(clusters) clusters, \(consumed) clusters are \
                consumed relative to baseline — the previous allocation was not released
                """
            )

            let audit = try await volume.auditBitmapForUnreferencedClusters()
            XCTAssertEqual(
                audit.leakedClusters, 0,
                "resize to \(clusters) clusters leaked \(audit.leakedClusters); ranges: \(audit.largestLeakedRanges)"
            )
        }
    }

    /// `cp`'s replace policy is delete-then-create (Cp.swift:464), so a delete
    /// that fails to release clusters leaks exactly one file's allocation —
    /// which is the shape observed on hardware (one contiguous 2,564-cluster
    /// run, exactly one corpus file's size).
    func testDeletingAFileReleasesAllOfItsClusters() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )
        let cluster = Int(volume.bytesPerCluster)
        let baseline = try await volume.allocationStats().freeClusters

        for clusters in [1, 20, 60] {
            let rn = try await volume.createFile(named: "del-\(clusters).bin", inDirectory: 5)
            try await self.write(volume, rn, bytes: clusters * cluster, seed: UInt8(clusters))
            try await volume.deleteFile(at: rn)

            let free = try await volume.allocationStats().freeClusters
            XCTAssertEqual(
                free, baseline,
                "deleting a \(clusters)-cluster file left \(Int64(baseline) - Int64(free)) clusters allocated"
            )
            let audit = try await volume.auditBitmapForUnreferencedClusters()
            XCTAssertEqual(
                audit.leakedClusters, 0,
                "delete of a \(clusters)-cluster file leaked \(audit.leakedClusters); ranges: \(audit.largestLeakedRanges)"
            )
        }
    }

    /// The full `cp` replace sequence: delete the existing file, create a new
    /// one with the same name, write different content.
    func testReplaceSequenceDeleteThenCreateDoesNotLeak() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )
        let cluster = Int(volume.bytesPerCluster)

        var rn = try await volume.createFile(named: "replaced.bin", inDirectory: 5)
        try await self.write(volume, rn, bytes: 40 * cluster, seed: 1)
        let afterFirst = try await volume.allocationStats().freeClusters

        for (i, clusters) in [40, 25, 55].enumerated() {
            try await volume.deleteFile(at: rn)
            rn = try await volume.createFile(named: "replaced.bin", inDirectory: 5)
            try await self.write(volume, rn, bytes: clusters * cluster, seed: UInt8(i + 2))

            let audit = try await volume.auditBitmapForUnreferencedClusters()
            XCTAssertEqual(
                audit.leakedClusters, 0,
                "replace round \(i) (\(clusters) clusters) leaked \(audit.leakedClusters); "
                + "ranges: \(audit.largestLeakedRanges)"
            )
        }

        // Back to the original size — free space must return to that baseline.
        try await volume.deleteFile(at: rn)
        rn = try await volume.createFile(named: "replaced.bin", inDirectory: 5)
        try await self.write(volume, rn, bytes: 40 * cluster, seed: 9)
        let afterLast = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            afterLast, afterFirst,
            "four replace cycles drifted free space by \(Int64(afterFirst) - Int64(afterLast)) clusters"
        )
    }

    /// Does an in-process write FAILURE leak the allocation?
    ///
    /// `writeFile` persists the cluster allocation before streaming payload,
    /// and its own doc comment accepts that a crash there leaves clusters
    /// "allocated but unreferenced". A power-loss crash genuinely cannot do
    /// better -- but an ordinary thrown error can and should release them.
    /// This is the only mechanism found that produces the hardware shape:
    /// one contiguous run equal to exactly one file's size.
    func testFailedWriteDoesNotLeakItsAllocation() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )
        let cluster = Int(volume.bytesPerCluster)
        let rn = try await volume.createFile(named: "fails.bin", inDirectory: 5)
        let baseline = try await volume.allocationStats().freeClusters

        struct Boom: Error {}
        let total = 30 * cluster
        var cursor = 0
        do {
            try await volume.writeFile(at: rn, totalSize: UInt64(total)) {
                if cursor >= total / 2 { throw Boom() }
                let take = min(1 << 16, total - cursor)
                defer { cursor += take }
                return Data(repeating: 0xAB, count: take)
            }
            XCTFail("expected the injected write failure to propagate")
        } catch is Boom {
            // expected
        }

        let audit = try await volume.auditBitmapForUnreferencedClusters()
        let free = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            audit.leakedClusters, 0,
            "a failed write leaked \(audit.leakedClusters) clusters (free moved by "
            + "\(Int64(baseline) - Int64(free))); ranges: \(audit.largestLeakedRanges)"
        )
    }

    func testOverwritingAFileDoesNotLeakItsPreviousClusters() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )

        let rn = try await volume.createFile(named: "overwrite.bin", inDirectory: 5)
        let size = 20 * Int(volume.bytesPerCluster)

        try await self.write(volume, rn, bytes: size, seed: 1)
        let freeAfterFirst = try await volume.allocationStats().freeClusters

        // Overwrite with the SAME size: the file should end up owning the same
        // number of clusters, so free space must not move.
        try await self.write(volume, rn, bytes: size, seed: 2)
        let freeAfterSecond = try await volume.allocationStats().freeClusters

        XCTAssertEqual(
            freeAfterSecond, freeAfterFirst,
            """
            overwriting a \(size / Int(volume.bytesPerCluster))-cluster file changed free space by \
            \(Int64(freeAfterFirst) - Int64(freeAfterSecond)) clusters — the previous allocation \
            was not released, leaving allocated bits with no owner ("Volume Bitmap is incorrect")
            """
        )

        // Repeated overwrites must not drift either.
        for seed in UInt8(3)...UInt8(6) {
            try await self.write(volume, rn, bytes: size, seed: seed)
        }
        let freeAfterMany = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            freeAfterMany, freeAfterFirst,
            "five overwrites drifted free space by \(Int64(freeAfterFirst) - Int64(freeAfterMany)) clusters"
        )

        // And the content must still be the last thing written.
        let readBack = try await volume.readFile(at: rn)
        XCTAssertEqual(readBack.count, size, "read-back length mismatch after overwrites")
    }
}
