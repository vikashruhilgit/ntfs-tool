import Foundation

// One MFT (Master File Table) file record. NTFS stores all filesystem
// metadata as a flat array of fixed-size MFT records — typically 1024 bytes
// each, but the size is volume-defined (see BootSector.clustersPerMFTRecord).
//
// On-disk layout (offsets from the start of the record, all little-endian):
//
//   0  u32   Magic: 'FILE' (0x46494C45). 'BAAD' (0x44414142) for corrupt records.
//   4  u16   USA offset — byte offset (from record start) of the Update Sequence Array.
//   6  u16   USA count — number of u16 entries in USA (1 sentinel + N fix-ups).
//   8  u64   $LogFile sequence number.
//  16  u16   Sequence number (incremented when this MFT slot is reused).
//  18  u16   Hard link count.
//  20  u16   Offset to first attribute.
//  22  u16   Flags: bit 0 = IN_USE, bit 1 = DIRECTORY.
//  24  u32   Used size of this record (header + attributes + 0xFFFFFFFF end marker).
//  28  u32   Allocated size of this record (= MFT record size from the boot sector).
//  32  u64   Base file reference. Zero if this is a base record; else MFT reference
//            (low 48 bits record number, high 16 bits sequence) of the base record.
//  40  u16   Next attribute instance ID.
//  42  u16   Padding (NTFS 3.1+ — was reserved).
//  44  u32   This record's MFT number (NTFS 3.1+).
//
// Then the USA at offset USA-offset, then the first attribute at offset 20-from-here.

public struct MFTRecord: Equatable, Sendable {
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let inUse     = Flags(rawValue: 0x0001)
        public static let directory = Flags(rawValue: 0x0002)
    }

    public let magic: UInt32              // 'FILE' or 'BAAD'
    public let usaOffset: UInt16
    public let usaCount: UInt16           // includes the sentinel entry
    public let logFileSequenceNumber: UInt64
    public let sequenceNumber: UInt16
    public let hardLinkCount: UInt16
    public let firstAttributeOffset: UInt16
    public let flags: Flags
    public let usedSize: UInt32
    public let allocatedSize: UInt32
    public let baseFileReference: UInt64  // 0 if this is a base record
    public let nextAttributeID: UInt16
    public let mftRecordNumber: UInt32    // NTFS 3.1+; older volumes leave it as padding

    /// The fixed-up record bytes (USA fix-ups applied). Always equal to the volume's
    /// MFT-record size if the parse succeeded.
    public let bytes: Data

    // Magic constants read as little-endian u32 from the first 4 bytes on disk.
    // "FILE" on disk = bytes 0x46 0x49 0x4C 0x45 → LE u32 = 0x454C4946.
    // "BAAD" on disk = bytes 0x42 0x41 0x41 0x44 → LE u32 = 0x44414142.
    public static let magicFILE: UInt32 = 0x454C_4946
    public static let magicBAAD: UInt32 = 0x4441_4142

    public var isInUse: Bool       { flags.contains(.inUse) }
    public var isDirectory: Bool   { flags.contains(.directory) }
    public var isBaseRecord: Bool  { baseFileReference == 0 }

    /// Parse one MFT record. The input must be exactly the record's allocated size
    /// (typically 1024 bytes); USA fix-ups are applied in-place to the returned
    /// `bytes` so that the post-fix-up content is what attribute parsers will see.
    public static func parse(_ raw: Data, expectedSize: Int) throws -> MFTRecord {
        guard raw.count == expectedSize else {
            throw NTFSError.corruptOnDisk(
                description: "MFT record size mismatch: expected \(expectedSize), got \(raw.count)"
            )
        }

        let magic = try raw.readU32LE(at: 0)
        guard magic == magicFILE else {
            // 'BAAD' is the documented post-mortem marker NTFS writes when
            // the OS detected corruption. Surface it as a typed error rather
            // than silently treating it like FILE.
            if magic == magicBAAD {
                throw NTFSError.corruptOnDisk(description: "MFT record magic is 'BAAD' (NTFS marked record corrupt)")
            }
            throw NTFSError.corruptOnDisk(
                description: "unexpected MFT record magic 0x\(String(format: "%08X", magic))"
            )
        }

        let usaOffset = try raw.readU16LE(at: 4)
        let usaCount  = try raw.readU16LE(at: 6)

        let fixedUp = try UpdateSequenceArray.applyFixup(
            recordBytes: raw,
            usaOffset: Int(usaOffset),
            usaCount: Int(usaCount),
            blockSize: 512
        )

        return MFTRecord(
            magic: magic,
            usaOffset: usaOffset,
            usaCount: usaCount,
            logFileSequenceNumber: try fixedUp.readU64LE(at: 8),
            sequenceNumber:        try fixedUp.readU16LE(at: 16),
            hardLinkCount:         try fixedUp.readU16LE(at: 18),
            firstAttributeOffset:  try fixedUp.readU16LE(at: 20),
            flags:                 Flags(rawValue: try fixedUp.readU16LE(at: 22)),
            usedSize:              try fixedUp.readU32LE(at: 24),
            allocatedSize:         try fixedUp.readU32LE(at: 28),
            baseFileReference:     try fixedUp.readU64LE(at: 32),
            nextAttributeID:       try fixedUp.readU16LE(at: 40),
            mftRecordNumber:       (expectedSize >= 48) ? (try fixedUp.readU32LE(at: 44)) : 0,
            bytes: fixedUp
        )
    }
}
