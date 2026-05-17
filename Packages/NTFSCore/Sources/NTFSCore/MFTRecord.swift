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

    /// Iterate the attributes embedded in this record. The result is cached only
    /// implicitly by the caller; call repeatedly only if cheap (parsing is O(N)
    /// in the record size).
    public func attributes() throws -> [Attribute] {
        try Attribute.iterate(
            recordBytes: bytes,
            firstAttributeOffset: Int(firstAttributeOffset),
            usedSize: Int(usedSize)
        )
    }

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
    ///
    /// `sectorSize` defaults to 512 — the NTFS standard logical sector size — but
    /// must be passed as `Int(volume.boot.bytesPerSector)` for 4Kn drives or any
    /// volume formatted with a non-default sector size.
    public static func parse(_ raw: Data, expectedSize: Int, sectorSize: Int = 512) throws -> MFTRecord {
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
            blockSize: sectorSize
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

    /// Serialize this MFT record into on-disk bytes ready for `BlockDevice.write`.
    /// Applies USA fix-up (increments the sentinel, copies block tails into
    /// USA[1..N], replaces tails with the new sentinel). The returned Data
    /// is the inverse of what `parse` consumes.
    ///
    /// `sectorSize` must match the volume — default 512.
    public func serialize(sectorSize: Int = 512) throws -> Data {
        // Sanity-check the in-memory bytes — every header field must agree
        // with the public properties before we serialize.
        guard bytes.count == Int(allocatedSize) else {
            throw NTFSError.corruptOnDisk(
                description: "MFTRecord.serialize: bytes.count \(bytes.count) != allocatedSize \(allocatedSize)"
            )
        }

        var mutable = bytes

        // Re-write the header in case the caller mutated any of our fields.
        Self.writeU32LE(into: &mutable, at: 0,  value: magic)
        Self.writeU16LE(into: &mutable, at: 4,  value: usaOffset)
        Self.writeU16LE(into: &mutable, at: 6,  value: usaCount)
        Self.writeU64LE(into: &mutable, at: 8,  value: logFileSequenceNumber)
        Self.writeU16LE(into: &mutable, at: 16, value: sequenceNumber)
        Self.writeU16LE(into: &mutable, at: 18, value: hardLinkCount)
        Self.writeU16LE(into: &mutable, at: 20, value: firstAttributeOffset)
        Self.writeU16LE(into: &mutable, at: 22, value: flags.rawValue)
        Self.writeU32LE(into: &mutable, at: 24, value: usedSize)
        Self.writeU32LE(into: &mutable, at: 28, value: allocatedSize)
        Self.writeU64LE(into: &mutable, at: 32, value: baseFileReference)
        Self.writeU16LE(into: &mutable, at: 40, value: nextAttributeID)
        if bytes.count >= 48 {
            Self.writeU32LE(into: &mutable, at: 44, value: mftRecordNumber)
        }

        // Apply USA on the way out.
        return try UpdateSequenceArray.reverseFixup(
            recordBytes: mutable,
            usaOffset: Int(usaOffset),
            usaCount: Int(usaCount),
            blockSize: sectorSize
        )
    }

    // MARK: — Little-endian writers (mirror of Endian.swift's readers)

    static func writeU16LE(into data: inout Data, at offset: Int, value: UInt16) {
        data[data.startIndex + offset]     = UInt8(value & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    static func writeU32LE(into data: inout Data, at offset: Int, value: UInt32) {
        for i in 0..<4 {
            data[data.startIndex + offset + i] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }
    static func writeU64LE(into data: inout Data, at offset: Int, value: UInt64) {
        for i in 0..<8 {
            data[data.startIndex + offset + i] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }
}
