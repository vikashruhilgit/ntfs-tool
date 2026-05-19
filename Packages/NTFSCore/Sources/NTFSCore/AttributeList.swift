import Foundation

/// $ATTRIBUTE_LIST (type 0x20) entry layout.
///
/// When a file's attributes don't all fit in its base MFT record, NTFS
/// allocates extension records (with `base_file_reference` pointing back
/// at the base record) and moves bulky attributes there. The base record
/// gets a `$ATTRIBUTE_LIST` attribute (resident or non-resident) whose
/// body is a sequence of `AttributeListEntry`s, one per attribute. Every
/// attribute the file has — including those still in the base record —
/// gets an entry. This is how `chkdsk /f` verifies a file's attribute
/// graph and how Windows + Linux fs/ntfs3 + NTFS-3G handle huge runlists,
/// many alternate data streams, etc.
///
/// On-disk layout (26 bytes + variable-length UTF-16 name):
/// ```
///   0  u32  attribute_type     // e.g., 0xA0 for $INDEX_ALLOCATION
///   4  u16  entry_length       // total entry size, name included
///   6  u8   name_length        // UTF-16 code units (NOT bytes)
///   7  u8   name_offset        // from start of entry; typically 26
///   8  u64  lowest_vcn         // 0 if attribute is unfragmented or resident
///  16  u64  mft_reference      // 48-bit recnum + 16-bit sequence in high bits
///  24  u16  attribute_id       // matches the attribute_id in the attr header
///  26  u8*  name (UTF-16 LE)   // optional, length = name_length * 2 bytes
/// ```
///
/// Entries are sorted by (type, name, lowest_vcn) ascending so the file's
/// attributes appear in a deterministic order.
public struct AttributeListEntry: Equatable, Sendable {
    public let attributeType: UInt32
    public let entryLength: Int        // total on-disk size, 8-byte-aligned
    public let nameLength: Int         // UTF-16 code units
    public let nameOffset: Int         // byte offset from start of entry
    public let lowestVCN: UInt64
    public let mftReference: UInt64    // 48-bit recnum + 16-bit sequence in high bits
    public let attributeID: UInt16
    public let name: String            // empty if nameLength == 0

    public var recordNumber: UInt64 {
        mftReference & 0x0000_FFFF_FFFF_FFFF
    }

    public var sequenceNumber: UInt16 {
        UInt16((mftReference >> 48) & 0xFFFF)
    }

    /// Parse a sequence of entries from the $ATTRIBUTE_LIST attribute's body.
    /// Stops at the first malformed entry or at end-of-data.
    public static func parseAll(in data: Data) throws -> [AttributeListEntry] {
        var entries: [AttributeListEntry] = []
        var pos = 0
        while pos + 26 <= data.count {
            let type = try data.readU32LE(at: pos + 0)
            let entryLen = Int(try data.readU16LE(at: pos + 4))
            // entry_length == 0 is a terminator some implementations write
            if entryLen == 0 || entryLen < 26 || pos + entryLen > data.count {
                break
            }
            let nameLen = Int(data[data.startIndex + pos + 6])
            let nameOffset = Int(data[data.startIndex + pos + 7])
            let lowestVCN = try data.readU64LE(at: pos + 8)
            let mftRef = try data.readU64LE(at: pos + 16)
            let attrID = try data.readU16LE(at: pos + 24)

            var name = ""
            if nameLen > 0 {
                let nameStart = pos + nameOffset
                let nameEnd = nameStart + (nameLen * 2)
                guard nameEnd <= pos + entryLen else {
                    throw NTFSError.corruptOnDisk(
                        description: "AttributeListEntry: name region [\(nameStart)..\(nameEnd)) past entry end (entry+\(entryLen))"
                    )
                }
                let nameBytes = data.subdata(in: data.startIndex.advanced(by: nameStart)..<data.startIndex.advanced(by: nameEnd))
                name = decodeUTF16LE(nameBytes) ?? ""
            }

            entries.append(AttributeListEntry(
                attributeType: type,
                entryLength: entryLen,
                nameLength: nameLen,
                nameOffset: nameOffset,
                lowestVCN: lowestVCN,
                mftReference: mftRef,
                attributeID: attrID,
                name: name
            ))
            pos += entryLen
        }
        return entries
    }

    /// Serialize one entry to on-disk bytes. The result is 8-byte aligned
    /// per NTFS convention; callers concatenate multiple entries directly.
    public func serialize() -> Data {
        // Fixed-size header is 26 bytes. Name (if any) follows immediately.
        // Whole entry rounds up to 8-byte alignment.
        let rawLen = 26 + (nameLength * 2)
        let aligned = ((rawLen + 7) / 8) * 8
        var out = Data(count: aligned)
        MFTRecord.writeU32LE(into: &out, at: 0,  value: attributeType)
        MFTRecord.writeU16LE(into: &out, at: 4,  value: UInt16(aligned))
        out[out.startIndex + 6] = UInt8(nameLength)
        out[out.startIndex + 7] = UInt8(nameLength == 0 ? 0 : 26)  // name immediately follows header
        MFTRecord.writeU64LE(into: &out, at: 8,  value: lowestVCN)
        MFTRecord.writeU64LE(into: &out, at: 16, value: mftReference)
        MFTRecord.writeU16LE(into: &out, at: 24, value: attributeID)
        if nameLength > 0 {
            // Encode name as UTF-16 LE, exactly nameLength code units.
            let utf16 = Array(name.utf16)
            let len = min(nameLength, utf16.count)
            for i in 0..<len {
                let cu = utf16[i]
                out[out.startIndex + 26 + i * 2]     = UInt8(cu & 0xFF)
                out[out.startIndex + 26 + i * 2 + 1] = UInt8((cu >> 8) & 0xFF)
            }
        }
        return out
    }

    public init(
        attributeType: UInt32,
        entryLength: Int,
        nameLength: Int,
        nameOffset: Int,
        lowestVCN: UInt64,
        mftReference: UInt64,
        attributeID: UInt16,
        name: String
    ) {
        self.attributeType = attributeType
        self.entryLength = entryLength
        self.nameLength = nameLength
        self.nameOffset = nameOffset
        self.lowestVCN = lowestVCN
        self.mftReference = mftReference
        self.attributeID = attributeID
        self.name = name
    }

    /// Convenience: build a fresh entry pointing at a specific extension
    /// record with no name (e.g., for the unnamed $DATA or an attribute
    /// like $INDEX_ALLOCATION with its $I30 name).
    public static func make(
        attributeType: UInt32,
        attributeName: String,
        recordNumber: UInt64,
        sequenceNumber: UInt16,
        attributeID: UInt16,
        lowestVCN: UInt64 = 0
    ) -> AttributeListEntry {
        let utf16Len = attributeName.utf16.count
        let rawLen = 26 + (utf16Len * 2)
        let aligned = ((rawLen + 7) / 8) * 8
        let mftRef = (UInt64(sequenceNumber) << 48) | (recordNumber & 0x0000_FFFF_FFFF_FFFF)
        return AttributeListEntry(
            attributeType: attributeType,
            entryLength: aligned,
            nameLength: utf16Len,
            nameOffset: utf16Len == 0 ? 0 : 26,
            lowestVCN: lowestVCN,
            mftReference: mftRef,
            attributeID: attributeID,
            name: attributeName
        )
    }
}

/// Build a serialized $ATTRIBUTE_LIST body from a sequence of entries.
/// Entries are written in the order given — callers must sort
/// `(attributeType, name, lowestVCN)` ascending if Windows-compat sort
/// order matters (it does for `chkdsk /f` cleanliness).
public func serializeAttributeListBody(_ entries: [AttributeListEntry]) -> Data {
    var out = Data()
    for entry in entries {
        out.append(entry.serialize())
    }
    return out
}
