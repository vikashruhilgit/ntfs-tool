import Foundation

// NTFS boot sector (the first 512 bytes of an NTFS volume).
//
// On-disk layout reference: Linux-NTFS project, https://flatcap.github.io/linux-ntfs/ntfs/.
// All multi-byte fields are little-endian.

public struct BootSector: Equatable, Sendable {
    /// Offset 3, 8 ASCII bytes. For an NTFS volume the first 4 are "NTFS"
    /// and the trailing 4 are spaces.
    public let oemID: String

    /// Offset 11. Bytes per logical sector. Must be one of 256/512/1024/2048/4096.
    public let bytesPerSector: UInt16

    /// Offset 13. Logical sectors per cluster. Power of two in [1, 128].
    public let sectorsPerCluster: UInt8

    /// Offset 21. Media descriptor (0xF8 for fixed disks).
    public let mediaDescriptor: UInt8

    /// Offset 40. Total number of sectors on the volume (NTFS-specific 64-bit field).
    public let totalSectors: UInt64

    /// Offset 48. Logical cluster number of the start of the MFT.
    public let mftCluster: UInt64

    /// Offset 56. Logical cluster number of the start of the MFT mirror.
    public let mftMirrorCluster: UInt64

    /// Offset 64. Clusters per MFT record. Signed: a positive value is the cluster
    /// count; a negative value `v` encodes a per-record byte size of `2^|v|` bytes.
    public let clustersPerMFTRecord: Int8

    /// Offset 68. Clusters per index record. Same signed encoding as `clustersPerMFTRecord`.
    public let clustersPerIndexRecord: Int8

    /// Offset 72. Volume serial number (8 bytes, treated as an opaque identifier).
    public let volumeSerial: UInt64

    /// Offset 510. Must be 0xAA55 for a valid boot sector signature.
    public let bootSectorSignature: UInt16

    public static let onDiskSize = 512

    public static func parse(_ data: Data) throws -> BootSector {
        guard data.count == onDiskSize else {
            throw NTFSError.invalidBootSector(
                reason: "expected \(onDiskSize) bytes, got \(data.count)"
            )
        }

        let oemID = try data.readASCII(at: 3, length: 8)
        guard oemID.hasPrefix("NTFS") else {
            throw NTFSError.invalidBootSector(
                reason: "OEM ID does not start with 'NTFS' (got '\(oemID)')"
            )
        }

        let bytesPerSector = try data.readU16LE(at: 11)
        guard validBytesPerSector.contains(bytesPerSector) else {
            throw NTFSError.invalidBootSector(
                reason: "bytesPerSector \(bytesPerSector) not in \(Array(validBytesPerSector))"
            )
        }

        let sectorsPerCluster = try data.readU8(at: 13)
        guard sectorsPerCluster > 0,
              sectorsPerCluster <= 128,
              sectorsPerCluster.nonzeroBitCount == 1 else {
            throw NTFSError.invalidBootSector(
                reason: "sectorsPerCluster \(sectorsPerCluster) is not a power of two in [1, 128]"
            )
        }

        let signature = try data.readU16LE(at: 510)
        guard signature == 0xAA55 else {
            throw NTFSError.invalidBootSector(
                reason: "boot sector signature 0x\(String(signature, radix: 16)) != 0xAA55"
            )
        }

        return BootSector(
            oemID: oemID,
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            mediaDescriptor: try data.readU8(at: 21),
            totalSectors: try data.readU64LE(at: 40),
            mftCluster: try data.readU64LE(at: 48),
            mftMirrorCluster: try data.readU64LE(at: 56),
            clustersPerMFTRecord: try data.readI8(at: 64),
            clustersPerIndexRecord: try data.readI8(at: 68),
            volumeSerial: try data.readU64LE(at: 72),
            bootSectorSignature: signature
        )
    }

    /// Decode the signed-cluster-or-negative-power-of-two encoding used by NTFS for
    /// `clustersPerMFTRecord` and `clustersPerIndexRecord`. Returns the resolved size
    /// in bytes, given the volume's cluster size in bytes.
    public static func resolveRecordSize(field: Int8, clusterSizeBytes: UInt32) -> UInt32 {
        if field >= 0 {
            return UInt32(field) * clusterSizeBytes
        }
        let exponent = UInt32(-Int(field))
        guard exponent < 32 else { return 0 }
        return UInt32(1) << exponent
    }
}

private let validBytesPerSector: Set<UInt16> = [256, 512, 1024, 2048, 4096]
