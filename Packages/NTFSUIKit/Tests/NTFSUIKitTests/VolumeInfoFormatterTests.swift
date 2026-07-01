import XCTest
@testable import NTFSUIKit

final class VolumeInfoFormatterTests: XCTestCase {

    // MARK: byte formatting

    func testHumanBytesBelowKilobyte() {
        XCTAssertEqual(VolumeInfoFormatter.humanBytes(512), "512 B")
    }

    func testHumanBytesGigabytesOneDecimal() {
        // 100 * 1000^3 == "100.0 GB"
        XCTAssertEqual(VolumeInfoFormatter.humanBytes(100_000_000_000), "100.0 GB")
    }

    func testHumanBytesFractionalGigabytes() {
        // 61.6 GB
        XCTAssertEqual(VolumeInfoFormatter.humanBytes(61_600_000_000), "61.6 GB")
    }

    func testClusterSizeFourKilobytes() {
        // KB renders with no decimal (idx < 2): 4096 / 1000 = 4.096 -> "4 KB".
        XCTAssertEqual(VolumeInfoFormatter.clusterSize(4096), "4 KB")
        XCTAssertEqual(VolumeInfoFormatter.clusterSize(4000), "4 KB")
        // MB and up carry one decimal.
        XCTAssertEqual(VolumeInfoFormatter.humanBytes(1_500_000), "1.5 MB")
    }

    // MARK: percent-used from allocationStats-derived numbers

    func testPercentUsedHalf() {
        XCTAssertEqual(VolumeInfoFormatter.percentUsed(used: 50, total: 100), 0.5, accuracy: 0.0001)
    }

    func testPercentUsedClampsAndGuardsZeroTotal() {
        XCTAssertEqual(VolumeInfoFormatter.percentUsed(used: 10, total: 0), 0)
        XCTAssertEqual(VolumeInfoFormatter.percentUsed(used: 200, total: 100), 1)
    }

    func testPercentUsedLabel() {
        XCTAssertEqual(VolumeInfoFormatter.percentUsedLabel(used: 616, total: 1000), "61.6%")
    }

    // MARK: dirty -> status

    func testHealthStatusMapping() {
        XCTAssertEqual(VolumeInfoFormatter.healthStatus(isDirty: false), "Clean")
        XCTAssertEqual(VolumeInfoFormatter.healthStatus(isDirty: true), "Dirty")
    }

    func testPermissionLabelMapping() {
        XCTAssertEqual(VolumeInfoFormatter.permissionLabel(isWritable: false), "Read-only")
        XCTAssertEqual(VolumeInfoFormatter.permissionLabel(isWritable: true), "Read/Write")
    }

    // MARK: cluster / MFT formatting

    func testMftLocationFormatting() {
        let s = VolumeInfoFormatter.mftLocation(cluster: 786_432, byteOffset: 3_221_225_472)
        XCTAssertTrue(s.contains("cluster 786432"), s)
        XCTAssertTrue(s.contains("GB"), s)
    }

    func testVersionLabel() {
        XCTAssertEqual(VolumeInfoFormatter.versionLabel(major: 3, minor: 1), "NTFS 3.1")
    }

    // MARK: nil-tolerant overloads (statfs / mounted-read-only path)

    func testMftLocationNilDegradesToUnavailableWhileMounted() {
        XCTAssertEqual(
            VolumeInfoFormatter.mftLocation(cluster: nil, byteOffset: nil),
            "Unavailable while mounted"
        )
        XCTAssertEqual(
            VolumeInfoFormatter.mftLocation(cluster: 786_432, byteOffset: nil),
            "Unavailable while mounted"
        )
        // Both present → the real description via the optional overload.
        let s = VolumeInfoFormatter.mftLocation(cluster: 786_432 as UInt64?, byteOffset: 3_221_225_472 as UInt64?)
        XCTAssertTrue(s.contains("cluster 786432"), s)
    }

    func testVersionLabelNilDegradesToUnavailable() {
        XCTAssertEqual(VolumeInfoFormatter.versionLabel(major: nil, minor: nil), "Unavailable")
        XCTAssertEqual(VolumeInfoFormatter.versionLabel(major: 3 as UInt8?, minor: 1 as UInt8?), "NTFS 3.1")
    }

    func testHealthStatusNilDegradesToUnavailable() {
        XCTAssertEqual(VolumeInfoFormatter.healthStatus(isDirty: nil), "Unavailable")
        XCTAssertEqual(VolumeInfoFormatter.healthStatus(isDirty: false as Bool?), "Clean")
        XCTAssertEqual(VolumeInfoFormatter.healthStatus(isDirty: true as Bool?), "Dirty")
    }
}
