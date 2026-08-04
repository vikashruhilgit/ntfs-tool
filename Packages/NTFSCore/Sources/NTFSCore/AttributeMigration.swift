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

    /// v0.7 multi-extension migration result.
    ///
    /// `newBaseBytes` is the rewritten base record carrying the previously
    /// existing `$ATTRIBUTE_LIST` plus ONE additional entry of the same
    /// `(attributeType, name)` family with `lowestVCN == splitVCN` and
    /// `mftReference == (newExtSeq << 48) | newExtRN`.
    /// `newExtensionBytes` is the freshly-built extension MFT record holding
    /// the suffix attribute (with `startingVCN == splitVCN`).
    public struct AdditionalExtensionResult: Sendable, Equatable {
        public let newBaseBytes: Data
        public let newExtensionBytes: Data

        public init(newBaseBytes: Data, newExtensionBytes: Data) {
            self.newBaseBytes = newBaseBytes
            self.newExtensionBytes = newExtensionBytes
        }
    }

    /// Build a migration of a single named-or-unnamed attribute (identified by
    /// `migratingType` + `migratingName`) out of the base record and into a new
    /// extension record, adding a resident `$ATTRIBUTE_LIST` to the base in its
    /// place that names every attribute the file still owns.
    ///
    /// The migrant is the unique attribute whose `type == migratingType` and
    /// `name == migratingName` (use `""` for unnamed attributes). For example
    /// `migratingType: AttributeType.indexAllocation.rawValue, migratingName: "$I30"`
    /// migrates a directory's index allocation; `migratingType:
    /// AttributeType.data.rawValue, migratingName: ""` migrates an unnamed
    /// `$DATA`.
    ///
    /// Throws `NTFSError.corruptOnDisk` if the base record holds no attribute
    /// matching the requested type/name. Throws `NTFSError.unsupportedFeature`
    /// if the resident `$ATTRIBUTE_LIST` itself does not fit in the base
    /// record's slack — non-resident `$ATTRIBUTE_LIST` is deferred to v0.5+.
    ///
    /// `newAttributeBytes` (v0.5 Fix B Step 4): when non-nil, the extension
    /// record holds THESE bytes for the migrant instead of the verbatim copy
    /// taken from the base record. This is the `$DATA`-overflow path: the
    /// caller has just grown a file's non-resident `$DATA` past the base
    /// record's slack and wants the freshly-built (would-overflow) `$DATA`
    /// attribute persisted in the extension, NOT the stale resident/old
    /// `$DATA` that is still on the base. The substitute bytes MUST carry the
    /// SAME attribute ID and SAME `startingVCN` (0 for an unsplit attribute)
    /// as the migrant they replace, so the `$ATTRIBUTE_LIST` entry — which is
    /// built from the *scanned migrant's* attributeID / startingVCN — stays
    /// coherent with what physically lands in the extension. (The unnamed
    /// `$DATA` write paths satisfy this: they serialize with
    /// `dataAttr.header.attributeID` and VCN 0, exactly the migrant's values.)
    /// When nil (the `$INDEX_ALLOCATION` path) the migrant is moved verbatim
    /// and the output is byte-identical to the pre-Step-4 behaviour.
    public static func buildAttributeMigration(
        baseRecordBytes: Data,
        baseRN: UInt64,
        baseSeq: UInt16,
        extRN: UInt64,
        extSeq: UInt16,
        migratingType: UInt32,
        migratingName: String,
        recordSize: Int,
        sectorSize: Int,
        newAttributeBytes: Data? = nil
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
        //   - the migrant (matching migratingType/migratingName) bytes specifically
        let scan = try scanAttributes(
            in: baseRecordBytes,
            firstAttributeOffset: Int(firstAttrOffset),
            usedSize: baseUsedSize
        )

        guard let migrantIndex = scan.firstIndex(where: { entry in
            entry.type == migratingType && entry.name == migratingName
        }) else {
            // The migrant isn't in the base. Two cases:
            //   1. Base already carries a $ATTRIBUTE_LIST → migrant has already
            //      been migrated to an extension record in a prior pass. The
            //      caller (leaf-split / file-grow) overflowed AGAIN, this time
            //      because the EXTENSION record itself filled up — i.e. the
            //      attribute now needs MULTI-EXTENSION coverage (a second
            //      extension record + a second $ATTRIBUTE_LIST entry at a
            //      higher lowest_vcn). Not yet implemented; this is the genuine
            //      next structural ceiling (v0.7). Throw a clean,
            //      user-actionable `unsupportedFeature` — NOT `corruptOnDisk`,
            //      which would scare users into running chkdsk on a perfectly
            //      consistent volume.
            //   2. Base has no $ATTRIBUTE_LIST and no migrant either → genuinely
            //      unexpected (caller invoked migration on the wrong record, or
            //      real corruption). Keep `corruptOnDisk` for this branch so
            //      it remains visible.
            let hasAttributeList = scan.contains(where: {
                $0.type == AttributeType.attributeList.rawValue
            })
            let typeHex = String(migratingType, radix: 16, uppercase: true)
            if hasAttributeList {
                throw NTFSError.unsupportedFeature(
                    description: """
                        This directory (or file) has grown beyond what this version supports in a single MFT extension record. \
                        Attribute type 0x\(typeHex) name '\(migratingName)' is already migrated to an extension, and that extension's runlist now overflows too — a second extension record (multi-extension $ATTRIBUTE_LIST) is required. \
                        Workaround until v0.7: split the data across multiple subdirectories so no single directory accumulates this many entries / fragments. \
                        Tracking: v0.7 multi-extension $INDEX_ALLOCATION (see docs/STATUS.md).
                        """
                )
            }
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration: base record has no attribute type 0x\(typeHex) name '\(migratingName)' to migrate, and no $ATTRIBUTE_LIST to redirect via — likely a programmer error (migration invoked on the wrong record) or real on-disk corruption."
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
        // the migrant, with the new $ATTRIBUTE_LIST spliced in at its canonical
        // sorted position (type 0x20 — after $STANDARD_INFORMATION, before
        // $FILE_NAME), then the end marker.
        let attrsStart = Int(firstAttrOffset)
        let newAttrs = composeAttributeStream(
            recordBytes: baseRecordBytes,
            surviving: scan.enumerated().filter { $0.offset != migrantIndex }.map(\.element),
            insertBytes: attrListBytes,
            insertType: AttributeType.attributeList.rawValue,
            insertName: "",
            insertStartingVCN: 0
        )

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
        MFTRecord.writeU32LE(into: &newBase, at: 24, value: MFTRecord.align8UsedSize(newUsedSize))
        MFTRecord.writeU16LE(into: &newBase, at: 40, value: nextAttrID &+ 1)

        // Build the extension record holding the migrated attribute. By
        // default this is the migrant copied VERBATIM out of the base
        // ($INDEX_ALLOCATION path). For the $DATA-overflow path the caller
        // supplies `newAttributeBytes` — the freshly-built (would-overflow)
        // $DATA attribute — and the extension holds THOSE bytes so the new
        // content is what persists. The $ATTRIBUTE_LIST entry above already
        // references the migrant by its scanned attributeID + startingVCN, so
        // the substitute bytes must agree (see this function's doc comment).
        let migrantBytes: Data
        if let substitute = newAttributeBytes {
            migrantBytes = substitute
        } else {
            migrantBytes = baseRecordBytes.subdata(
                in: (baseRecordBytes.startIndex + migrant.start)..<(baseRecordBytes.startIndex + migrant.start + migrant.length)
            )
        }
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

    /// v0.7 — multi-extension `$ATTRIBUTE_LIST` builder. Used when the
    /// migrant (`migratingType:migratingName`) is ALREADY migrated to an
    /// existing extension record, and that extension's own runlist is now
    /// too large to fit a single MFT record. The caller allocates a fresh
    /// extension slot and computes the runlist split at an extent boundary,
    /// then asks this builder to:
    ///
    ///   1. Append an ADDITIONAL `$ATTRIBUTE_LIST` entry to the base record
    ///      naming the same `(attributeType, name)` pair with
    ///      `lowestVCN == splitVCN` and `mftReference == new extension`.
    ///   2. Re-sort the `$ATTRIBUTE_LIST` body canonically
    ///      `(attributeType, name UTF-16, lowestVCN)`.
    ///   3. Build a fresh extension MFT record carrying `suffixAttributeBytes`
    ///      with `baseFileReference = (baseSeq << 48) | baseRN`.
    ///
    /// Pure / no I/O. Inputs are all bytes; outputs are post-fix-up bytes
    /// suitable for `MFT.writeRawRecord` (the caller is responsible for the
    /// USA reverseFixup, just like `buildAttributeMigration`).
    ///
    /// The caller MUST also separately rewrite the *existing* extension's
    /// record to truncate its runlist to the surviving prefix (covering
    /// VCN `0..splitVCN-1` for a `lowestVCN==0` first extent, generally
    /// `firstVCN..splitVCN-1` for higher extents); that rewrite lives in
    /// `Volume` because it requires the runlist encoder and is record-shape
    /// dependent. This builder does NOT touch the existing extension.
    ///
    /// ### Split-point heuristic (AC-4, measurement-driven)
    ///
    /// The caller picks `splitVCN` such that the surviving-prefix runlist
    /// (the existing extension's truncated runlist, re-serialized via the
    /// canonical `encodeRunlist`) is `<= 50% of (recordSize - fixed_attribute_overhead)`.
    /// "Fixed overhead" = the existing extension's attribute header
    /// (16 bytes common header + 48 bytes non-resident extension + UTF-16
    /// name + alignment + the MFT record header + end marker). The 50%
    /// threshold leaves headroom so the runlist can grow on subsequent leaf
    /// splits without immediately re-splitting (the "oscillation" failure
    /// mode the AC-4 unit test guards against).
    ///
    /// Split at an **extent boundary** only — never mid-extent. This keeps
    /// the runlist-encoded bytes well-defined and avoids the variable-width
    /// encoding hazards mid-extent splits would invite. NTFS runlist
    /// encoding is variable-width per extent (signed-delta + length), so
    /// analytical "K from extent count" can mis-budget; measure the actual
    /// encoded bytes.
    ///
    /// ### Parameters
    ///
    /// - `baseRecordBytes`: the current base record (carrying the existing
    ///   resident `$ATTRIBUTE_LIST` with N entries; this builder produces
    ///   one with N+1 entries).
    /// - `migratingType` / `migratingName`: the attribute family being
    ///   extended (e.g. `0xA0` / `"$I30"`).
    /// - `migrantAttributeID`: the existing migrant's attribute ID. Multi-
    ///   extent NTFS attributes share the same attribute ID across all
    ///   their extents; the new `$ATTRIBUTE_LIST` entry MUST use it.
    /// - `newExtRN` / `newExtSeq`: identity of the freshly-allocated
    ///   extension MFT slot.
    /// - `splitVCN`: the new extension's `lowestVCN` (= first VCN it
    ///   covers, = `lastVCN_of_surviving_prefix + 1`).
    /// - `suffixAttributeBytes`: the caller-built attribute blob (header +
    ///   non-resident extension + runlist for VCNs `splitVCN..lastVCN`)
    ///   to splice into the new extension record. Header MUST carry
    ///   `startingVCN == splitVCN`.
    /// - `recordSize` / `sectorSize`: same constants the base record was
    ///   built with.
    ///
    /// ### Returns
    ///
    /// `AdditionalExtensionResult.newBaseBytes` and `.newExtensionBytes`.
    /// Both are post-fix-up byte images.
    public static func buildAdditionalExtensionForAttribute(
        baseRecordBytes: Data,
        baseRN: UInt64,
        baseSeq: UInt16,
        migratingType: UInt32,
        migratingName: String,
        migrantAttributeID: UInt16,
        newExtRN: UInt64,
        newExtSeq: UInt16,
        splitVCN: UInt64,
        suffixAttributeBytes: Data,
        recordSize: Int,
        sectorSize: Int
    ) throws -> AdditionalExtensionResult {
        guard baseRecordBytes.count == recordSize else {
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration.buildAdditionalExtensionForAttribute: base record size \(baseRecordBytes.count) != expected \(recordSize)"
            )
        }
        guard recordSize >= 256, sectorSize > 2, recordSize % sectorSize == 0 else {
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration.buildAdditionalExtensionForAttribute: invalid recordSize \(recordSize) / sectorSize \(sectorSize)"
            )
        }
        guard splitVCN > 0 else {
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration.buildAdditionalExtensionForAttribute: splitVCN must be > 0 (the new extension can't start at VCN 0)"
            )
        }

        // Re-read the base record header in the same way `MFTRecord.parse` does.
        let firstAttrOffset = Int(try baseRecordBytes.readU16LE(at: 20))
        let baseUsedSize = Int(try baseRecordBytes.readU32LE(at: 24))
        let nextAttrID = try baseRecordBytes.readU16LE(at: 40)

        let scan = try scanAttributes(
            in: baseRecordBytes,
            firstAttributeOffset: firstAttrOffset,
            usedSize: baseUsedSize
        )

        // Find the existing $ATTRIBUTE_LIST attribute.
        guard let attrListIdx = scan.firstIndex(where: {
            $0.type == AttributeType.attributeList.rawValue
        }) else {
            throw NTFSError.corruptOnDisk(
                description: "AttributeMigration.buildAdditionalExtensionForAttribute: base record has no $ATTRIBUTE_LIST to extend"
            )
        }
        let attrListAttr = scan[attrListIdx]

        // Read the resident $ATTRIBUTE_LIST body (non-resident is a separate
        // ceiling, not yet handled at this entry point).
        let nonResidentByte = try baseRecordBytes.readU8(at: attrListAttr.start + 8)
        guard nonResidentByte == 0 else {
            throw NTFSError.unsupportedFeature(
                description: "buildAdditionalExtensionForAttribute: non-resident $ATTRIBUTE_LIST not supported yet"
            )
        }
        let valueLength = Int(try baseRecordBytes.readU32LE(at: attrListAttr.start + 16))
        let valueOffset = Int(try baseRecordBytes.readU16LE(at: attrListAttr.start + 20))
        let bodyStart = attrListAttr.start + valueOffset
        let body = baseRecordBytes.subdata(
            in: (baseRecordBytes.startIndex + bodyStart)..<(baseRecordBytes.startIndex + bodyStart + valueLength)
        )
        var entries = try AttributeListEntry.parseAll(in: body)

        // Append the new entry naming the new extension at lowestVCN=splitVCN.
        let newEntry = AttributeListEntry.make(
            attributeType: migratingType,
            attributeName: migratingName,
            recordNumber: newExtRN,
            sequenceNumber: newExtSeq,
            attributeID: migrantAttributeID,
            lowestVCN: splitVCN
        )
        entries.append(newEntry)

        // NTFS canonical sort: (attributeType, name UTF-16 binary, lowestVCN).
        entries.sort { a, b in
            if a.attributeType != b.attributeType { return a.attributeType < b.attributeType }
            let an = Array(a.name.utf16), bn = Array(b.name.utf16)
            if an.lexicographicallyPrecedes(bn) { return true }
            if bn.lexicographicallyPrecedes(an) { return false }
            return a.lowestVCN < b.lowestVCN
        }

        let newAttrListBody = serializeAttributeListBody(entries)
        // Reuse the existing $ATTRIBUTE_LIST attribute ID; only the body grows.
        let newAttrListBytes = buildResidentAttribute(
            type: AttributeType.attributeList.rawValue,
            attrID: attrListAttr.attributeID,
            flags: 0,
            value: newAttrListBody
        )

        // Compose the new base attribute stream: every existing attribute
        // EXCEPT the old $ATTRIBUTE_LIST, with the rebuilt one spliced back in
        // at its canonical sorted position, then the end marker. Preserves the
        // stream order of every non-$ATTRIBUTE_LIST attribute.
        //
        // The byte position DOES matter: NTFS requires ascending
        // (type, name, startingVCN) within a record, and chkdsk enforces it.
        let attrsStart = firstAttrOffset
        let newAttrs = composeAttributeStream(
            recordBytes: baseRecordBytes,
            surviving: scan.enumerated().filter { $0.offset != attrListIdx }.map(\.element),
            insertBytes: newAttrListBytes,
            insertType: AttributeType.attributeList.rawValue,
            insertName: "",
            insertStartingVCN: 0
        )

        let newUsedSize = attrsStart + newAttrs.count + 4
        guard newUsedSize <= recordSize else {
            throw NTFSError.unsupportedFeature(
                description: "buildAdditionalExtensionForAttribute: enlarged $ATTRIBUTE_LIST exceeds base record slack — non-resident $ATTRIBUTE_LIST not yet implemented"
            )
        }

        var newBase = Data(count: recordSize)
        for i in 0..<attrsStart {
            newBase[newBase.startIndex + i] = baseRecordBytes[baseRecordBytes.startIndex + i]
        }
        for (i, byte) in newAttrs.enumerated() {
            newBase[newBase.startIndex + attrsStart + i] = byte
        }
        MFTRecord.writeU32LE(into: &newBase, at: attrsStart + newAttrs.count, value: AttributeType.endMarker)
        MFTRecord.writeU32LE(into: &newBase, at: 24, value: MFTRecord.align8UsedSize(newUsedSize))
        // nextAttributeID doesn't need to bump: the new $ATTRIBUTE_LIST reuses
        // the existing attribute ID; the new extension reuses the migrant's
        // attribute ID (multi-extent attributes share IDs across extents).
        // Preserve the existing value verbatim.
        MFTRecord.writeU16LE(into: &newBase, at: 40, value: nextAttrID)

        // Build the new extension record carrying the suffix attribute blob.
        let baseRef = packMFTReference(recordNumber: baseRN, sequenceNumber: baseSeq)
        let newExt = try MFTRecord.buildExtensionRecord(
            recordNumber: newExtRN,
            sequenceNumber: newExtSeq,
            baseFileReference: baseRef,
            attributesBytes: suffixAttributeBytes,
            // The suffix shares its attribute ID with the prefix (multi-extent
            // attributes); the extension's own nextAttributeID must still be
            // greater than that, since any future attribute added to this
            // extension picks IDs from this counter.
            nextAttributeID: migrantAttributeID &+ 1,
            recordSize: recordSize,
            sectorSize: sectorSize
        )

        return AdditionalExtensionResult(
            newBaseBytes: newBase,
            newExtensionBytes: newExt
        )
    }

    /// Build a migration of the unique `$INDEX_ALLOCATION:$I30` attribute out
    /// of the base record and into a new extension record, adding a resident
    /// `$ATTRIBUTE_LIST` to the base in its place.
    ///
    /// Thin wrapper over `buildAttributeMigration` for the directory-index case.
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
        try buildAttributeMigration(
            baseRecordBytes: baseRecordBytes,
            baseRN: baseRN,
            baseSeq: baseSeq,
            extRN: extRN,
            extSeq: extSeq,
            migratingType: AttributeType.indexAllocation.rawValue,
            migratingName: "$I30",
            recordSize: recordSize,
            sectorSize: sectorSize
        )
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

    // MARK: — Canonical attribute ordering within a record

    /// NTFS orders the attributes *within* an MFT record ascending by
    /// `(type code, name UTF-16 binary, startingVCN)` — the same key the
    /// `$ATTRIBUTE_LIST` body uses. Windows `chkdsk` enforces this and
    /// reports "Attribute records for file record segment N are unsorted"
    /// when it's violated.
    ///
    /// Both migration builders previously *appended* the `$ATTRIBUTE_LIST`
    /// (type 0x20) to the end of the stream, landing it after `$FILE_NAME`
    /// (0x30) — on the belief, stated in a since-corrected comment, that
    /// stream position didn't matter as long as the body contents were
    /// sorted. A real `chkdsk /f` run on a 15,997-record volume flagged
    /// every migrated base record. Our own reader is order-agnostic, so
    /// nothing on this side ever noticed.
    static func attributeSortsBefore(
        lhsType: UInt32, lhsName: String, lhsStartingVCN: UInt64,
        rhsType: UInt32, rhsName: String, rhsStartingVCN: UInt64
    ) -> Bool {
        if lhsType != rhsType { return lhsType < rhsType }
        let ln = Array(lhsName.utf16), rn = Array(rhsName.utf16)
        if ln.lexicographicallyPrecedes(rn) { return true }
        if rn.lexicographicallyPrecedes(ln) { return false }
        return lhsStartingVCN < rhsStartingVCN
    }

    /// Rebuild a record's attribute stream from `surviving` (kept in their
    /// existing relative order, which is already canonical) with
    /// `insertBytes` spliced in at its sorted position rather than appended.
    static func composeAttributeStream(
        recordBytes: Data,
        surviving: [ScannedAttribute],
        insertBytes: Data,
        insertType: UInt32,
        insertName: String,
        insertStartingVCN: UInt64
    ) -> Data {
        var out = Data()
        var inserted = false
        for attr in surviving {
            if !inserted,
               attributeSortsBefore(
                   lhsType: insertType, lhsName: insertName, lhsStartingVCN: insertStartingVCN,
                   rhsType: attr.type, rhsName: attr.name, rhsStartingVCN: attr.startingVCN
               ) {
                out.append(insertBytes)
                inserted = true
            }
            out.append(recordBytes[
                (recordBytes.startIndex + attr.start)..<(recordBytes.startIndex + attr.start + attr.length)
            ])
        }
        // Sorts after everything that survived (e.g. a record holding only
        // $STANDARD_INFORMATION) — the tail IS the canonical position.
        if !inserted { out.append(insertBytes) }
        return out
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
