import XCTest
@testable import NTFSCore

/// Regression guard for the cluster→device-byte-offset invariant.
///
/// NTFS device byte offsets must be computed in 64-bit:
///   byteOffset = LCN × bytesPerCluster
///
/// macOS 15's `livefiles_ntfs` ships a 32-bit blockmap bug that wraps offsets
/// above 4 GiB, mapping high LCNs to the wrong place on disk. These tests pin
/// our pure-arithmetic core (`Volume.deviceByteOffset(forLCN:bytesPerCluster:)`)
/// so we can never reintroduce the same overflow: every assertion below uses an
/// LCN whose byte offset exceeds `UInt32.max`, and would compute a wrong value
/// under 32-bit truncation.
final class ClusterOffsetTests: XCTestCase {

    /// The cluster→offset multiply must stay 64-bit for LCNs that push the
    /// resulting byte offset above 4 GiB (where a 32-bit multiply would wrap).
    func testClusterByteOffsetIs64BitAboveFourGiB() {
        let bytesPerCluster: UInt32 = 4096

        // The real hardware LCN from the livefiles >4 GB investigation. In
        // 32-bit this product wraps to a wrong (small) value; in 64-bit it is
        // exactly 5,161,881,600.
        let realHardwareLCN: UInt64 = 1_260_225
        let realHardwareOffset = Volume.deviceByteOffset(
            forLCN: realHardwareLCN, bytesPerCluster: bytesPerCluster)
        XCTAssertEqual(realHardwareOffset, 5_161_881_600)
        XCTAssertGreaterThan(realHardwareOffset, UInt64(UInt32.max),
                             "offset must exceed 32-bit range — no wraparound")

        // A round LCN well above the 4 GiB boundary.
        let offset2M = Volume.deviceByteOffset(
            forLCN: 2_000_000, bytesPerCluster: bytesPerCluster)
        XCTAssertEqual(offset2M, 8_192_000_000)
        XCTAssertGreaterThan(offset2M, UInt64(UInt32.max))

        // Exactly the 32-bit overflow boundary: LCN 1,048,576 == 4 GiB / 4096,
        // so the offset is exactly 4 GiB (2^32). A 32-bit multiply yields 0.
        let offsetAt4GiB = Volume.deviceByteOffset(
            forLCN: 1_048_576, bytesPerCluster: bytesPerCluster)
        XCTAssertEqual(offsetAt4GiB, 4_294_967_296) // 4 GiB
        XCTAssertGreaterThan(offsetAt4GiB, UInt64(UInt32.max))

        // Well past the boundary.
        let offset4M = Volume.deviceByteOffset(
            forLCN: 4_000_000, bytesPerCluster: bytesPerCluster)
        XCTAssertEqual(offset4M, 16_384_000_000)
        XCTAssertGreaterThan(offset4M, UInt64(UInt32.max))
    }
}
