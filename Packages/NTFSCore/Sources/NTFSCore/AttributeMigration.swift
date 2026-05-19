import Foundation

// Pure in-memory byte builder for the v0.5 Fix B Step 3 write path:
// migrating a directory's `$INDEX_ALLOCATION` attribute out of its base
// MFT record into a freshly-allocated extension record, and dropping a
// resident `$ATTRIBUTE_LIST` (type 0x20) into the base that names every
// attribute the file still owns.
//
// Why: at ~350 files in one directory the runlist for `$INDEX_ALLOCATION:$I30`
// outgrows the base record's slack and `rewriteParentForLeafSplit` throws
// "would overflow record". The mature NTFS fix is to keep bulky non-resident
// attributes in extension records and reference them from a `$ATTRIBUTE_LIST`
// on the base. Both fs/ntfs3 and NTFS-3G do this; chkdsk verifies it.
//
// This file is pure: no I/O, no `Volume`, no `async`. Callers feed it the
// existing base record bytes (post-fix-up — the form `MFTRecord.parse`
// returns) plus the freshly-allocated extension record number/sequence,
// and get back the rewritten base bytes and a fresh extension record.
// Both outputs are post-fix-up; the caller is responsible for
// `UpdateSequenceArray.reverseFixup` before they hit disk (e.g. via
// `MFT.writeRawRecord`).

public enum AttributeMigration {

    public struct Result: Sendable, Equatable {
        public let newBaseBytes: Data
        public let newExtBytes: Data

        public init(newBaseBytes: Data, newExtBytes: Data) {
            self.newBaseBytes = newBaseBytes
            self.newExtBytes = newExtBytes
        }
    }

    /// Build a migration of the unique `$INDEX_ALLOCATION:$I30` attribute out
    /// of the base record and into a new extension record, adding a resident
    /// `$ATTRIBUTE_LIST` to the base in its place.
    ///
    /// Throws `NTFSError.unsupportedFeature` if the resident `$ATTRIBUTE_LIST`
    /// itself does not fit in the base record's slack — non-resident
    /// `$ATTRIBUTE_LIST` is deferred to v0.5+.
    public static func buildIndexAllocationMigration(
        baseRecordBytes: Data,
        baseRN: UInt64,
        baseSeq: UInt16,
        extRN: UInt64,
        extSeq: UInt16,
        recordSize: Int,
        sectorSize: Int
    ) throws -> Result {
        guard baseRecordBytes.count == recordSize else {
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration: base record size \(baseRecordBytes.count) != expected \(recordSize)"
            )
        }
        guard recordSize >= 256, sectorSize > 2, recordSize % sectorSize == 0 else {
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration: invalid recordSize \(recordSize) / sectorSize \(sectorSize)"
            )
        }

        // Re-read the base record header in the same way `MFTRecord.parse` does
        // so we preserve all fields the caller didn't ask us to change. We only
        // need the attribute-stream slice + used/next-ID — the USA region and
        // every other header byte get copied verbatim below.
        let firstAttrOffset = try baseRecordBytes.readU16LE(at: 20)
        let baseUsedSize = Int(try baseRecordBytes.readU32LE(at: 24))
        let nextAttrID = try baseRecordBytes.readU16LE(at: 40)

        // Walk the base attribute stream once, collecting:
        //   - the bytes of every attribute (so we can splice them back)
        //   - per-attribute (type, name, attrID, startingVCN) for the
        //     $ATTRIBUTE_LIST entries
        //   - the migrant ($INDEX_ALLOCATION:$I30) bytes specifically
        let scan = try scanAttributes(
            in: baseRecordBytes,
            firstAttributeOffset: Int(firstAttrOffset),
            usedSize: baseUsedSize
        )

        guard let migrantIndex = scan.firstIndex(where: { entry in
            entry.type == AttributeType.indexAllocation.rawValue && entry.name == "$I30"
        }) else {
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration: base record has no $INDEX_ALLOCATION:$I30 to migrate"
            )
        }
        let migrant = scan[migrantIndex]

        // Build the $ATTRIBUTE_LIST entries: one per attribute the file owns.
        // Every non-migrant attribute points back at the base record; the
        // migrant points at the new extension record.
        let baseRef = packMFTReference(recordNumber: baseRN, sequenceNumber: baseSeq)
        let extRef  = packMFTReference(recordNumber: extRN,  sequenceNumber: extSeq)

        var listEntries: [AttributeListEntry] = []
        for (idx, attr) in scan.enumerated() {
            let entry = AttributeListEntry.make(
                attributeType: attr.type,
                attributeName: attr.name,
                recordNumber: idx == migrantIndex ? extRN : baseRN,
                sequenceNumber: idx == migrantIndex ? extSeq : baseSeq,
                attributeID: attr.attributeID,
                lowestVCN: attr.startingVCN
            )
            // The `make` helper builds the mftReference internally; assert it
            // matches what we expect so a future change to the helper can't
            // silently drift this contract.
            let expectedRef = idx == migrantIndex ? extRef : baseRef
            precondition(entry.mftReference == expectedRef)
            listEntries.append(entry)
        }

        // NTFS canonical sort: (attributeType, name UTF-16 binary, lowestVCN).
        listEntries.sort { a, b in
            if a.attributeType != b.attributeType { return a.attributeType < b.attributeType }
            let an = Array(a.name.utf16), bn = Array(b.name.utf16)
            if an.lexicographicallyPrecedes(bn) { return true }
            if bn.lexicographicallyPrecedes(an) { return false }
            return a.lowestVCN < b.lowestVCN
        }

        let attrListBody = serializeAttributeListBody(listEntries)
        let attrListAttrID = nextAttrID
        let attrListBytes = buildResidentAttribute(
            type: AttributeType.attributeList.rawValue,
            attrID: attrListAttrID,
            flags: 0,
            value: attrListBody
        )

        // Compose the new base attribute stream: every existing attribute EXCEPT
        // the migrant, then the new $ATTRIBUTE_LIST, then the end marker.
        let attrsStart = Int(firstAttrOffset)
        var newAttrs = Data()
        for (idx, attr) in scan.enumerated() where idx != migrantIndex {
            newAttrs.append(baseRecordBytes[
                (baseRecordBytes.startIndex + attr.start)..<(baseRecordBytes.startIndex + attr.start + attr.length)
            ])
        }
        newAttrs.append(attrListBytes)

        // Verify the new stream fits with room for the end marker (4 bytes).
        let newUsedSize = attrsStart + newAttrs.count + 4
        guard newUsedSize <= recordSize else {
            throw NTFSError.unsupportedFeature(
                description: "Fix B Step 3.5: $ATTRIBUTE_LIST exceeds parent slack — non-resident $ATTRIBUTE_LIST not yet implemented"
            )
        }

        // Build the new base record bytes. Preserve the existing header + USA
        // region; only rewrite the attribute stream + usedSize + nextAttrID.
        var newBase = Data(count: recordSize)
        // Copy original header + USA + any padding before firstAttrOffset.
        for i in 0..<attrsStart {
            newBase[newBase.startIndex + i] = baseRecordBytes[baseRecordBytes.startIndex + i]
        }
        // Splice in the new attribute stream.
        for (i, byte) in newAttrs.enumerated() {
            newBase[newBase.startIndex + attrsStart + i] = byte
        }
        // End marker.
        MFTRecord.writeU32LE(into: &newBase, at: attrsStart + newAttrs.count, value: AttributeType.endMarker)
        // Updated header fields.
        MFTRecord.writeU32LE(into: &newBase, at: 24, value: UInt32(newUsedSize))
        MFTRecord.writeU16LE(into: &newBase, at: 40, value: nextAttrID &+ 1)

        // Build the extension record holding just the migrated $INDEX_ALLOCATION.
        let migrantBytes = baseRecordBytes.subdata(
            in: (baseRecordBytes.startIndex + migrant.start)..<(baseRecordBytes.startIndex + migrant.start + migrant.length)
        )
        let newExt = try MFTRecord.buildExtensionRecord(
            recordNumber: extRN,
            sequenceNumber: extSeq,
            baseFileReference: baseRef,
            // The migrated attribute keeps its existing attribute ID — the
            // $ATTRIBUTE_LIST entry above pointed at it by that ID. Both base
            // and extension advertise the SAME file-wide next ID so future
            // allocations from either side stay collision-free.
            attributesBytes: migrantBytes,
            nextAttributeID: nextAttrID &+ 1,
            recordSize: recordSize,
            sectorSize: sectorSize
        )

        return Result(newBaseBytes: newBase, newExtBytes: newExt)
    }

    // MARK: — Internal raw attribute scan

    /// One attribute as it appears in the base record's byte stream.
    struct ScannedAttribute: Equatable {
        let start: Int            // byte offset from start of record
        let length: Int           // attribute total length on disk (includes 8-byte align)
        let type: UInt32
        let attributeID: UInt16
        let name: String          // "" if unnamed
        let nonResident: Bool
        let startingVCN: UInt64   // 0 for resident; first VCN for non-resident
    }

    static func scanAttributes(
        in data: Data,
        firstAttributeOffset: Int,
        usedSize: Int
    ) throws -> [ScannedAttribute] {
        var out: [ScannedAttribute] = []
        var cursor = firstAttributeOffset
        let upperBound = min(usedSize, data.count)

        while cursor + 4 <= upperBound {
            let type = try data.readU32LE(at: cursor)
            if type == AttributeType.endMarker { break }
            guard cursor + 16 <= upperBound else {
                throw NTFSError.corruptOnDisk(
                    description: "AttributeMigration.scan: truncated attribute header at offset \(cursor)"
                )
            }
            let length = Int(try data.readU32LE(at: cursor + 4))
            guard length >= 16, cursor + length <= upperBound else {
                throw NTFSError.corruptOnDisk(
                    description: "AttributeMigration.scan: attribute at \(cursor) length \(length) overruns record"
                )
            }
            let nonResidentByte = try data.readU8(at: cursor + 8)
            let nameLength      = try data.readU8(at: cursor + 9)
            let nameOffset      = try data.readU16LE(at: cursor + 10)
            let attrID          = try data.readU16LE(at: cursor + 14)

            var name = ""
            if nameLength > 0 {
                let nameByteCount = Int(nameLength) * 2
                guard Int(nameOffset) >= 16,
                      Int(nameOffset) + nameByteCount <= length else {
                    throw NTFSError.corruptOnDisk(
                        description: "AttributeMigration.scan: bad name range at offset \(cursor)"
                    )
                }
                let nameStart = cursor + Int(nameOffset)
                let nameBytes = data[(data.startIndex + nameStart)..<(data.startIndex + nameStart + nameByteCount)]
                name = decodeUTF16LE(nameBytes) ?? ""
            }

            var startingVCN: UInt64 = 0
            if nonResidentByte != 0 {
                guard length >= 24 else {
                    throw NTFSError.corruptOnDisk(
                        description: "AttributeMigration.scan: non-resident attribute too short at \(cursor)"
                    )
                }
                startingVCN = try data.readU64LE(at: cursor + 16)
            }

            out.append(ScannedAttribute(
                start: cursor,
                length: length,
                type: type,
                attributeID: attrID,
                name: name,
                nonResident: nonResidentByte != 0,
                startingVCN: startingVCN
            ))
            cursor += length
        }
        return out
    }

    // MARK: — Resident-attribute byte builder (small, local to this file)

    /// Build a resident attribute with no name. Mirrors the layout
    /// `MFTRecordBuilder.writeResidentAttribute` produces but emits bytes
    /// rather than writing into a buffer at an offset.
    static func buildResidentAttribute(
        type: UInt32,
        attrID: UInt16,
        flags: UInt16,
        value: Data
    ) -> Data {
        let bodyLength = value.count
        let rawLen = 16 + 8 + bodyLength
        let alignedLen = ((rawLen + 7) / 8) * 8
        let valueOffset: UInt16 = 24
        var data = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &data, at: 0,  value: type)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 0                                // resident
        data[data.startIndex + 9] = 0                                // nameLength
        MFTRecord.writeU16LE(into: &data, at: 10, value: 0)          // nameOffset
        MFTRecord.writeU16LE(into: &data, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        MFTRecord.writeU32LE(into: &data, at: 16, value: UInt32(bodyLength))
        MFTRecord.writeU16LE(into: &data, at: 20, value: valueOffset)
        data[data.startIndex + 22] = 0
        data[data.startIndex + 23] = 0
        for (i, byte) in value.enumerated() {
            data[data.startIndex + Int(valueOffset) + i] = byte
        }
        return data
    }

    @inline(__always)
    static func packMFTReference(recordNumber: UInt64, sequenceNumber: UInt16) -> UInt64 {
        (UInt64(sequenceNumber) << 48) | (recordNumber & 0x0000_FFFF_FFFF_FFFF)
    }
}
