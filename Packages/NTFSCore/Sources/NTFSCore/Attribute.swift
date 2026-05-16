import Foundation

// One NTFS attribute parsed out of an MFT record. The attribute's metadata
// lives in `header`; the actual content (resident value bytes, or extents +
// sizes for a non-resident attribute) lives in `value`.
//
// On-disk layout reference (Linux-NTFS):
//
//   Common header (16 bytes):
//     0  u32 type
//     4  u32 total record length (header + value/runs + padding)
//     8  u8  non-resident flag (0 = resident, 1 = non-resident)
//     9  u8  name length (UTF-16 chars, not bytes)
//    10  u16 name offset
//    12  u16 flags (0x0001 = compressed, 0x4000 = encrypted, 0x8000 = sparse)
//    14  u16 attribute ID
//
//   Resident extension (8 bytes):
//    16  u32 value length (bytes)
//    20  u16 value offset (relative to attribute start)
//    22  u8  indexed flag
//    23  u8  padding
//
//   Non-resident extension (48 bytes, content is a runlist starting at dataRunsOffset):
//    16  u64 starting VCN
//    24  u64 last VCN
//    32  u16 data runs offset (relative to attribute start)
//    34  u8  compression unit (0 for uncompressed; actual cluster count is 1 << value)
//    35  u8  reserved[5] — 5 bytes of zero padding through offset 39
//    40  u64 allocated size
//    48  u64 real size
//    56  u64 initialized size
public struct Attribute: Sendable, Equatable {
    public let header: AttributeHeader
    public let value: AttributeValue

    public var type: AttributeType? { header.type }
    public var rawType: UInt32 { header.rawType }
    public var nameOrEmpty: String { header.name ?? "" }
}

public struct AttributeHeader: Sendable, Equatable {
    public let rawType: UInt32
    public let length: UInt32
    public let nonResident: Bool
    public let nameLength: UInt8
    public let nameOffset: UInt16
    public let flags: UInt16
    public let attributeID: UInt16
    public let name: String?

    public var type: AttributeType? { AttributeType(rawValue: rawType) }

    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let compressed = Flags(rawValue: 0x0001)
        public static let encrypted  = Flags(rawValue: 0x4000)
        public static let sparse     = Flags(rawValue: 0x8000)
    }
    public var flagSet: Flags { Flags(rawValue: flags) }
}

public enum AttributeValue: Sendable, Equatable {
    case resident(value: Data, indexed: Bool)
    case nonResident(
        startingVCN: UInt64,
        lastVCN: UInt64,
        dataRunsOffset: UInt16,
        compressionUnit: UInt8,
        allocatedSize: UInt64,
        realSize: UInt64,
        initializedSize: UInt64,
        extents: [Extent]
    )

    public var residentBytes: Data? {
        if case let .resident(value, _) = self { return value }
        return nil
    }

    public var nonResidentExtents: [Extent]? {
        if case let .nonResident(_, _, _, _, _, _, _, extents) = self { return extents }
        return nil
    }
}

public extension Attribute {
    /// Iterate the attributes of an MFT record. The caller supplies the record
    /// bytes (with USA fix-up already applied) and the offset to the first
    /// attribute (typically `MFTRecord.firstAttributeOffset`). Iteration stops
    /// at the 0xFFFFFFFF end marker or when the record's `usedSize` is reached.
    static func iterate(
        recordBytes data: Data,
        firstAttributeOffset: Int,
        usedSize: Int
    ) throws -> [Attribute] {
        var attributes: [Attribute] = []
        var cursor = firstAttributeOffset
        let upperBound = min(usedSize, data.count)

        while cursor + 4 <= upperBound {
            let typeRaw = try data.readU32LE(at: cursor)
            if typeRaw == AttributeType.endMarker { break }

            // The common header is 16 bytes. We need at least that much to
            // read `length` and the resident/non-resident flag.
            guard cursor + 16 <= upperBound else {
                throw NTFSError.corruptOnDisk(
                    description: "attribute at offset \(cursor) is truncated (need 16 bytes for header, have \(upperBound - cursor))"
                )
            }

            let length = try data.readU32LE(at: cursor + 4)
            guard length >= 16 else {
                throw NTFSError.corruptOnDisk(
                    description: "attribute at offset \(cursor) reports length \(length) < 16-byte minimum header"
                )
            }
            // Walk lengths must be 8-byte aligned per NTFS spec; we don't enforce
            // it strictly (some real-world records relax this) but we do require
            // that the attribute fits inside the record's used region.
            guard cursor + Int(length) <= upperBound else {
                throw NTFSError.corruptOnDisk(
                    description: "attribute at offset \(cursor) extends past record's used region (\(cursor + Int(length)) > \(upperBound))"
                )
            }

            let nonResidentByte = try data.readU8(at: cursor + 8)
            let nameLength      = try data.readU8(at: cursor + 9)
            let nameOffset      = try data.readU16LE(at: cursor + 10)
            let flags           = try data.readU16LE(at: cursor + 12)
            let attrID          = try data.readU16LE(at: cursor + 14)

            let name: String?
            if nameLength > 0 {
                let nameByteCount = Int(nameLength) * 2  // UTF-16 chars
                guard Int(nameOffset) >= 16 else {
                    throw NTFSError.corruptOnDisk(
                        description: "attribute name offset \(nameOffset) overlaps the 16-byte common header"
                    )
                }
                guard Int(nameOffset) + nameByteCount <= Int(length) else {
                    throw NTFSError.corruptOnDisk(
                        description: "attribute name at offset \(cursor + Int(nameOffset)) length \(nameByteCount) exceeds attribute body"
                    )
                }
                let nameStart = cursor + Int(nameOffset)
                let nameBytes = data[(data.startIndex + nameStart)..<(data.startIndex + nameStart + nameByteCount)]
                name = decodeUTF16LE(nameBytes)
            } else {
                name = nil
            }

            let header = AttributeHeader(
                rawType: typeRaw,
                length: length,
                nonResident: (nonResidentByte != 0),
                nameLength: nameLength,
                nameOffset: nameOffset,
                flags: flags,
                attributeID: attrID,
                name: name
            )

            let value: AttributeValue
            if nonResidentByte == 0 {
                value = try parseResidentValue(data: data, attributeStart: cursor, length: Int(length))
            } else {
                value = try parseNonResidentValue(data: data, attributeStart: cursor, length: Int(length))
            }

            attributes.append(Attribute(header: header, value: value))
            cursor += Int(length)
        }

        return attributes
    }

    private static func parseResidentValue(
        data: Data,
        attributeStart: Int,
        length: Int
    ) throws -> AttributeValue {
        // Need at least the resident extension (8 more bytes).
        guard length >= 24 else {
            throw NTFSError.corruptOnDisk(
                description: "resident attribute too short: length \(length) < 24"
            )
        }
        let valueLength = try data.readU32LE(at: attributeStart + 16)
        let valueOffset = try data.readU16LE(at: attributeStart + 20)
        let indexedFlag = try data.readU8(at: attributeStart + 22)

        guard Int(valueOffset) + Int(valueLength) <= length else {
            throw NTFSError.corruptOnDisk(
                description: "resident value [offset \(valueOffset), length \(valueLength)] exceeds attribute body \(length)"
            )
        }

        let valueStart = attributeStart + Int(valueOffset)
        let valueEnd = valueStart + Int(valueLength)
        let value = Data(data[(data.startIndex + valueStart)..<(data.startIndex + valueEnd)])
        return .resident(value: value, indexed: indexedFlag != 0)
    }

    private static func parseNonResidentValue(
        data: Data,
        attributeStart: Int,
        length: Int
    ) throws -> AttributeValue {
        // Need at least common header (16) + non-resident extension (48) = 64.
        guard length >= 64 else {
            throw NTFSError.corruptOnDisk(
                description: "non-resident attribute too short: length \(length) < 64"
            )
        }
        let startingVCN     = try data.readU64LE(at: attributeStart + 16)
        let lastVCN         = try data.readU64LE(at: attributeStart + 24)
        let dataRunsOffset  = try data.readU16LE(at: attributeStart + 32)
        let compressionUnit = try data.readU8(at: attributeStart + 34)
        let allocatedSize   = try data.readU64LE(at: attributeStart + 40)
        let realSize        = try data.readU64LE(at: attributeStart + 48)
        let initializedSize = try data.readU64LE(at: attributeStart + 56)

        guard Int(dataRunsOffset) >= 64, Int(dataRunsOffset) < length else {
            throw NTFSError.corruptOnDisk(
                description: "non-resident dataRunsOffset \(dataRunsOffset) out of range for attribute length \(length)"
            )
        }

        let runsStart = attributeStart + Int(dataRunsOffset)
        let runsEnd = attributeStart + length
        let runsSlice = Data(data[(data.startIndex + runsStart)..<(data.startIndex + runsEnd)])
        let extents = try DataRun.decode(runsSlice)

        return .nonResident(
            startingVCN: startingVCN,
            lastVCN: lastVCN,
            dataRunsOffset: dataRunsOffset,
            compressionUnit: compressionUnit,
            allocatedSize: allocatedSize,
            realSize: realSize,
            initializedSize: initializedSize,
            extents: extents
        )
    }

}
