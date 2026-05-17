import Foundation

// Build the on-disk bytes of a $INDEX_ROOT attribute body for $I30. Used by
// Volume.createFile / deleteFile (Block G stage 3b) to mutate the parent
// directory's index when a child file is added or removed.
//
// $I30 is the canonical NTFS directory index — its key is a $FILE_NAME
// attribute body (per the parent's $INDEX_ROOT.attributeTypeIndexed = 0x30).
// Stage 3b only handles the resident-only ("small directory") path: every
// entry fits inside $INDEX_ROOT, no $INDEX_ALLOCATION is created or grown.
// Directories that already have the LARGE_INDEX flag are rejected with
// unsupportedFeature; converting a small directory to LARGE_INDEX during
// insert is its own work item (Phase 5e or later).
enum IndexBuilder {

    /// Serialize a single INDEX_ENTRY (no subnode pointer) with the given
    /// fileReference + $FILE_NAME body as key.
    static func serializeEntry(fileReference: UInt64, fileNameBody: Data) -> Data {
        let keyLength = fileNameBody.count
        // Common header (16) + key bytes, rounded up to 8.
        let rawLength = 16 + keyLength
        let alignedLength = ((rawLength + 7) / 8) * 8

        var data = Data(count: alignedLength)
        MFTRecord.writeU64LE(into: &data, at: 0, value: fileReference)
        MFTRecord.writeU16LE(into: &data, at: 8, value: UInt16(alignedLength))
        MFTRecord.writeU16LE(into: &data, at: 10, value: UInt16(keyLength))
        MFTRecord.writeU16LE(into: &data, at: 12, value: 0)   // flags: not LAST, no subnode
        MFTRecord.writeU16LE(into: &data, at: 14, value: 0)   // reserved
        for (i, byte) in fileNameBody.enumerated() {
            data[data.startIndex + 16 + i] = byte
        }
        return data
    }

    /// Serialize the LAST sentinel entry: 16-byte header with flags=LAST and
    /// no key + no subnode. Always 16 bytes.
    static func serializeLastSentinel() -> Data {
        var data = Data(count: 16)
        MFTRecord.writeU64LE(into: &data, at: 0,  value: 0)   // fileReference unused
        MFTRecord.writeU16LE(into: &data, at: 8,  value: 16)  // entryLength
        MFTRecord.writeU16LE(into: &data, at: 10, value: 0)   // keyLength
        MFTRecord.writeU16LE(into: &data, at: 12, value: 0x02) // flags: LAST
        MFTRecord.writeU16LE(into: &data, at: 14, value: 0)
        return data
    }

    /// Build a complete $INDEX_ROOT attribute body for $I30 from a sorted
    /// list of (fileReference, fileNameBody) pairs. Returns the bytes to
    /// stuff into the resident $INDEX_ROOT attribute's value.
    ///
    /// Layout:
    ///   0   u32 attributeTypeIndexed    = 0x30 ($FILE_NAME)
    ///   4   u32 collationRule           = 0x01 (COLLATION_FILENAME)
    ///   8   u32 indexAllocationBlockSize (carry over from existing index)
    ///   12  u8  clustersPerIndexBlock    (carry over)
    ///   13  3 bytes padding
    ///   16  INDEX_HEADER (16 bytes):
    ///        0  u32 entriesOffset (relative to header start = 16; we use 16 → entries start at offset 32 from $INDEX_ROOT start)
    ///        4  u32 usedSize
    ///        8  u32 allocatedSize
    ///        12 u8  flags: 0 (no LARGE_INDEX — resident only)
    ///        13 3 bytes padding
    ///   32  INDEX_ENTRY[] (sorted, terminated by LAST sentinel)
    static func buildIndexRootBody(
        indexAllocationBlockSize: UInt32,
        clustersPerIndexBlock: Int8,
        sortedEntries: [(fileReference: UInt64, fileNameBody: Data)]
    ) -> Data {
        // Serialize all entries followed by the LAST sentinel.
        var entriesBytes = Data()
        for entry in sortedEntries {
            entriesBytes.append(serializeEntry(
                fileReference: entry.fileReference,
                fileNameBody: entry.fileNameBody
            ))
        }
        entriesBytes.append(serializeLastSentinel())

        // INDEX_HEADER's usedSize = entries bytes + 16 (the header itself).
        // allocatedSize = same as usedSize for a tightly-packed resident root.
        let entriesOffset: UInt32 = 16    // entries start right after the 16-byte INDEX_HEADER
        let usedSize: UInt32 = UInt32(16 + entriesBytes.count)
        let allocatedSize: UInt32 = usedSize

        // 16 header bytes for the $INDEX_ROOT preamble + 16 for INDEX_HEADER + entries.
        var body = Data(count: 32 + entriesBytes.count)
        MFTRecord.writeU32LE(into: &body, at: 0,  value: 0x30)                    // attributeTypeIndexed
        MFTRecord.writeU32LE(into: &body, at: 4,  value: 0x01)                    // COLLATION_FILENAME
        MFTRecord.writeU32LE(into: &body, at: 8,  value: indexAllocationBlockSize)
        body[body.startIndex + 12] = UInt8(bitPattern: clustersPerIndexBlock)
        // 13-15: zero padding (already)

        // INDEX_HEADER at offset 16
        MFTRecord.writeU32LE(into: &body, at: 16, value: entriesOffset)
        MFTRecord.writeU32LE(into: &body, at: 20, value: usedSize)
        MFTRecord.writeU32LE(into: &body, at: 24, value: allocatedSize)
        body[body.startIndex + 28] = 0                                            // flags: not LARGE_INDEX
        // 29-31: zero padding

        // Entry bytes at offset 32
        for (i, byte) in entriesBytes.enumerated() {
            body[body.startIndex + 32 + i] = byte
        }

        return body
    }

    /// NTFS COLLATION_FILENAME sort comparator. Returns true if `a` should
    /// sort before `b`. NTFS uses uppercase Unicode comparison via the
    /// volume's $UpCase table; Stage 3b approximates with Swift's
    /// case-insensitive localized comparison. For ASCII names the result
    /// is identical; non-ASCII may sort slightly differently than Windows
    /// would. Either way the volume remains structurally valid.
    static func collationFilenameSortsBefore(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }
}
