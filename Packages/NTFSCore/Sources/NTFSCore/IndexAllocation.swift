import Foundation

// Parser for one $INDEX_ALLOCATION block — an "INDX" record. Used when a
// directory's $I30 B-tree spills out of $INDEX_ROOT (LARGE_INDEX flag).
//
// On-disk layout (USA fix-up applies to the whole record before reading entries):
//   0   u32  magic 'INDX' (LE = 0x58444E49)
//   4   u16  USA offset
//   6   u16  USA count (1 sentinel + N fix-ups)
//   8   u64  $LogFile sequence number
//   16  u64  VCN of this index block (in cluster-equivalent units)
//   24  INDEX_HEADER (16 bytes — same layout as IndexRoot's embedded header)
//   24 + entriesOffset: INDEX_ENTRY[] terminated by LAST
public struct IndexAllocationBlock: Sendable, Equatable {
    public let magic: UInt32
    public let usaOffset: UInt16
    public let usaCount: UInt16
    public let logFileSequenceNumber: UInt64
    public let vcnOfThisBlock: UInt64
    public let header: IndexHeader
    public let entries: [IndexEntry]

    public static let magicINDX: UInt32 = 0x5844_4E49  // 'I' 'N' 'D' 'X' → LE u32

    /// Parse one INDX block.
    ///
    /// - parameter raw: the raw on-disk bytes (one INDX block — typically
    ///   `Volume.indexRecordSizeBytes` long for the volume).
    /// - parameter sectorSize: the volume's logical sector size, for USA fix-up.
    public static func parse(_ raw: Data, sectorSize: Int = 512) throws -> IndexAllocationBlock {
        guard raw.count >= 40 else {
            throw NTFSError.corruptOnDisk(
                description: "INDX block too short: \(raw.count) < 40"
            )
        }

        let magic = try raw.readU32LE(at: 0)
        guard magic == magicINDX else {
            throw NTFSError.corruptOnDisk(
                description: "INDX block magic mismatch: expected 0x\(String(format: "%08X", magicINDX)), got 0x\(String(format: "%08X", magic))"
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

        let lsn = try fixedUp.readU64LE(at: 8)
        let vcn = try fixedUp.readU64LE(at: 16)

        // INDEX_HEADER at offset 24.
        let entriesOffset = try fixedUp.readU32LE(at: 24)
        let usedSize      = try fixedUp.readU32LE(at: 28)
        let allocatedSize = try fixedUp.readU32LE(at: 32)
        let flagsByte     = try fixedUp.readU8(at: 36)

        let header = IndexHeader(
            entriesOffset: entriesOffset,
            usedSize: usedSize,
            allocatedSize: allocatedSize,
            flags: IndexHeader.Flags(rawValue: flagsByte)
        )

        let entriesStart = 24 + Int(entriesOffset)
        let entriesEnd   = 24 + Int(usedSize)
        guard entriesStart <= fixedUp.count, entriesEnd <= fixedUp.count else {
            throw NTFSError.corruptOnDisk(
                description: "INDX entries [\(entriesStart)..\(entriesEnd)] outside buffer \(fixedUp.count)"
            )
        }

        let entries = try IndexEntryParser.iterate(fixedUp, startingAt: entriesStart, limit: entriesEnd)

        return IndexAllocationBlock(
            magic: magic,
            usaOffset: usaOffset,
            usaCount: usaCount,
            logFileSequenceNumber: lsn,
            vcnOfThisBlock: vcn,
            header: header,
            entries: entries
        )
    }
}
