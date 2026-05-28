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

    /// Serialize this BootSector into the canonical 512-byte boot sector
    /// layout (including the standard NTFS-style x86 jump stub at offset 0,
    /// the NTFS OEM signature at offset 3, the BPB at offsets 11-83, the
    /// volume serial at offset 72, and the 0xAA55 signature at offset 510).
    ///
    /// The inverse of `parse(_:)`. Round-trip is byte-identical for the
    /// fields BootSector models (modulo the bootstrap stub bytes, which are
    /// fixed by this writer to the canonical mkntfs jump stub).
    public func serialize() throws -> Data {
        // Validate fields first so we surface "bad input" rather than write
        // a malformed boot sector.
        guard oemID.count == 8, oemID.hasPrefix("NTFS") else {
            throw NTFSError.invalidBootSector(reason: "OEM ID must be 8 chars starting with NTFS (got '\(oemID)')")
        }
        guard validBytesPerSector.contains(bytesPerSector) else {
            throw NTFSError.invalidBootSector(reason: "bytesPerSector \(bytesPerSector) invalid")
        }
        guard sectorsPerCluster > 0,
              sectorsPerCluster <= 128,
              sectorsPerCluster.nonzeroBitCount == 1 else {
            throw NTFSError.invalidBootSector(reason: "sectorsPerCluster \(sectorsPerCluster) is not a power of two in [1,128]")
        }
        guard bootSectorSignature == 0xAA55 else {
            throw NTFSError.invalidBootSector(reason: "bootSectorSignature must be 0xAA55")
        }

        var d = Data(count: Self.onDiskSize)

        // --- Jump stub (offset 0-2): canonical NTFS jump-to-code-at-offset-0x54.
        //     mkntfs writes EB 52 90 — a 2-byte short jump (rel +0x52) then NOP.
        d[0] = 0xEB
        d[1] = 0x52
        d[2] = 0x90

        // --- OEM ID (offset 3, 8 ASCII bytes).
        let oemBytes = Array(oemID.utf8)
        precondition(oemBytes.count == 8)
        for i in 0..<8 { d[3 + i] = oemBytes[i] }

        // --- BPB (offset 11): bytes-per-sector, sectors-per-cluster, then
        //     a block of FAT-compatibility zeros (NTFS leaves them 0).
        Self.writeU16LE(into: &d, at: 11, bytesPerSector)
        d[13] = sectorsPerCluster
        // 14-15: reserved sectors (u16) — NTFS uses 0
        // 16: number of FATs (u8) — NTFS uses 0
        // 17-18: root entries (u16) — NTFS uses 0
        // 19-20: small total sectors (u16) — NTFS uses 0
        d[21] = mediaDescriptor
        // 22-23: sectors per FAT (u16) — NTFS uses 0
        // 24-25: sectors per track (u16) — NTFS leaves 0 for our purposes;
        //   mkntfs writes the BIOS geometry but it's advisory only.
        // 26-27: number of heads (u16) — same.
        // 28-31: hidden sectors (u32) — 0 here; the partition start is
        //   set by the partitioner, not by us.
        // 32-35: large total sectors (u32) — NTFS uses 0; the real total
        //   lives in the 64-bit field at offset 40.

        // --- NTFS-specific extended BPB (offset 36+).
        // 36: physical drive number (u8) — 0x80 for hard disks
        d[36] = 0x80
        // 37: current head (u8) — 0
        // 38: extended boot signature (u8) — 0x80 per mkntfs
        d[38] = 0x80
        // 39: reserved
        Self.writeU64LE(into: &d, at: 40, totalSectors)
        Self.writeU64LE(into: &d, at: 48, mftCluster)
        Self.writeU64LE(into: &d, at: 56, mftMirrorCluster)
        d[64] = UInt8(bitPattern: clustersPerMFTRecord)
        // 65-67: reserved (3 bytes) — 0
        d[68] = UInt8(bitPattern: clustersPerIndexRecord)
        // 69-71: reserved (3 bytes) — 0
        Self.writeU64LE(into: &d, at: 72, volumeSerial)
        // 80-83: checksum (u32) — 0 (NTFS doesn't use it; chkdsk ignores)

        // --- Boot code (offset 84-509): a 426-byte stub. mkntfs writes a
        //     small "NTLDR is missing"-style stub; for a data volume we
        //     leave it as zeros (the volume is non-bootable, which matches
        //     `mkntfs -Q` behavior for data volumes per the brief — read
        //     by Windows/livefiles_ntfs without complaint).

        // --- Signature (offset 510).
        Self.writeU16LE(into: &d, at: 510, bootSectorSignature)

        return d
    }

    // MARK: — Little-endian writers (mirror of MFTRecord's writers, kept
    // local to BootSector to avoid a cross-file dependency for what is a
    // small amount of code).

    static func writeU16LE(into d: inout Data, at offset: Int, _ value: UInt16) {
        d[offset]     = UInt8(value & 0xFF)
        d[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    static func writeU64LE(into d: inout Data, at offset: Int, _ value: UInt64) {
        for i in 0..<8 {
            d[offset + i] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }

    /// Convenience initializer for `mkntfs`: build a BootSector value from
    /// the volume geometry, ready to be serialized into bytes.
    public init(
        oemID: String = "NTFS    ",
        bytesPerSector: UInt16,
        sectorsPerCluster: UInt8,
        mediaDescriptor: UInt8 = 0xF8,
        totalSectors: UInt64,
        mftCluster: UInt64,
        mftMirrorCluster: UInt64,
        clustersPerMFTRecord: Int8,
        clustersPerIndexRecord: Int8,
        volumeSerial: UInt64,
        bootSectorSignature: UInt16 = 0xAA55
    ) {
        self.oemID = oemID
        self.bytesPerSector = bytesPerSector
        self.sectorsPerCluster = sectorsPerCluster
        self.mediaDescriptor = mediaDescriptor
        self.totalSectors = totalSectors
        self.mftCluster = mftCluster
        self.mftMirrorCluster = mftMirrorCluster
        self.clustersPerMFTRecord = clustersPerMFTRecord
        self.clustersPerIndexRecord = clustersPerIndexRecord
        self.volumeSerial = volumeSerial
        self.bootSectorSignature = bootSectorSignature
    }

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
