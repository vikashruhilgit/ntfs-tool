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

    /// Last-resort self-relative NTFS security descriptor: owner/group =
    /// Administrators (S-1-5-32-544), DACL = a single inheritable
    /// ACCESS_ALLOWED ACE granting **Everyone (S-1-1-0) Full Control**
    /// (0x001F01FF).
    ///
    /// This is the legacy NTFS **1.2** representation — an inline
    /// `$SECURITY_DESCRIPTOR` (type 0x50) on the file itself. Modern NTFS 3.x
    /// (Windows 2000+) instead stores descriptors centrally in `$Secure` and
    /// references them by a `security_id` in `$STANDARD_INFORMATION`; on a v3
    /// volume ntfs-3g writes a `security_id` and removes any inline 0x50. We
    /// therefore prefer inheriting a `security_id` (see `Volume.createFile`)
    /// and only emit this inline SD as a fallback on volumes that carry NO
    /// security_id anywhere to inherit (our own formatter's images, ntfs-3g
    /// v1.x images). Such volumes read inline SDs natively; whether a modern
    /// Windows volume would accept an inline-only file is unverified, so this
    /// path is deliberately the last resort, not the default.
    public static let everyoneFullControlSD: [UInt8] = [
        0x01, 0x00, 0x04, 0x80,                         // rev 1, control 0x8004 (DACL_PRESENT|SELF_RELATIVE)
        0x14, 0x00, 0x00, 0x00,                         // owner offset = 20
        0x24, 0x00, 0x00, 0x00,                         // group offset = 36
        0x00, 0x00, 0x00, 0x00,                         // SACL offset = 0 (none)
        0x34, 0x00, 0x00, 0x00,                         // DACL offset = 52
        0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // owner SID S-1-5-32-544
        0x20, 0x00, 0x00, 0x00, 0x20, 0x02, 0x00, 0x00,
        0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // group SID S-1-5-32-544
        0x20, 0x00, 0x00, 0x00, 0x20, 0x02, 0x00, 0x00,
        0x02, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x00, // ACL rev 2, size 0x1C, 1 ACE
        0x00, 0x03, 0x14, 0x00, 0xFF, 0x01, 0x1F, 0x00, // ACE: ALLOW, OI|CI, size 0x14, mask FULL
        0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // SID S-1-1-0 (Everyone)
        0x00, 0x00, 0x00, 0x00,
    ]


    public let recordSize: Int          // typically 1024
    public let sectorSize: Int          // typically 512
    public let recordNumber: UInt32     // self MFT number
    public let sequenceNumber: UInt16   // bumped each time the slot is reused
    public let isDirectory: Bool        // sets flags bit 1

    public let fileName: String
    public let parentReference: UInt64  // (parentSeq << 48) | parentRecord
    public let nowFiletime: UInt64      // shared across all four timestamps
    /// Inherited NTFS 3.x security id (indexes into $Secure). When non-nil the
    /// $STANDARD_INFORMATION is emitted in the 72-byte v3.0 form carrying this
    /// id, so Windows can resolve the file's ACL. nil → 48-byte v1.2 form (no
    /// security id) — used on volumes whose own system files lack one (e.g.
    /// ntfs-3g-formatted images). WITHOUT a valid security id on a Windows-
    /// formatted volume, Windows denies all access ("you do not have
    /// permission to open this file"), so `Volume.createFile` inherits the
    /// parent directory's id (falling back to the volume root's).
    public let securityID: UInt32?
    /// Inline self-relative security descriptor (NTFS $SECURITY_DESCRIPTOR,
    /// type 0x50) inherited from the parent or volume root — the legacy NTFS
    /// 1.2 fallback used only when no `securityID` is available to inherit.
    /// nil → no $SECURITY_DESCRIPTOR attribute emitted. Mutually exclusive with
    /// `securityID` in practice (we set one or the other, never both).
    public let securityDescriptor: Data?
    /// Final data-stream sizes to stamp into the file's own $FILE_NAME (0x30)
    /// size fields. chkdsk cross-checks the $FILE_NAME copy in the file's MFT
    /// record against the copy in the parent's $I30 index entry (and against
    /// $DATA), so these MUST match the size we put in the $I30 entry — leaving
    /// them 0 while $DATA is non-empty is a mismatch chkdsk flags/"repairs".
    /// For a file written via `writeFile` after creation, pass the eventual
    /// $DATA size here. 0 for empty files and directories.
    public let dataRealSize: UInt64
    public let dataAllocatedSize: UInt64

    public init(
        recordSize: Int = 1024,
        sectorSize: Int = 512,
        recordNumber: UInt32,
        sequenceNumber: UInt16,
        isDirectory: Bool,
        fileName: String,
        parentReference: UInt64,
        nowFiletime: UInt64 = MFTRecordBuilder.windowsFiletimeNow(),
        securityID: UInt32? = nil,
        securityDescriptor: Data? = nil,
        dataRealSize: UInt64 = 0,
        dataAllocatedSize: UInt64 = 0
    ) {
        self.recordSize = recordSize
        self.sectorSize = sectorSize
        self.recordNumber = recordNumber
        self.sequenceNumber = sequenceNumber
        self.isDirectory = isDirectory
        self.fileName = fileName
        self.parentReference = parentReference
        self.nowFiletime = nowFiletime
        self.securityID = securityID
        self.securityDescriptor = securityDescriptor
        self.dataRealSize = dataRealSize
        self.dataAllocatedSize = dataAllocatedSize
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
        // nextAttributeID ("first available attribute identifier") is written
        // below, AFTER the attributes — it must be (highest assigned id + 1).
        // A hardcoded 3 was correct only for the 3-attribute v3 layout; on the
        // 4-attribute v1.2 inline-SD layout (ids 0,1,2,3) it left an attribute
        // whose id == first-available, which real Windows chkdsk deletes as a
        // "corrupt attribute record".
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

        // 3) $SECURITY_DESCRIPTOR (type 0x50, resident) inherited from the
        //    parent — emitted in ascending type order (after $FILE_NAME 0x30,
        //    before $DATA 0x80 / $INDEX_ROOT 0x90). Required for Windows to
        //    grant access on volumes whose root carries an inline SD.
        var bodyAttrID: UInt16 = 2
        if let sd = securityDescriptor, !sd.isEmpty {
            cursor = try writeResidentAttribute(
                into: &data,
                at: cursor,
                type: 0x50,
                attrID: 2,
                valueBytes: sd
            )
            bodyAttrID = 3
        }

        // 4) Type-discriminated body attribute:
        //    - File:      $DATA (0x80) resident, empty body.
        //    - Directory: $INDEX_ROOT (0x90) with attribute name $I30 and an
        //                 empty $I30 body (just the INDEX_ROOT preamble +
        //                 INDEX_HEADER + LAST sentinel). Without this, the
        //                 new directory has no enumerable index and any
        //                 attempt to descend into it would fail.
        if isDirectory {
            cursor = try writeNamedResidentAttribute(
                into: &data,
                at: cursor,
                type: 0x90,
                attrID: bodyAttrID,
                attributeName: "$I30",
                valueBytes: emptyIndexRootBody()
            )
        } else {
            cursor = try writeResidentAttribute(
                into: &data,
                at: cursor,
                type: 0x80,
                attrID: bodyAttrID,
                valueBytes: Data()
            )
        }

        // 4) End marker.
        guard cursor + 4 <= recordSize else {
            throw NTFSError.corruptOnDisk(
                description: "MFTRecordBuilder: record overflow (cursor \(cursor) + 4 > \(recordSize))"
            )
        }
        MFTRecord.writeU32LE(into: &data, at: cursor, value: 0xFFFF_FFFF)
        cursor += 4

        // nextAttributeID = highest assigned id + 1. `bodyAttrID` is the id of
        // the last attribute written ($DATA/$INDEX_ROOT), so it is the maximum.
        MFTRecord.writeU16LE(into: &data, at: 40, value: bodyAttrID + 1)

        // Fill in usedSize now that we know it — 8-byte aligned (Windows/mkntfs
        // convention; chkdsk corrects an unaligned "first free byte offset").
        MFTRecord.writeU32LE(into: &data, at: 24, value: MFTRecord.align8UsedSize(cursor))

        return data
    }

    // MARK: — Attribute body builders

    private func standardInformationBody() -> Data {
        // 72-byte v3.0 form when we have a security id to carry (NTFS 3.x /
        // Windows volumes); 48-byte v1.2 form otherwise.
        let v3 = securityID != nil
        var data = Data(count: v3 ? 72 : 48)
        MFTRecord.writeU64LE(into: &data, at: 0,  value: nowFiletime)   // creation
        MFTRecord.writeU64LE(into: &data, at: 8,  value: nowFiletime)   // modification
        MFTRecord.writeU64LE(into: &data, at: 16, value: nowFiletime)   // mft change
        MFTRecord.writeU64LE(into: &data, at: 24, value: nowFiletime)   // access
        MFTRecord.writeU32LE(into: &data, at: 32, value: 0x20)         // fileAttributes = ARCHIVE (matches ntfs-3g; $STD_INFO has no dir bit)
        MFTRecord.writeU32LE(into: &data, at: 36, value: 0)             // maxVersions
        MFTRecord.writeU32LE(into: &data, at: 40, value: 0)             // version
        MFTRecord.writeU32LE(into: &data, at: 44, value: 0)             // classID
        if v3 {
            MFTRecord.writeU32LE(into: &data, at: 48, value: 0)              // ownerID
            MFTRecord.writeU32LE(into: &data, at: 52, value: securityID!)    // securityID → $Secure
            MFTRecord.writeU64LE(into: &data, at: 56, value: 0)             // quotaCharged
            MFTRecord.writeU64LE(into: &data, at: 64, value: 0)             // USN
        }
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
        MFTRecord.writeU64LE(into: &data, at: 40, value: dataAllocatedSize)  // allocatedSize (matches $I30 + $DATA)
        MFTRecord.writeU64LE(into: &data, at: 48, value: dataRealSize)       // realSize (matches $I30 + $DATA)
        MFTRecord.writeU32LE(into: &data, at: 56, value: isDirectory ? 0x1000_0020 : 0x20)   // fileAttributes: DIR|ARCHIVE / ARCHIVE
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
        // Resident "indexed" flag (RESIDENT_ATTR_IS_INDEXED, 0x01): set iff this
        // attribute's value is duplicated in an index. $FILE_NAME (0x30) is
        // indexed in the parent directory's $I30, so Windows/ntfs-3g set this to
        // 1 for $FILE_NAME (and 0 for everything else). Leaving it 0 makes real
        // Windows chkdsk reject the $FILE_NAME attribute record as corrupt and
        // delete it ("Deleting corrupt attribute record (0x30)"), orphaning the
        // file — even though ntfs-3g and our own reader accept it. Verified
        // against ntfs-3g-authored records (Tests Fixtures/small.img).
        data[data.startIndex + offset + 22] = (type == 0x30) ? 1 : 0     // indexedFlag
        data[data.startIndex + offset + 23] = 0                          // padding

        // Body bytes.
        for (i, byte) in valueBytes.enumerated() {
            data[data.startIndex + offset + Int(valueOffset) + i] = byte
        }

        return offset + alignedLength
    }

    /// Build the body of an empty $INDEX_ROOT:$I30 attribute. Layout matches
    /// IndexRoot.parse / IndexBuilder.buildIndexRootBody: 16-byte preamble +
    /// 16-byte INDEX_HEADER + 16-byte LAST sentinel = 48 bytes total.
    private func emptyIndexRootBody() -> Data {
        var body = Data(count: 48)
        // Preamble.
        MFTRecord.writeU32LE(into: &body, at: 0,  value: 0x30)              // attributeTypeIndexed = $FILE_NAME
        MFTRecord.writeU32LE(into: &body, at: 4,  value: 0x01)              // COLLATION_FILENAME
        MFTRecord.writeU32LE(into: &body, at: 8,  value: 4096)              // indexAllocationBlockSize (4 KiB default)
        body[body.startIndex + 12] = 1                                       // clustersPerIndexBlock (1 if blockSize == clusterSize, fine for 4096/4096)
        // INDEX_HEADER at offset 16.
        MFTRecord.writeU32LE(into: &body, at: 16, value: 16)                // entriesOffset (relative to header start)
        MFTRecord.writeU32LE(into: &body, at: 20, value: 32)                // usedSize: header + LAST sentinel
        MFTRecord.writeU32LE(into: &body, at: 24, value: 32)                // allocatedSize matches usedSize for empty
        body[body.startIndex + 28] = 0                                       // flags: not LARGE_INDEX
        // LAST sentinel at offset 32 (16 bytes).
        MFTRecord.writeU64LE(into: &body, at: 32, value: 0)                  // fileReference (unused)
        MFTRecord.writeU16LE(into: &body, at: 40, value: 16)                 // entryLength
        MFTRecord.writeU16LE(into: &body, at: 42, value: 0)                  // keyLength
        MFTRecord.writeU16LE(into: &body, at: 44, value: 0x02)               // flags: LAST
        MFTRecord.writeU16LE(into: &body, at: 46, value: 0)                  // reserved
        return body
    }

    /// Write a resident attribute that carries a UTF-16 name (e.g. $INDEX_ROOT:$I30).
    /// Layout: 16-byte common header + 8-byte resident extension + name bytes +
    /// value bytes, 8-byte aligned.
    private func writeNamedResidentAttribute(
        into data: inout Data,
        at offset: Int,
        type: UInt32,
        attrID: UInt16,
        attributeName: String,
        valueBytes: Data
    ) throws -> Int {
        let nameUTF16 = Array(attributeName.utf16)
        let nameByteCount = nameUTF16.count * 2
        let bodyLength = valueBytes.count
        let rawLength = 16 + 8 + nameByteCount + bodyLength
        let alignedLength = ((rawLength + 7) / 8) * 8
        let nameOffset: UInt16 = 24
        let valueOffset: UInt16 = UInt16(24 + nameByteCount)

        guard offset + alignedLength + 4 <= recordSize else {
            throw NTFSError.corruptOnDisk(
                description: "MFTRecordBuilder: named attribute type 0x\(String(format: "%02X", type)) doesn't fit at offset \(offset)"
            )
        }

        MFTRecord.writeU32LE(into: &data, at: offset + 0,  value: type)
        MFTRecord.writeU32LE(into: &data, at: offset + 4,  value: UInt32(alignedLength))
        data[data.startIndex + offset + 8]  = 0                          // resident
        data[data.startIndex + offset + 9]  = UInt8(nameUTF16.count)
        MFTRecord.writeU16LE(into: &data, at: offset + 10, value: nameOffset)
        MFTRecord.writeU16LE(into: &data, at: offset + 12, value: 0)     // flags
        MFTRecord.writeU16LE(into: &data, at: offset + 14, value: attrID)

        MFTRecord.writeU32LE(into: &data, at: offset + 16, value: UInt32(bodyLength))
        MFTRecord.writeU16LE(into: &data, at: offset + 20, value: valueOffset)
        data[data.startIndex + offset + 22] = 0                          // indexedFlag
        data[data.startIndex + offset + 23] = 0                          // padding

        for (i, codeUnit) in nameUTF16.enumerated() {
            data[data.startIndex + offset + Int(nameOffset) + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[data.startIndex + offset + Int(nameOffset) + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
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
