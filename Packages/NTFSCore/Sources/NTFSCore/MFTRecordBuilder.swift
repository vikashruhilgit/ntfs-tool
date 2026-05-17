import Foundation

// Constructs a fresh MFT record from scratch — the inverse of MFTRecord.parse
// for files we're CREATING rather than reading. Used by Volume.createFile.
//
// Layout produced (for a typical file):
//   header (56 bytes; 16 of those reserved for USA at offset 48)
//   $STANDARD_INFORMATION resident attribute  (24 + 48 body = 72 bytes)
//   $FILE_NAME resident attribute             (24 + 66+N*2 body, 8-byte aligned)
//   $DATA resident attribute (empty payload)  (24 bytes total)
//   end marker 0xFFFFFFFF                     (4 bytes)
//
// All offsets within attributes are 8-byte aligned per NTFS spec; the builder
// rounds each attribute's `length` field up to the next multiple of 8.
public struct MFTRecordBuilder {

    public let recordSize: Int          // typically 1024
    public let sectorSize: Int          // typically 512
    public let recordNumber: UInt32     // self MFT number
    public let sequenceNumber: UInt16   // bumped each time the slot is reused
    public let isDirectory: Bool        // sets flags bit 1

    public let fileName: String
    public let parentReference: UInt64  // (parentSeq << 48) | parentRecord
    public let nowFiletime: UInt64      // shared across all four timestamps

    public init(
        recordSize: Int = 1024,
        sectorSize: Int = 512,
        recordNumber: UInt32,
        sequenceNumber: UInt16,
        isDirectory: Bool,
        fileName: String,
        parentReference: UInt64,
        nowFiletime: UInt64 = MFTRecordBuilder.windowsFiletimeNow()
    ) {
        self.recordSize = recordSize
        self.sectorSize = sectorSize
        self.recordNumber = recordNumber
        self.sequenceNumber = sequenceNumber
        self.isDirectory = isDirectory
        self.fileName = fileName
        self.parentReference = parentReference
        self.nowFiletime = nowFiletime
    }

    /// Build the post-fix-up bytes (the form `MFTRecord.parse` consumes).
    /// Call MFTRecord.serialize on the result before writing to disk.
    public func build() throws -> Data {
        // Validate sizes first.
        guard recordSize >= 256, recordSize % sectorSize == 0 else {
            throw NTFSError.corruptOnDisk(
                description: "MFTRecordBuilder: recordSize \(recordSize) invalid"
            )
        }
        let fileNameUTF16 = Array(fileName.utf16)
        guard fileNameUTF16.count <= 255 else {
            throw NTFSError.corruptOnDisk(
                description: "MFTRecordBuilder: name too long (\(fileNameUTF16.count) chars)"
            )
        }

        var data = Data(count: recordSize)

        // USA at offset 48: 1 sentinel + N fix-ups (N = recordSize/sectorSize).
        let usaOffset: UInt16 = 48
        let fixupCount = recordSize / sectorSize
        let usaCount = UInt16(1 + fixupCount)
        // 16 bytes reserved for USA + space for fix-ups. usaCount*2 bytes used.
        // First attribute starts at next 8-byte boundary after USA.
        let firstAttrOffset: UInt16 = UInt16(((Int(usaOffset) + Int(usaCount) * 2 + 7) / 8) * 8)

        // Header — values for a freshly-created in-use base record.
        MFTRecord.writeU32LE(into: &data, at: 0,  value: MFTRecord.magicFILE)
        MFTRecord.writeU16LE(into: &data, at: 4,  value: usaOffset)
        MFTRecord.writeU16LE(into: &data, at: 6,  value: usaCount)
        MFTRecord.writeU64LE(into: &data, at: 8,  value: 0)                              // LSN
        MFTRecord.writeU16LE(into: &data, at: 16, value: sequenceNumber)
        MFTRecord.writeU16LE(into: &data, at: 18, value: 1)                              // hardLinkCount
        MFTRecord.writeU16LE(into: &data, at: 20, value: firstAttrOffset)
        let flagsValue: UInt16 = isDirectory ? 0x0003 : 0x0001                            // IN_USE | (DIRECTORY if dir)
        MFTRecord.writeU16LE(into: &data, at: 22, value: flagsValue)
        // 24: usedSize — filled in after we know how much we consumed
        MFTRecord.writeU32LE(into: &data, at: 28, value: UInt32(recordSize))             // allocatedSize
        MFTRecord.writeU64LE(into: &data, at: 32, value: 0)                              // baseFileReference (base record)
        MFTRecord.writeU16LE(into: &data, at: 40, value: 3)                              // nextAttributeID (after the 3 we write)
        MFTRecord.writeU32LE(into: &data, at: 44, value: recordNumber)

        // USA[0] sentinel — pick 1 (NTFS uses any non-zero; the reverseFixup
        // path will bump to 2 on first write). USA[1..N] start at 0; reverseFixup
        // populates them from the original block-tail bytes (which are 0).
        MFTRecord.writeU16LE(into: &data, at: Int(usaOffset), value: 1)

        // Attributes start at firstAttrOffset.
        var cursor = Int(firstAttrOffset)

        // 1) $STANDARD_INFORMATION (type 0x10, resident, 48-byte body for v1.2 layout).
        cursor = try writeResidentAttribute(
            into: &data,
            at: cursor,
            type: 0x10,
            attrID: 0,
            valueBytes: standardInformationBody()
        )

        // 2) $FILE_NAME (type 0x30, resident, 66 + N*2 body).
        cursor = try writeResidentAttribute(
            into: &data,
            at: cursor,
            type: 0x30,
            attrID: 1,
            valueBytes: fileNameBody(fileNameUTF16: fileNameUTF16)
        )

        // 3) $DATA (type 0x80, resident, 0-byte body for an empty file).
        cursor = try writeResidentAttribute(
            into: &data,
            at: cursor,
            type: 0x80,
            attrID: 2,
            valueBytes: Data()
        )

        // 4) End marker.
        guard cursor + 4 <= recordSize else {
            throw NTFSError.corruptOnDisk(
                description: "MFTRecordBuilder: record overflow (cursor \(cursor) + 4 > \(recordSize))"
            )
        }
        MFTRecord.writeU32LE(into: &data, at: cursor, value: 0xFFFF_FFFF)
        cursor += 4

        // Fill in usedSize now that we know it.
        MFTRecord.writeU32LE(into: &data, at: 24, value: UInt32(cursor))

        return data
    }

    // MARK: — Attribute body builders

    private func standardInformationBody() -> Data {
        var data = Data(count: 48)   // v1.2 body — fits NTFS 3.0+ as a subset
        MFTRecord.writeU64LE(into: &data, at: 0,  value: nowFiletime)   // creation
        MFTRecord.writeU64LE(into: &data, at: 8,  value: nowFiletime)   // modification
        MFTRecord.writeU64LE(into: &data, at: 16, value: nowFiletime)   // mft change
        MFTRecord.writeU64LE(into: &data, at: 24, value: nowFiletime)   // access
        MFTRecord.writeU32LE(into: &data, at: 32, value: 0)             // fileAttributes
        MFTRecord.writeU32LE(into: &data, at: 36, value: 0)             // maxVersions
        MFTRecord.writeU32LE(into: &data, at: 40, value: 0)             // version
        MFTRecord.writeU32LE(into: &data, at: 44, value: 0)             // classID
        return data
    }

    private func fileNameBody(fileNameUTF16: [UInt16]) -> Data {
        let nameByteCount = fileNameUTF16.count * 2
        var data = Data(count: 66 + nameByteCount)
        MFTRecord.writeU64LE(into: &data, at: 0,  value: parentReference)
        MFTRecord.writeU64LE(into: &data, at: 8,  value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 16, value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 24, value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 32, value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 40, value: 0)              // allocatedSize (stale by design)
        MFTRecord.writeU64LE(into: &data, at: 48, value: 0)              // realSize (stale by design)
        MFTRecord.writeU32LE(into: &data, at: 56, value: isDirectory ? 0x1000_0000 : 0)   // fileAttributes
        MFTRecord.writeU32LE(into: &data, at: 60, value: 0)              // EA/reparse union
        data[64] = UInt8(fileNameUTF16.count)
        data[65] = 1                                                     // namespace = Win32
        for (i, codeUnit) in fileNameUTF16.enumerated() {
            data[66 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[66 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        return data
    }

    /// Write a resident attribute into `data` starting at `offset`, returning
    /// the offset of the byte after the attribute (8-byte aligned).
    private func writeResidentAttribute(
        into data: inout Data,
        at offset: Int,
        type: UInt32,
        attrID: UInt16,
        valueBytes: Data
    ) throws -> Int {
        // Common header (16) + resident extension (8) + value body, 8-byte aligned.
        let bodyLength = valueBytes.count
        let rawLength = 16 + 8 + bodyLength
        let alignedLength = ((rawLength + 7) / 8) * 8
        let valueOffset: UInt16 = 24

        guard offset + alignedLength + 4 <= recordSize else {
            // +4 for end marker
            throw NTFSError.corruptOnDisk(
                description: "MFTRecordBuilder: attribute type 0x\(String(format: "%02X", type)) doesn't fit at offset \(offset)"
            )
        }

        // Common header.
        MFTRecord.writeU32LE(into: &data, at: offset + 0,  value: type)
        MFTRecord.writeU32LE(into: &data, at: offset + 4,  value: UInt32(alignedLength))
        data[data.startIndex + offset + 8]  = 0                          // resident
        data[data.startIndex + offset + 9]  = 0                          // nameLength
        MFTRecord.writeU16LE(into: &data, at: offset + 10, value: 0)     // nameOffset
        MFTRecord.writeU16LE(into: &data, at: offset + 12, value: 0)     // flags
        MFTRecord.writeU16LE(into: &data, at: offset + 14, value: attrID)

        // Resident extension.
        MFTRecord.writeU32LE(into: &data, at: offset + 16, value: UInt32(bodyLength))
        MFTRecord.writeU16LE(into: &data, at: offset + 20, value: valueOffset)
        data[data.startIndex + offset + 22] = 0                          // indexedFlag
        data[data.startIndex + offset + 23] = 0                          // padding

        // Body bytes.
        for (i, byte) in valueBytes.enumerated() {
            data[data.startIndex + offset + Int(valueOffset) + i] = byte
        }

        return offset + alignedLength
    }

    // MARK: — Time helpers

    /// Convert a `Date` to a Windows FILETIME (100-ns intervals since 1601).
    /// Inverse of FileName's internal helper.
    public static func windowsFiletime(from date: Date) -> UInt64 {
        let secondsBetweenEpochs: TimeInterval = 11_644_473_600
        let intervals = (date.timeIntervalSince1970 + secondsBetweenEpochs) * 10_000_000
        return UInt64(max(0, intervals))
    }

    public static func windowsFiletimeNow() -> UInt64 {
        windowsFiletime(from: Date())
    }
}
