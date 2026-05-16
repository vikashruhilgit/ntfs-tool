import Foundation

// One entry in an NTFS index. For the canonical `$I30` directory index, each
// entry's content is a `$FILE_NAME` attribute body, so we expose both the
// raw MFT reference and the parsed `FileName`.
//
// On-disk layout of an INDEX_ENTRY (Linux-NTFS docs):
//   0   u64 file reference (low 48 bits = record number, high 16 = sequence)
//   8   u16 length of this entry (including subnode pointer if present)
//   10  u16 length of the key (the embedded $FILE_NAME body, in bytes)
//   12  u16 flags (bit 0 = HAS_SUBNODE, bit 1 = LAST)
//   14  u16 reserved
//   16  ... key bytes (key_length bytes) — for $I30, this is a $FILE_NAME body
//   ... 8-byte alignment padding ...
//   end-of-entry - 8: u64 VCN of child subnode (if HAS_SUBNODE)
public struct IndexEntry: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        /// Entry has a child subnode (VCN at end - 8 bytes).
        public static let hasSubnode = Flags(rawValue: 0x01)
        /// Last entry in the node (its key is empty — sentinel).
        public static let last       = Flags(rawValue: 0x02)
    }

    public let fileReference: UInt64
    public let recordNumber: UInt64
    public let sequenceNumber: UInt16
    public let entryLength: UInt16
    public let keyLength: UInt16
    public let flags: Flags
    public let fileName: FileName?       // nil for LAST sentinel entries
    public let subnodeVCN: UInt64?       // present when flags.contains(.hasSubnode)

    public var isLast: Bool { flags.contains(.last) }
    public var hasSubnode: Bool { flags.contains(.hasSubnode) }
}

// Parse a sequence of INDEX_ENTRY records starting at `cursor` in `data` and
// continuing until a LAST entry or the buffer is exhausted. The caller is
// responsible for slicing `data` so it starts at the first entry (typically
// `entriesOffset` past the INDEX_HEADER).
enum IndexEntryParser {

    static func iterate(_ data: Data, startingAt cursor: Int, limit: Int) throws -> [IndexEntry] {
        var entries: [IndexEntry] = []
        var pos = cursor
        let end = min(limit, data.count)

        while pos + 16 <= end {
            let fileRef     = try data.readU64LE(at: pos + 0)
            let entryLength = try data.readU16LE(at: pos + 8)
            let keyLength   = try data.readU16LE(at: pos + 10)
            let flagsRaw    = try data.readU16LE(at: pos + 12)

            guard entryLength >= 16 else {
                throw NTFSError.corruptOnDisk(
                    description: "INDEX_ENTRY entryLength \(entryLength) < 16-byte minimum at offset \(pos)"
                )
            }
            guard pos + Int(entryLength) <= end else {
                throw NTFSError.corruptOnDisk(
                    description: "INDEX_ENTRY at offset \(pos) length \(entryLength) overruns buffer (end \(end))"
                )
            }

            let flags = IndexEntry.Flags(rawValue: flagsRaw)

            // Parse the embedded key as a $FILE_NAME body when present.
            var fileName: FileName?
            if !flags.contains(.last), keyLength > 0 {
                let keyStart = pos + 16
                let keyEnd   = keyStart + Int(keyLength)
                guard keyEnd <= pos + Int(entryLength) else {
                    throw NTFSError.corruptOnDisk(
                        description: "INDEX_ENTRY key length \(keyLength) extends past entry end at offset \(pos)"
                    )
                }
                let keyBytes = Data(data[(data.startIndex + keyStart)..<(data.startIndex + keyEnd)])
                fileName = try FileName.parse(keyBytes)
            }

            var subnodeVCN: UInt64?
            if flags.contains(.hasSubnode) {
                // Subnode VCN sits in the last 8 bytes of this entry.
                let vcnOffset = pos + Int(entryLength) - 8
                guard vcnOffset >= pos + 16 else {
                    throw NTFSError.corruptOnDisk(
                        description: "INDEX_ENTRY subnode pointer at offset \(vcnOffset) overlaps header"
                    )
                }
                subnodeVCN = try data.readU64LE(at: vcnOffset)
            }

            let recordNumber = fileRef & 0x0000_FFFF_FFFF_FFFF
            let sequenceNumber = UInt16(truncatingIfNeeded: (fileRef >> 48) & 0xFFFF)

            entries.append(IndexEntry(
                fileReference: fileRef,
                recordNumber: recordNumber,
                sequenceNumber: sequenceNumber,
                entryLength: entryLength,
                keyLength: keyLength,
                flags: flags,
                fileName: fileName,
                subnodeVCN: subnodeVCN
            ))

            if flags.contains(.last) { break }
            pos += Int(entryLength)
        }

        return entries
    }
}
