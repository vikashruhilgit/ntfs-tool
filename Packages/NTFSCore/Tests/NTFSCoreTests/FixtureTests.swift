import XCTest
@testable import NTFSCore

final class FixtureTests: XCTestCase {

    /// Resolve the path to a committed test fixture relative to this test file.
    /// SwiftPM does not yet have a stable `Bundle.module`-based way to locate
    /// arbitrary non-Swift resources without declaring them as `.resource` in
    /// Package.swift; since the fixture is consumed only by tests and we want
    /// to keep Package.swift minimal, we look it up by walking from #file up
    /// to the Tests/NTFSCoreTests/Fixtures/ directory.
    private func fixturePath(_ name: String) -> String {
        // #file == .../Tests/NTFSCoreTests/FixtureTests.swift
        let here = URL(fileURLWithPath: #filePath)
        let fixtures = here
            .deletingLastPathComponent()  // .../Tests/NTFSCoreTests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return fixtures.path
    }

    /// Read the first 512 bytes of the real `small.img` fixture via BlockDevice
    /// and verify BootSector.parse accepts it. This is the end-to-end smoke
    /// test that the fixture pipeline (scripts/make_test_images.sh) produces
    /// output our parser can actually consume.
    func testParseRealFixtureBootSector() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("""
                Fixture missing: \(path)
                Regenerate via: ./scripts/make_test_images.sh
                (requires Docker Desktop running)
                """)
        }

        let device = try FileHandleBlockDevice(openingFileAt: path)
        let firstSector = try await device.read(offset: 0, length: BootSector.onDiskSize)
        let boot = try BootSector.parse(firstSector)

        // Properties of the fixture as built by scripts/make_test_images.sh.
        XCTAssertEqual(boot.oemID, "NTFS    ")
        XCTAssertEqual(boot.bytesPerSector, 512)
        // The script passes --cluster-size 4096 to mkntfs: 4096 / 512 = 8 sectors per cluster.
        XCTAssertEqual(boot.sectorsPerCluster, 8)
        XCTAssertEqual(boot.mediaDescriptor, 0xF8)
        XCTAssertEqual(boot.bootSectorSignature, 0xAA55)

        // 4 MiB / 512 = 8192 total sectors. mkntfs subtracts 1 (boot sector
        // is excluded from the "total sectors" count it writes), so expect 8191.
        // Allow ±1 for tool version differences.
        XCTAssertTrue(
            (8190...8192).contains(boot.totalSectors),
            "expected totalSectors in 8190..8192, got \(boot.totalSectors)"
        )

        // MFT placement is determined by mkntfs; we don't pin a specific cluster
        // number (it can shift between mkntfs versions). Just assert it's
        // strictly inside the volume.
        let totalSectors = boot.totalSectors
        let sectorsPerCluster = UInt64(boot.sectorsPerCluster)
        let totalClusters = totalSectors / sectorsPerCluster
        XCTAssertGreaterThan(boot.mftCluster, 0, "MFT cluster should be non-zero")
        XCTAssertLessThan(
            boot.mftCluster, totalClusters,
            "MFT cluster (\(boot.mftCluster)) should be within volume (\(totalClusters) clusters)"
        )
    }

    /// BlockDevice respects async semantics: a sliced read at a non-zero offset
    /// returns the correct bytes and doesn't accidentally read past the end.
    func testBlockDeviceSlicedReads() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }

        let device = try FileHandleBlockDevice(openingFileAt: path)

        // Read just the boot signature (2 bytes at offset 510).
        let sig = try await device.read(offset: 510, length: 2)
        XCTAssertEqual(sig.count, 2)
        XCTAssertEqual(sig[0], 0x55)
        XCTAssertEqual(sig[1], 0xAA)

        // Read the OEM ID (8 bytes at offset 3).
        let oem = try await device.read(offset: 3, length: 8)
        XCTAssertEqual(String(decoding: oem, as: UTF8.self), "NTFS    ")
    }

    /// Zero-length read returns an empty Data without seeking.
    func testBlockDeviceZeroLengthRead() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let empty = try await device.read(offset: 0, length: 0)
        XCTAssertEqual(empty.count, 0)
    }
}
