import Foundation

// Parser for the $INDEX_ROOT attribute (type 0x90, always resident).
//
// $INDEX_ROOT layout:
//   0   u32 attribute type indexed (0x30 for $FILE_NAME entries — the $I30 case)
//   4   u32 collation rule
//   8   u32 index allocation block size (bytes)
//   12  u8  clusters per index allocation block (or signed-exp like MFT record)
//   13  3 bytes padding
//   16  INDEX_HEADER (16 bytes):
//        0  u32 entries offset (from start of INDEX_HEADER)
//        4  u32 used size of the index (from start of INDEX_HEADER)
//        8  u32 allocated size of the index (from start of INDEX_HEADER)
//        12 u8  flags: bit 0 = LARGE_INDEX (has subnodes / index allocation)
//        13 3 bytes padding
//   16 + entriesOffset: INDEX_ENTRY[] terminated by a LAST entry
public struct IndexRoot: Sendable, Equatable {
    public let attributeTypeIndexed: UInt32
    public let collationRule: UInt32
    public let indexAllocationBlockSize: UInt32
    public let clustersPerIndexBlock: Int8
    public let header: IndexHeader
    public let entries: [IndexEntry]

    public var isLargeIndex: Bool { header.flags.contains(.large) }

    public static func parse(_ data: Data) throws -> IndexRoot {
        guard data.count >= 32 else {
            throw NTFSError.corruptOnDisk(
                description: "INDEX_ROOT too short: \(data.count) < 32"
            )
        }

        let attrType = try data.readU32LE(at: 0)
        let collation = try data.readU32LE(at: 4)
        let blockSize = try data.readU32LE(at: 8)
        let clustersPerBlock = try data.readI8(at: 12)

        // INDEX_HEADER starts at offset 16.
        let entriesOffset = try data.readU32LE(at: 16)
        let usedSize      = try data.readU32LE(at: 20)
        let allocatedSize = try data.readU32LE(at: 24)
        let flagsByte     = try data.readU8(at: 28)
        let header = IndexHeader(
            entriesOffset: entriesOffset,
            usedSize: usedSize,
            allocatedSize: allocatedSize,
            flags: IndexHeader.Flags(rawValue: flagsByte)
        )

        let entriesStart = 16 + Int(entriesOffset)
        let entriesEnd = 16 + Int(usedSize)
        guard entriesStart <= data.count, entriesEnd <= data.count else {
            throw NTFSError.corruptOnDisk(
                description: "INDEX_ROOT entries [\(entriesStart)..\(entriesEnd)] outside buffer \(data.count)"
            )
        }

        let entries = try IndexEntryParser.iterate(data, startingAt: entriesStart, limit: entriesEnd)

        return IndexRoot(
            attributeTypeIndexed: attrType,
            collationRule: collation,
            indexAllocationBlockSize: blockSize,
            clustersPerIndexBlock: clustersPerBlock,
            header: header,
            entries: entries
        )
    }
}

public struct IndexHeader: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// The index has an associated $INDEX_ALLOCATION attribute (it's a tree, not a leaf).
        public static let large = Flags(rawValue: 0x01)
    }
    public let entriesOffset: UInt32
    public let usedSize: UInt32
    public let allocatedSize: UInt32
    public let flags: Flags
}
