import Foundation

// A mounted-for-reading NTFS volume. Phase 1.8 surface: open + boot sector +
// MFT helper + directory enumeration ($I30) + file content reads ($DATA).
//
// All boot-derived properties are immutable + Sendable, so they're declared
// `nonisolated` to allow cross-actor reads without `await`. The mutable
// `_mft` cache is the only state that's actually actor-isolated.
//
// Later phases extend Volume with: $Bitmap queries, (Phase 5) write.
public actor Volume {
    public nonisolated let device: any BlockDevice
    public nonisolated let boot: BootSector
    public nonisolated let bytesPerCluster: UInt32
    public nonisolated let mftRecordSizeBytes: UInt32
    public nonisolated let indexRecordSizeBytes: UInt32

    private var _mft: MFT?

    public init(device: any BlockDevice) async throws {
        self.device = device

        let firstSector = try await device.read(offset: 0, length: BootSector.onDiskSize)
        let boot = try BootSector.parse(firstSector)
        self.boot = boot

        self.bytesPerCluster = UInt32(boot.bytesPerSector) * UInt32(boot.sectorsPerCluster)
        self.mftRecordSizeBytes = BootSector.resolveRecordSize(
            field: boot.clustersPerMFTRecord,
            clusterSizeBytes: bytesPerCluster
        )
        self.indexRecordSizeBytes = BootSector.resolveRecordSize(
            field: boot.clustersPerIndexRecord,
            clusterSizeBytes: bytesPerCluster
        )

        guard mftRecordSizeBytes > 0,
              mftRecordSizeBytes >= 512,
              mftRecordSizeBytes.nonzeroBitCount == 1 else {
            throw NTFSError.invalidBootSector(
                reason: "computed MFT record size \(mftRecordSizeBytes) is not a power of two >= 512"
            )
        }
    }

    /// Byte offset of the start of the MFT (record 0) on the volume.
    public nonisolated var mftByteOffset: UInt64 {
        UInt64(boot.mftCluster) * UInt64(bytesPerCluster)
    }

    public func mft() -> MFT {
        if let existing = _mft { return existing }
        let mft = MFT(volume: self)
        _mft = mft
        return mft
    }

    /// MFT record number of the $Bitmap system file. Always 6 on every NTFS
    /// volume — this is part of the NTFS spec, not a per-volume value.
    public static let bitmapRecordNumber: UInt64 = 6

    private var _bitmap: Bitmap?

    /// Read and cache the volume's $Bitmap. The $Bitmap attribute is one bit
    /// per cluster (1 = allocated, 0 = free). On the read-only mount this
    /// answer is stable for the lifetime of the Volume, so we cache it; the
    /// Phase 5b write-side allocator will invalidate the cache on mutation.
    public func bitmap() async throws -> Bitmap {
        if let cached = _bitmap { return cached }

        let mft = self.mft()
        let bitmapRecord = try await mft.record(at: Self.bitmapRecordNumber)
        let attrs = try bitmapRecord.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(
                description: "$Bitmap record \(Self.bitmapRecordNumber) has no unnamed $DATA attribute"
            )
        }

        // Total clusters the bitmap MUST describe = volume clusters total.
        let totalClusters = boot.totalSectors / UInt64(boot.sectorsPerCluster)

        switch dataAttr.value {
        case let .resident(bytes, _):
            let bm = Bitmap(bytes: bytes, clusterCount: totalClusters)
            _bitmap = bm
            return bm
        case let .nonResident(_, _, _, _, _, realSize, _, extents):
            // Walk every extent and concatenate. The $Bitmap is contiguous on
            // every healthy volume, so this is one read for typical fixtures
            // and a handful for fragmented production volumes.
            var bytes = Data()
            bytes.reserveCapacity(Int(min(realSize, UInt64(Int.max))))
            let clusterBytes = UInt64(bytesPerCluster)
            var remaining = Int(min(realSize, UInt64(Int.max)))
            for extent in extents where remaining > 0 {
                let extentLen = Int(min(extent.clusterCount * clusterBytes, UInt64(remaining)))
                if let startLCN = extent.startLCN {
                    let chunk = try await device.read(
                        offset: startLCN * clusterBytes,
                        length: extentLen
                    )
                    bytes.append(chunk)
                } else {
                    bytes.append(Data(repeating: 0, count: extentLen))
                }
                remaining -= extentLen
            }
            let bm = Bitmap(bytes: bytes, clusterCount: totalClusters)
            _bitmap = bm
            return bm
        }
    }

    /// Snapshot of cluster-allocation statistics. Cheap if `bitmap()` has
    /// already been called; otherwise pays one bitmap read.
    public struct AllocationStats: Sendable, Equatable {
        public let totalClusters: UInt64
        public let freeClusters: UInt64
        public let allocatedClusters: UInt64
        public let bytesPerCluster: UInt32

        public var totalBytes: UInt64     { totalClusters * UInt64(bytesPerCluster) }
        public var freeBytes: UInt64      { freeClusters * UInt64(bytesPerCluster) }
        public var allocatedBytes: UInt64 { allocatedClusters * UInt64(bytesPerCluster) }
    }

    public func allocationStats() async throws -> AllocationStats {
        let bm = try await bitmap()
        return AllocationStats(
            totalClusters: bm.clusterCount,
            freeClusters: bm.freeClusterCount,
            allocatedClusters: bm.allocatedClusterCount,
            bytesPerCluster: bytesPerCluster
        )
    }

    /// Create a new file or directory.
    ///
    /// Stage 3b complete: allocates an MFT slot, builds a fresh record
    /// (\$STANDARD_INFORMATION + \$FILE_NAME(parentRef) + empty \$DATA),
    /// writes it to disk, AND inserts the matching entry into the parent
    /// directory's \$I30 index so the new file is visible to enumerate()
    /// (and Finder, once mounted).
    ///
    /// Limitations:
    /// - Parent's `$INDEX_ROOT:$I30` must be small enough to absorb the
    ///   new entry without overflowing the MFT record. LARGE_INDEX
    ///   directories that already have an `$INDEX_ALLOCATION` extension
    ///   are rejected with `unsupportedFeature` — that's a future stage.
    /// - If the new entry would overflow the parent record, we roll back
    ///   the MFT allocation and throw `unsupportedFeature` rather than
    ///   leaving an orphan record.
    public func createFile(
        named name: String,
        inDirectory parentRecordNumber: UInt64 = 5,
        isDirectory: Bool = false
    ) async throws -> UInt64 {
        let mft = self.mft()
        let recordNumber = try await mft.findFreeRecordNumber()

        // For a slot that's been used before, the existing record's
        // sequenceNumber + 1 should be the new one (NTFS recycles MFT slots
        // by bumping the sequence). For never-used slots, start at 1.
        var newSequence: UInt16 = 1
        if let existing = try? await mft.record(at: recordNumber) {
            newSequence = existing.sequenceNumber &+ 1
            if newSequence == 0 { newSequence = 1 }
        }

        // Build the parent reference: 48 bits record number + 16 bits seq.
        let parent = try await mft.record(at: parentRecordNumber)
        let parentRef = (UInt64(parent.sequenceNumber) << 48) | (parentRecordNumber & 0x0000_FFFF_FFFF_FFFF)

        // 1) Write the new MFT record first so we know the slot is durably ours.
        let builder = MFTRecordBuilder(
            recordSize: Int(mftRecordSizeBytes),
            sectorSize: Int(boot.bytesPerSector),
            recordNumber: UInt32(recordNumber & 0xFFFF_FFFF),
            sequenceNumber: newSequence,
            isDirectory: isDirectory,
            fileName: name,
            parentReference: parentRef
        )
        let recordBytes = try builder.build()
        try await mft.writeRawRecord(at: recordNumber, postFixupBytes: recordBytes)

        // 2) Insert into parent's $I30. If this fails (overflow / LARGE_INDEX
        //    rejection), roll back the MFT write by zeroing IN_USE on the
        //    new record so we don't leave an orphan.
        do {
            try await insertIntoParentI30(
                parentRecordNumber: parentRecordNumber,
                childRecordNumber: recordNumber,
                childSequence: newSequence,
                childFileName: name,
                isDirectory: isDirectory,
                nowFiletime: MFTRecordBuilder.windowsFiletimeNow()
            )
        } catch {
            // Roll back the orphan record so the volume stays consistent.
            try? await deleteOrphan(at: recordNumber)
            throw error
        }

        return recordNumber
    }

    /// Rebuild the parent's MFT record with the inserted child entry in its
    /// $INDEX_ROOT:$I30. Pure resident-only path: rejects LARGE_INDEX dirs
    /// and rejects when the rewritten attribute doesn't fit in the parent
    /// record's slack space.
    private func insertIntoParentI30(
        parentRecordNumber: UInt64,
        childRecordNumber: UInt64,
        childSequence: UInt16,
        childFileName: String,
        isDirectory: Bool,
        nowFiletime: UInt64
    ) async throws {
        let mft = self.mft()
        let parent = try await mft.record(at: parentRecordNumber)
        let attrs = try parent.attributes()

        guard let indexRootAttr = attrs.first(where: {
            $0.type == .indexRoot && $0.nameOrEmpty == "$I30"
        }) else {
            throw NTFSError.corruptOnDisk(
                description: "parent record \(parentRecordNumber) lacks $INDEX_ROOT:$I30"
            )
        }
        guard case let .resident(rootBytes, _) = indexRootAttr.value else {
            throw NTFSError.corruptOnDisk(description: "$INDEX_ROOT:$I30 must be resident")
        }
        let root = try IndexRoot.parse(rootBytes)
        if root.isLargeIndex {
            throw NTFSError.unsupportedFeature(
                description: "parent directory has LARGE_INDEX ($INDEX_ALLOCATION) — insert path not yet supported"
            )
        }

        // Existing entries → (fileRef, fileNameBody) pairs we can re-serialize.
        var entries: [(fileReference: UInt64, fileNameBody: Data, sortKey: String)] = []
        for entry in root.entries {
            guard !entry.isLast, let fn = entry.fileName else { continue }
            // Slice the original key bytes out of rootBytes via the entry's
            // computed offsets. The keyLength is the in-memory entry.keyLength;
            // the body sits at the entry's first byte + 16.
            // We have the parsed FileName but not the raw bytes — re-serialize
            // a $FILE_NAME body from the parsed fields. Lossy for fields we
            // don't expose (DOS extended flags), but Stage 3b doesn't need
            // those — they're regenerated on next Windows mount anyway.
            let body = reserializeFileNameBody(fn)
            entries.append((entry.fileReference, body, fn.name))
        }

        // Build the new entry's $FILE_NAME body (parent ref points at PARENT,
        // not at the child — that's how $I30 keys are structured).
        let parentRef = (UInt64(parent.sequenceNumber) << 48) | (parentRecordNumber & 0x0000_FFFF_FFFF_FFFF)
        let childRef  = (UInt64(childSequence) << 48) | (childRecordNumber & 0x0000_FFFF_FFFF_FFFF)
        let childBody = buildFileNameBody(
            parentReference: parentRef,
            fileName: childFileName,
            isDirectory: isDirectory,
            nowFiletime: nowFiletime
        )
        entries.append((childRef, childBody, childFileName))

        // Sort by NTFS COLLATION_FILENAME (case-insensitive uppercase).
        entries.sort { IndexBuilder.collationFilenameSortsBefore($0.sortKey, $1.sortKey) }

        // Build new $INDEX_ROOT body.
        let newRootBody = IndexBuilder.buildIndexRootBody(
            indexAllocationBlockSize: root.indexAllocationBlockSize,
            clustersPerIndexBlock: root.clustersPerIndexBlock,
            sortedEntries: entries.map { ($0.fileReference, $0.fileNameBody) }
        )

        // Re-flow the parent MFT record around the new $INDEX_ROOT size.
        let newParentBytes = try rewriteResidentAttribute(
            in: parent.bytes,
            firstAttributeOffset: Int(parent.firstAttributeOffset),
            usedSize: Int(parent.usedSize),
            recordSize: Int(parent.allocatedSize),
            replacingType: AttributeType.indexRoot.rawValue,
            attributeName: "$I30",
            newValueBytes: newRootBody
        )

        // Header.usedSize must be updated too — it's the byte position of the
        // 4-byte end marker, which shifts when the $INDEX_ROOT body resizes.
        let newUsedSize = locateEndMarker(in: newParentBytes, fromOffset: Int(parent.firstAttributeOffset))
        guard let newUsedSize = newUsedSize else {
            throw NTFSError.corruptOnDisk(description: "rewritten parent record has no end marker")
        }

        var updatedBytes = newParentBytes
        MFTRecord.writeU32LE(into: &updatedBytes, at: 24, value: UInt32(newUsedSize + 4))

        try await mft.writeRawRecord(at: parentRecordNumber, postFixupBytes: updatedBytes)
    }

    /// Remove an entry from the parent's `$I30` (by name match). Same
    /// resident-only constraints as insert: LARGE_INDEX directories are
    /// rejected. Idempotent — silently no-op if the name isn't found.
    private func removeFromParentI30(
        parentRecordNumber: UInt64,
        childFileName: String
    ) async throws {
        let mft = self.mft()
        let parent = try await mft.record(at: parentRecordNumber)
        let attrs = try parent.attributes()

        guard let indexRootAttr = attrs.first(where: {
            $0.type == .indexRoot && $0.nameOrEmpty == "$I30"
        }) else {
            return  // can't find index — nothing to remove
        }
        guard case let .resident(rootBytes, _) = indexRootAttr.value else {
            return
        }
        let root = try IndexRoot.parse(rootBytes)
        if root.isLargeIndex {
            throw NTFSError.unsupportedFeature(
                description: "parent directory has LARGE_INDEX — remove path not yet supported"
            )
        }

        var entries: [(fileReference: UInt64, fileNameBody: Data, sortKey: String)] = []
        var removedAny = false
        for entry in root.entries {
            guard !entry.isLast, let fn = entry.fileName else { continue }
            if fn.name == childFileName && fn.namespace != .dos {
                removedAny = true
                continue
            }
            entries.append((entry.fileReference, reserializeFileNameBody(fn), fn.name))
        }
        guard removedAny else { return }

        entries.sort { IndexBuilder.collationFilenameSortsBefore($0.sortKey, $1.sortKey) }

        let newRootBody = IndexBuilder.buildIndexRootBody(
            indexAllocationBlockSize: root.indexAllocationBlockSize,
            clustersPerIndexBlock: root.clustersPerIndexBlock,
            sortedEntries: entries.map { ($0.fileReference, $0.fileNameBody) }
        )

        let newParentBytes = try rewriteResidentAttribute(
            in: parent.bytes,
            firstAttributeOffset: Int(parent.firstAttributeOffset),
            usedSize: Int(parent.usedSize),
            recordSize: Int(parent.allocatedSize),
            replacingType: AttributeType.indexRoot.rawValue,
            attributeName: "$I30",
            newValueBytes: newRootBody
        )
        let newUsedSize = locateEndMarker(in: newParentBytes, fromOffset: Int(parent.firstAttributeOffset))
        guard let newUsedSize = newUsedSize else {
            throw NTFSError.corruptOnDisk(description: "rewritten parent record has no end marker")
        }

        var updatedBytes = newParentBytes
        MFTRecord.writeU32LE(into: &updatedBytes, at: 24, value: UInt32(newUsedSize + 4))

        try await mft.writeRawRecord(at: parentRecordNumber, postFixupBytes: updatedBytes)
    }

    /// Find the end marker (0xFFFFFFFF type field) starting from `from
    /// Offset`. Returns the offset of the end marker's first byte, or nil
    /// if no end marker is found.
    private func locateEndMarker(in data: Data, fromOffset: Int) -> Int? {
        var cursor = fromOffset
        while cursor + 4 <= data.count {
            let type = try? data.readU32LE(at: cursor)
            if type == AttributeType.endMarker { return cursor }
            // Walk to next attribute via its length field.
            guard cursor + 8 <= data.count,
                  let length = try? data.readU32LE(at: cursor + 4),
                  length >= 16 else {
                return nil
            }
            cursor += Int(length)
        }
        return nil
    }

    /// Replace a resident attribute's body with new bytes. Walks the record's
    /// attribute chain to find the target, computes the new length, shifts
    /// all subsequent attributes by the delta, and updates the target
    /// attribute's length + value-length fields. Rejects if the new total
    /// would overflow the record's allocatedSize.
    private func rewriteResidentAttribute(
        in originalBytes: Data,
        firstAttributeOffset: Int,
        usedSize: Int,
        recordSize: Int,
        replacingType: UInt32,
        attributeName: String,
        newValueBytes: Data
    ) throws -> Data {
        // Locate the target attribute.
        var cursor = firstAttributeOffset
        var targetStart: Int?
        var targetOldLength: Int = 0
        while cursor + 4 <= usedSize {
            let type = try originalBytes.readU32LE(at: cursor)
            if type == AttributeType.endMarker { break }
            guard cursor + 16 <= usedSize else { break }
            let length = Int(try originalBytes.readU32LE(at: cursor + 4))

            // Name match.
            let nameLength = try originalBytes.readU8(at: cursor + 9)
            let nameOffset = try originalBytes.readU16LE(at: cursor + 10)
            var thisName = ""
            if nameLength > 0 {
                let nameByteCount = Int(nameLength) * 2
                let nameStart = cursor + Int(nameOffset)
                let nameBytes = originalBytes[(originalBytes.startIndex + nameStart)..<(originalBytes.startIndex + nameStart + nameByteCount)]
                thisName = decodeUTF16LE(nameBytes) ?? ""
            }

            if type == replacingType && thisName == attributeName {
                targetStart = cursor
                targetOldLength = length
                break
            }
            cursor += length
        }
        guard let targetStart = targetStart else {
            throw NTFSError.corruptOnDisk(
                description: "rewriteResidentAttribute: target type 0x\(String(format: "%08X", replacingType)) name '\(attributeName)' not found"
            )
        }

        // Compute new attribute length: 16 common header + 8 resident ext +
        // attribute name bytes + body bytes, 8-byte aligned. The name bytes
        // are CRITICAL — forgetting them is the silent off-by-N bug that
        // makes the rewritten attribute appear truncated to attribute
        // iteration.
        let newBodyLength = newValueBytes.count
        let nameByteCount = Int(attributeName.utf16.count) * 2
        let newAttrRawLength = 16 + 8 + nameByteCount + newBodyLength
        let newAttrLength = ((newAttrRawLength + 7) / 8) * 8

        // Compute new record byte usage and reject if it overflows.
        let delta = newAttrLength - targetOldLength
        let newUsedSize = usedSize + delta
        guard newUsedSize + 4 <= recordSize else {
            throw NTFSError.unsupportedFeature(
                description: "rewriteResidentAttribute: new attribute (\(newAttrLength) bytes) would overflow parent record (used \(usedSize), record \(recordSize))"
            )
        }

        // Build new record bytes.
        var out = Data(count: recordSize)
        // Copy header + USA + everything up to target start.
        for i in 0..<targetStart {
            out[out.startIndex + i] = originalBytes[originalBytes.startIndex + i]
        }

        // Write the new attribute at targetStart.
        MFTRecord.writeU32LE(into: &out, at: targetStart + 0,  value: replacingType)
        MFTRecord.writeU32LE(into: &out, at: targetStart + 4,  value: UInt32(newAttrLength))
        out[out.startIndex + targetStart + 8]  = 0    // resident
        out[out.startIndex + targetStart + 9]  = UInt8(attributeName.utf16.count)
        let nameOffset: UInt16 = 24   // resident ext is 8 bytes; name goes right after
        // For $INDEX_ROOT (the only attribute we rewrite), $I30 name lives between resident ext + value.
        // Place name immediately after resident ext (offset 24), then value after the name.
        let actualValueOffset: UInt16 = UInt16(24 + nameByteCount)
        MFTRecord.writeU16LE(into: &out, at: targetStart + 10, value: nameOffset)
        // Re-read original flags + attrID for the rewritten attribute
        let origFlags = try originalBytes.readU16LE(at: targetStart + 12)
        let origAttrID = try originalBytes.readU16LE(at: targetStart + 14)
        MFTRecord.writeU16LE(into: &out, at: targetStart + 12, value: origFlags)
        MFTRecord.writeU16LE(into: &out, at: targetStart + 14, value: origAttrID)

        // Resident extension at +16.
        MFTRecord.writeU32LE(into: &out, at: targetStart + 16, value: UInt32(newBodyLength))
        MFTRecord.writeU16LE(into: &out, at: targetStart + 20, value: actualValueOffset)
        out[out.startIndex + targetStart + 22] = 0
        out[out.startIndex + targetStart + 23] = 0

        // Name bytes at +24 (if name length > 0)
        for (i, codeUnit) in attributeName.utf16.enumerated() {
            out[out.startIndex + targetStart + 24 + 2 * i]     = UInt8(codeUnit & 0xFF)
            out[out.startIndex + targetStart + 24 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }

        // Value bytes at targetStart + actualValueOffset
        for (i, byte) in newValueBytes.enumerated() {
            out[out.startIndex + targetStart + Int(actualValueOffset) + i] = byte
        }
        // Padding to newAttrLength stays zero.

        // Tail: everything after the old attribute, shifted by delta.
        let tailStart = targetStart + targetOldLength
        let tailEnd = usedSize + 4    // include end marker
        let newTailStart = targetStart + newAttrLength
        for i in 0..<(tailEnd - tailStart) {
            out[out.startIndex + newTailStart + i] = originalBytes[originalBytes.startIndex + tailStart + i]
        }

        return out
    }

    /// Re-serialize a parsed FileName back into a $FILE_NAME body. Slightly
    /// lossy — we don't preserve EA/reparse fields (we don't expose them),
    /// but that's harmless on Windows since they get regenerated.
    private func reserializeFileNameBody(_ fn: FileName) -> Data {
        let nameUTF16 = Array(fn.name.utf16)
        let nameByteCount = nameUTF16.count * 2
        var data = Data(count: 66 + nameByteCount)
        MFTRecord.writeU64LE(into: &data, at: 0,  value: fn.parentDirectoryReference)
        MFTRecord.writeU64LE(into: &data, at: 8,  value: filetimeFromDate(fn.creationTime))
        MFTRecord.writeU64LE(into: &data, at: 16, value: filetimeFromDate(fn.modificationTime))
        MFTRecord.writeU64LE(into: &data, at: 24, value: filetimeFromDate(fn.mftChangeTime))
        MFTRecord.writeU64LE(into: &data, at: 32, value: filetimeFromDate(fn.accessTime))
        MFTRecord.writeU64LE(into: &data, at: 40, value: fn.allocatedSize)
        MFTRecord.writeU64LE(into: &data, at: 48, value: fn.realSize)
        MFTRecord.writeU32LE(into: &data, at: 56, value: fn.fileAttributes)
        MFTRecord.writeU32LE(into: &data, at: 60, value: 0)
        data[64] = UInt8(nameUTF16.count)
        data[65] = fn.namespace.rawValue
        for (i, codeUnit) in nameUTF16.enumerated() {
            data[66 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[66 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        return data
    }

    /// Build a $FILE_NAME body for a brand-new entry being inserted into $I30.
    private func buildFileNameBody(
        parentReference: UInt64,
        fileName: String,
        isDirectory: Bool,
        nowFiletime: UInt64
    ) -> Data {
        let nameUTF16 = Array(fileName.utf16)
        let nameByteCount = nameUTF16.count * 2
        var data = Data(count: 66 + nameByteCount)
        MFTRecord.writeU64LE(into: &data, at: 0,  value: parentReference)
        MFTRecord.writeU64LE(into: &data, at: 8,  value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 16, value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 24, value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 32, value: nowFiletime)
        MFTRecord.writeU64LE(into: &data, at: 40, value: 0)
        MFTRecord.writeU64LE(into: &data, at: 48, value: 0)
        MFTRecord.writeU32LE(into: &data, at: 56, value: isDirectory ? 0x1000_0000 : 0)
        MFTRecord.writeU32LE(into: &data, at: 60, value: 0)
        data[64] = UInt8(nameUTF16.count)
        data[65] = 1  // Win32 namespace
        for (i, codeUnit) in nameUTF16.enumerated() {
            data[66 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[66 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        return data
    }

    private func filetimeFromDate(_ date: Date?) -> UInt64 {
        guard let date = date else { return 0 }
        return MFTRecordBuilder.windowsFiletime(from: date)
    }

    // MARK: — Block G stage 4: file write + truncate

    /// Threshold for keeping $DATA resident. Below this we keep it inline in
    /// the MFT record; at or above, we promote to non-resident with cluster
    /// allocation. The exact value is conventional — NTFS picks based on
    /// available record slack; we use a fixed 700-byte ceiling which fits
    /// every test fixture with room to spare. Larger values would let more
    /// files stay resident (faster reads) but risk overflowing the record.
    private static let residentDataThreshold = 700

    /// Replace the file's `$DATA` content with `bytes` (writing at offset 0).
    /// If the file was non-resident, frees its old clusters first. If the new
    /// bytes fit under the resident threshold, $DATA stays resident; else
    /// promotes to non-resident with newly allocated clusters.
    ///
    /// Stage 4 scope: rewrite-from-offset-0 only. Append via the offset
    /// parameter (must equal the current size). Partial overwrites at
    /// arbitrary middle offsets are stage 4b.
    public func write(at recordNumber: UInt64, offset: UInt64, bytes: Data) async throws {
        guard recordNumber >= MFT.firstUserRecord else {
            throw NTFSError.unsupportedFeature(
                description: "write: refusing to mutate reserved MFT record \(recordNumber)"
            )
        }
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        guard record.isInUse else {
            throw NTFSError.corruptOnDisk(description: "write: MFT record \(recordNumber) is not in use")
        }
        if record.isDirectory {
            throw NTFSError.unsupportedFeature(description: "write: target is a directory")
        }

        let attrs = try record.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(description: "write: MFT record \(recordNumber) lacks unnamed $DATA")
        }

        // Existing file size for the offset check.
        let existingSize: UInt64
        switch dataAttr.value {
        case .resident(let v, _):
            existingSize = UInt64(v.count)
        case .nonResident(_, _, _, _, _, let realSize, _, _):
            existingSize = realSize
        }

        // For Stage 4 we accept offset == 0 (rewrite) or offset == existingSize (append).
        guard offset == 0 || offset == existingSize else {
            throw NTFSError.unsupportedFeature(
                description: "write: Stage 4 supports offset == 0 OR offset == existingSize \(existingSize); got \(offset)"
            )
        }

        // Compose the new full $DATA content.
        let finalContent: Data
        if offset == 0 {
            finalContent = bytes
        } else {
            // Append: existingSize == offset; read existing content via readFile.
            let existing = try await readFile(at: recordNumber)
            finalContent = existing + bytes
        }

        // Free any old non-resident extents — we're rewriting.
        if case let .nonResident(_, _, _, _, _, _, _, oldExtents) = dataAttr.value {
            for extent in oldExtents {
                try await freeClusters(extent)
            }
        }

        // Decide resident vs non-resident.
        let newDataAttr: Data    // serialized attribute (header + value/runlist + alignment)
        if finalContent.count <= Self.residentDataThreshold {
            newDataAttr = serializeResidentDataAttribute(
                attrID: dataAttr.header.attributeID,
                flags: dataAttr.header.flags,
                value: finalContent
            )
        } else {
            // Allocate clusters and write the bytes.
            let clusterBytes = UInt64(bytesPerCluster)
            let clustersNeeded = (UInt64(finalContent.count) + clusterBytes - 1) / clusterBytes
            let extent = try await allocateClusters(clustersNeeded)
            try await writeContentToExtent(extent: extent, content: finalContent)
            newDataAttr = serializeNonResidentDataAttribute(
                attrID: dataAttr.header.attributeID,
                flags: dataAttr.header.flags,
                realSize: UInt64(finalContent.count),
                allocatedSize: clustersNeeded * clusterBytes,
                extent: extent
            )
        }

        // Replace the attribute in the MFT record.
        let newRecordBytes = try rewriteEntireAttribute(
            in: record.bytes,
            firstAttributeOffset: Int(record.firstAttributeOffset),
            usedSize: Int(record.usedSize),
            recordSize: Int(record.allocatedSize),
            replacingType: AttributeType.data.rawValue,
            attributeName: "",
            replacementBytes: newDataAttr
        )
        let newUsedSize = locateEndMarker(in: newRecordBytes, fromOffset: Int(record.firstAttributeOffset))
        guard let newUsedSize = newUsedSize else {
            throw NTFSError.corruptOnDisk(description: "write: rewritten record has no end marker")
        }
        var updatedBytes = newRecordBytes
        MFTRecord.writeU32LE(into: &updatedBytes, at: 24, value: UInt32(newUsedSize + 4))

        try await mft.writeRawRecord(at: recordNumber, postFixupBytes: updatedBytes)
    }

    /// Truncate a file to `newSize`. Stage 4 supports two patterns:
    ///  - newSize == 0 → free all clusters, $DATA becomes empty resident.
    ///  - newSize <= existingSize, cluster-aligned → free trailing clusters,
    ///    update realSize/allocatedSize.
    public func truncate(at recordNumber: UInt64, newSize: UInt64) async throws {
        guard recordNumber >= MFT.firstUserRecord else {
            throw NTFSError.unsupportedFeature(
                description: "truncate: refusing to mutate reserved MFT record \(recordNumber)"
            )
        }
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        let attrs = try record.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(description: "truncate: record \(recordNumber) lacks unnamed $DATA")
        }

        if newSize == 0 {
            // Free everything, write empty resident $DATA.
            if case let .nonResident(_, _, _, _, _, _, _, extents) = dataAttr.value {
                for extent in extents {
                    try await freeClusters(extent)
                }
            }
            try await write(at: recordNumber, offset: 0, bytes: Data())
            return
        }

        // For non-zero sizes, only support cluster-aligned shrinks on
        // non-resident $DATA for now.
        let clusterBytes = UInt64(bytesPerCluster)
        guard newSize % clusterBytes == 0 else {
            throw NTFSError.unsupportedFeature(
                description: "truncate: Stage 4 requires newSize to be cluster-aligned (multiple of \(clusterBytes)) — got \(newSize)"
            )
        }
        guard case let .nonResident(_, _, _, _, _, oldRealSize, _, extents) = dataAttr.value else {
            throw NTFSError.unsupportedFeature(
                description: "truncate: Stage 4 shrink path is non-resident-only — promote first via write()"
            )
        }
        guard newSize <= oldRealSize else {
            throw NTFSError.unsupportedFeature(
                description: "truncate: extending via truncate() not yet supported (use write())"
            )
        }

        // Walk extents, keep the leading ones that fit in newSize bytes,
        // free the rest (and partial-free the boundary extent).
        let keepClusters = newSize / clusterBytes
        var keptExtents: [Extent] = []
        var clustersKept: UInt64 = 0
        for extent in extents {
            if clustersKept >= keepClusters { break }
            let needed = keepClusters - clustersKept
            if extent.clusterCount <= needed {
                keptExtents.append(extent)
                clustersKept += extent.clusterCount
            } else {
                // Split: keep first `needed` clusters, free the rest of THIS extent.
                let trimmed = Extent(startLCN: extent.startLCN, clusterCount: needed)
                keptExtents.append(trimmed)
                if let lcn = extent.startLCN {
                    let toFree = Extent(startLCN: lcn + needed, clusterCount: extent.clusterCount - needed)
                    try await freeClusters(toFree)
                }
                clustersKept = keepClusters
                break
            }
        }
        // Free any tail extents that the loop didn't reach.
        var tailIndex = 0
        var processedClusters: UInt64 = 0
        for extent in extents {
            tailIndex += 1
            processedClusters += extent.clusterCount
            if processedClusters >= keepClusters { break }
        }
        for extent in extents.suffix(from: tailIndex) {
            try await freeClusters(extent)
        }

        let allocatedSize = clustersKept * clusterBytes
        let newDataAttr = serializeNonResidentDataAttribute(
            attrID: dataAttr.header.attributeID,
            flags: dataAttr.header.flags,
            realSize: newSize,
            allocatedSize: allocatedSize,
            extentList: keptExtents
        )
        let newRecordBytes = try rewriteEntireAttribute(
            in: record.bytes,
            firstAttributeOffset: Int(record.firstAttributeOffset),
            usedSize: Int(record.usedSize),
            recordSize: Int(record.allocatedSize),
            replacingType: AttributeType.data.rawValue,
            attributeName: "",
            replacementBytes: newDataAttr
        )
        let newUsedSize = locateEndMarker(in: newRecordBytes, fromOffset: Int(record.firstAttributeOffset))
        guard let newUsedSize = newUsedSize else {
            throw NTFSError.corruptOnDisk(description: "truncate: rewritten record has no end marker")
        }
        var updatedBytes = newRecordBytes
        MFTRecord.writeU32LE(into: &updatedBytes, at: 24, value: UInt32(newUsedSize + 4))
        try await mft.writeRawRecord(at: recordNumber, postFixupBytes: updatedBytes)
    }

    // MARK: — Stage 4 helpers

    private func writeContentToExtent(extent: Extent, content: Data) async throws {
        guard let startLCN = extent.startLCN else {
            throw NTFSError.corruptOnDisk(description: "writeContentToExtent: sparse extent passed to writer")
        }
        let byteOffset = startLCN * UInt64(bytesPerCluster)
        try await device.write(offset: byteOffset, bytes: content)
        // Pad to cluster boundary so we don't leave junk in the trailing partial cluster.
        let clusterBytes = Int(bytesPerCluster)
        let tailBytes = content.count % clusterBytes
        if tailBytes != 0 {
            let padBytes = clusterBytes - tailBytes
            let pad = Data(repeating: 0, count: padBytes)
            try await device.write(offset: byteOffset + UInt64(content.count), bytes: pad)
        }
    }

    private func serializeResidentDataAttribute(attrID: UInt16, flags: UInt16, value: Data) -> Data {
        let bodyLen = value.count
        let rawLen = 16 + 8 + bodyLen
        let alignedLen = ((rawLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &data, at: 0,  value: AttributeType.data.rawValue)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 0          // resident
        data[data.startIndex + 9] = 0          // nameLength
        MFTRecord.writeU16LE(into: &data, at: 10, value: 0)
        MFTRecord.writeU16LE(into: &data, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        MFTRecord.writeU32LE(into: &data, at: 16, value: UInt32(bodyLen))
        MFTRecord.writeU16LE(into: &data, at: 20, value: 24)   // valueOffset
        for (i, byte) in value.enumerated() {
            data[data.startIndex + 24 + i] = byte
        }
        return data
    }

    private func serializeNonResidentDataAttribute(
        attrID: UInt16,
        flags: UInt16,
        realSize: UInt64,
        allocatedSize: UInt64,
        extent: Extent
    ) -> Data {
        serializeNonResidentDataAttribute(
            attrID: attrID,
            flags: flags,
            realSize: realSize,
            allocatedSize: allocatedSize,
            extentList: [extent]
        )
    }

    private func serializeNonResidentDataAttribute(
        attrID: UInt16,
        flags: UInt16,
        realSize: UInt64,
        allocatedSize: UInt64,
        extentList: [Extent]
    ) -> Data {
        // Build runlist bytes from extents.
        let runlist = encodeRunlist(extents: extentList)
        // Header (16) + non-resident ext (48) + runlist + terminator (0) + padding to 8.
        let bodyLen = 64 + runlist.count
        let alignedLen = ((bodyLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        let clusterBytes = UInt64(bytesPerCluster)
        let totalClusters = extentList.reduce(0) { $0 + $1.clusterCount }
        let lastVCN = totalClusters > 0 ? totalClusters - 1 : 0

        MFTRecord.writeU32LE(into: &data, at: 0,  value: AttributeType.data.rawValue)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 1          // non-resident
        data[data.startIndex + 9] = 0          // nameLength
        MFTRecord.writeU16LE(into: &data, at: 10, value: 0)
        MFTRecord.writeU16LE(into: &data, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        // Non-resident extension
        MFTRecord.writeU64LE(into: &data, at: 16, value: 0)                          // startingVCN
        MFTRecord.writeU64LE(into: &data, at: 24, value: lastVCN)                    // lastVCN
        MFTRecord.writeU16LE(into: &data, at: 32, value: 64)                          // dataRunsOffset
        data[data.startIndex + 34] = 0                                                // compressionUnit
        // 35-39: reserved zeros
        MFTRecord.writeU64LE(into: &data, at: 40, value: allocatedSize)
        MFTRecord.writeU64LE(into: &data, at: 48, value: realSize)
        MFTRecord.writeU64LE(into: &data, at: 56, value: realSize)                    // initializedSize == realSize
        for (i, byte) in runlist.enumerated() {
            data[data.startIndex + 64 + i] = byte
        }
        _ = clusterBytes
        return data
    }

    private func encodeRunlist(extents: [Extent]) -> Data {
        var bytes = Data()
        var prevLCN: Int64 = 0
        for extent in extents {
            // length field width: bytes needed to hold extent.clusterCount.
            let lengthBytes = encodeUnsignedLE(extent.clusterCount)
            // Offset: signed delta from prevLCN, or no offset bytes for sparse.
            if let startLCN = extent.startLCN {
                let delta = Int64(startLCN) - prevLCN
                let offsetBytes = encodeSignedLE(delta)
                let header = UInt8(lengthBytes.count) | (UInt8(offsetBytes.count) << 4)
                bytes.append(header)
                bytes.append(lengthBytes)
                bytes.append(offsetBytes)
                prevLCN = Int64(startLCN)
            } else {
                // Sparse: offset width 0
                let header = UInt8(lengthBytes.count)
                bytes.append(header)
                bytes.append(lengthBytes)
            }
        }
        bytes.append(0)   // terminator
        return bytes
    }

    private func encodeUnsignedLE(_ value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var v = value
        var bytes: [UInt8] = []
        while v != 0 {
            bytes.append(UInt8(v & 0xFF))
            v >>= 8
        }
        return Data(bytes)
    }

    private func encodeSignedLE(_ value: Int64) -> Data {
        // Find the minimum number of bytes that hold `value` with sign bit intact.
        if value == 0 { return Data([0]) }
        for width in 1...8 {
            let max: Int64 = (Int64(1) << (8 * width - 1)) - 1
            let min: Int64 = -(Int64(1) << (8 * width - 1))
            if value >= min && value <= max {
                var bytes: [UInt8] = []
                var v = UInt64(bitPattern: value)
                for _ in 0..<width {
                    bytes.append(UInt8(v & 0xFF))
                    v >>= 8
                }
                return Data(bytes)
            }
        }
        return Data([0])  // shouldn't happen with valid LCN
    }

    /// Like `rewriteResidentAttribute` but the caller pre-serialized the entire
    /// replacement attribute (header + body), so we just splice it into the
    /// record. Used by write() and truncate() because they swap an entire
    /// $DATA attribute (sometimes changing form between resident ↔ non-
    /// resident, with different header layouts).
    private func rewriteEntireAttribute(
        in originalBytes: Data,
        firstAttributeOffset: Int,
        usedSize: Int,
        recordSize: Int,
        replacingType: UInt32,
        attributeName: String,
        replacementBytes: Data
    ) throws -> Data {
        var cursor = firstAttributeOffset
        var targetStart: Int?
        var targetOldLength: Int = 0
        while cursor + 4 <= usedSize {
            let type = try originalBytes.readU32LE(at: cursor)
            if type == AttributeType.endMarker { break }
            guard cursor + 16 <= usedSize else { break }
            let length = Int(try originalBytes.readU32LE(at: cursor + 4))
            let nameLength = try originalBytes.readU8(at: cursor + 9)
            let nameOffset = try originalBytes.readU16LE(at: cursor + 10)
            var thisName = ""
            if nameLength > 0 {
                let nameByteCount = Int(nameLength) * 2
                let nameStart = cursor + Int(nameOffset)
                let nameBytes = originalBytes[(originalBytes.startIndex + nameStart)..<(originalBytes.startIndex + nameStart + nameByteCount)]
                thisName = decodeUTF16LE(nameBytes) ?? ""
            }
            if type == replacingType && thisName == attributeName {
                targetStart = cursor
                targetOldLength = length
                break
            }
            cursor += length
        }
        guard let targetStart = targetStart else {
            throw NTFSError.corruptOnDisk(
                description: "rewriteEntireAttribute: target type 0x\(String(format: "%08X", replacingType)) name '\(attributeName)' not found"
            )
        }
        let delta = replacementBytes.count - targetOldLength
        let newUsedSize = usedSize + delta
        guard newUsedSize + 4 <= recordSize else {
            throw NTFSError.unsupportedFeature(
                description: "rewriteEntireAttribute: new attribute (\(replacementBytes.count) bytes) would overflow record (used \(usedSize), record \(recordSize))"
            )
        }

        var out = Data(count: recordSize)
        for i in 0..<targetStart {
            out[out.startIndex + i] = originalBytes[originalBytes.startIndex + i]
        }
        for (i, byte) in replacementBytes.enumerated() {
            out[out.startIndex + targetStart + i] = byte
        }
        // Tail: everything after old attribute, shifted by delta.
        let tailStart = targetStart + targetOldLength
        let tailEnd = usedSize + 4
        let newTailStart = targetStart + replacementBytes.count
        for i in 0..<(tailEnd - tailStart) {
            out[out.startIndex + newTailStart + i] = originalBytes[originalBytes.startIndex + tailStart + i]
        }
        return out
    }

    /// Roll back an MFT record allocation by flipping IN_USE off — used by
    /// createFile's error handler when the $I30 insert fails. Doesn't try to
    /// free clusters (the new record is empty resident $DATA only) and
    /// doesn't update the parent (this is the rollback path called after
    /// the parent update itself failed).
    private func deleteOrphan(at recordNumber: UInt64) async throws {
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        guard record.isInUse else { return }
        var newFlags = record.flags
        newFlags.remove(.inUse)
        let updated = MFTRecord(
            magic: record.magic,
            usaOffset: record.usaOffset,
            usaCount: record.usaCount,
            logFileSequenceNumber: record.logFileSequenceNumber,
            sequenceNumber: record.sequenceNumber,
            hardLinkCount: record.hardLinkCount,
            firstAttributeOffset: record.firstAttributeOffset,
            flags: newFlags,
            usedSize: record.usedSize,
            allocatedSize: record.allocatedSize,
            baseFileReference: record.baseFileReference,
            nextAttributeID: record.nextAttributeID,
            mftRecordNumber: record.mftRecordNumber,
            bytes: record.bytes
        )
        try await mft.writeRecord(at: recordNumber, updated)
    }

    /// Delete a file. Stage 3b complete: frees non-resident clusters, marks
    /// the MFT record IN_USE=0, bumps the sequence number, AND removes the
    /// corresponding entry from the parent directory's $I30 index.
    ///
    /// Idempotent — deleting an already-deleted record is a no-op rather
    /// than an error.
    public func deleteFile(at recordNumber: UInt64) async throws {
        // Don't allow deleting NTFS system records.
        guard recordNumber >= MFT.firstUserRecord else {
            throw NTFSError.unsupportedFeature(
                description: "deleteFile: refusing to delete reserved MFT record \(recordNumber)"
            )
        }

        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        guard record.isInUse else { return }  // already deleted — idempotent

        // Find the parent record number from the file's $FILE_NAME so we can
        // remove the corresponding $I30 entry.
        let attrs = try record.attributes()
        var parentRecordNumber: UInt64?
        var deletedName: String?
        if let fnAttr = attrs.first(where: { $0.type == .fileName }),
           case let .resident(fnBytes, _) = fnAttr.value,
           let fn = try? FileName.parse(fnBytes) {
            parentRecordNumber = fn.parentRecordNumber
            deletedName = fn.name
        }

        // 1) Remove from parent's $I30 first. Best-effort — if it fails, the
        // record is still removable from MFT and the $I30 stale-entry can
        // be cleaned up by `chkdsk`. Done before the MFT delete so we can
        // tolerate failures here without leaving an orphan.
        if let parentRN = parentRecordNumber, let name = deletedName {
            try? await removeFromParentI30(
                parentRecordNumber: parentRN,
                childFileName: name
            )
        }

        // 2) Free non-resident clusters.
        for attr in attrs {
            if case let .nonResident(_, _, _, _, _, _, _, extents) = attr.value {
                for extent in extents {
                    try await freeClusters(extent)
                }
            }
        }

        // Flip IN_USE off, bump sequence number for next reuse.
        var newFlags = record.flags
        newFlags.remove(.inUse)
        var newSeq = record.sequenceNumber &+ 1
        if newSeq == 0 { newSeq = 1 }

        let updated = MFTRecord(
            magic: record.magic,
            usaOffset: record.usaOffset,
            usaCount: record.usaCount,
            logFileSequenceNumber: record.logFileSequenceNumber,
            sequenceNumber: newSeq,
            hardLinkCount: record.hardLinkCount,
            firstAttributeOffset: record.firstAttributeOffset,
            flags: newFlags,
            usedSize: record.usedSize,
            allocatedSize: record.allocatedSize,
            baseFileReference: record.baseFileReference,
            nextAttributeID: record.nextAttributeID,
            mftRecordNumber: record.mftRecordNumber,
            bytes: record.bytes
        )
        try await mft.writeRecord(at: recordNumber, updated)
    }

    /// Allocate a contiguous run of `count` clusters from $Bitmap, persist
    /// the updated $Bitmap back to disk, and return the granted Extent.
    /// Throws `outOfSpace` if no run of the requested length exists.
    ///
    /// Phase 5b: contiguous-only allocator. Phase 5c will add a fall-back
    /// path that splits a request into multiple extents when no single run
    /// is large enough (common on fragmented volumes).
    public func allocateClusters(_ count: UInt64) async throws -> Extent {
        var bm = try await bitmap()
        let extent = try bm.allocate(count)
        try await persistBitmap(bm)
        _bitmap = bm
        return extent
    }

    /// Free a previously-allocated extent and persist the updated $Bitmap.
    public func freeClusters(_ extent: Extent) async throws {
        var bm = try await bitmap()
        try bm.free(extent)
        try await persistBitmap(bm)
        _bitmap = bm
    }

    /// Persist the in-memory Bitmap back to the on-disk $Bitmap attribute.
    /// Walks $Bitmap's $DATA extents and writes the corresponding bitmap
    /// bytes via `BlockDevice.write`. For a resident $Bitmap (a degenerate
    /// case that doesn't happen on real volumes since $Bitmap is always
    /// non-resident), we'd need to rewrite the MFT record — out of scope
    /// for stage 2.
    private func persistBitmap(_ bm: Bitmap) async throws {
        let mft = self.mft()
        let bitmapRecord = try await mft.record(at: Self.bitmapRecordNumber)
        let attrs = try bitmapRecord.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(
                description: "$Bitmap record \(Self.bitmapRecordNumber) has no $DATA"
            )
        }
        guard case let .nonResident(_, _, _, _, _, _, _, extents) = dataAttr.value else {
            throw NTFSError.unsupportedFeature(
                description: "$Bitmap is resident — rewriting the MFT record is not yet supported"
            )
        }

        let clusterBytes = UInt64(bytesPerCluster)
        var bytesRemaining = bm.bytes
        for extent in extents where !bytesRemaining.isEmpty {
            guard let startLCN = extent.startLCN else { continue }  // sparse
            let extentBytes = Int(min(extent.clusterCount * clusterBytes, UInt64(bytesRemaining.count)))
            let chunk = bytesRemaining.prefix(extentBytes)
            try await device.write(
                offset: startLCN * clusterBytes,
                bytes: Data(chunk)
            )
            bytesRemaining = bytesRemaining.dropFirst(extentBytes)
        }
    }

    /// Enumerate the children of the directory at `recordNumber`. For the root
    /// directory pass `recordNumber: 5`. Returns the entries in the order they
    /// appear in the $I30 index (sorted by NTFS collation, typically Unicode
    /// uppercase). Skips the LAST sentinel.
    public func enumerate(directory recordNumber: UInt64) async throws -> [DirectoryEntry] {
        let mft = self.mft()
        let dirRecord = try await mft.record(at: recordNumber)
        guard dirRecord.isDirectory else {
            throw NTFSError.corruptOnDisk(
                description: "MFT record \(recordNumber) is not a directory (flags=0x\(String(format: "%04X", dirRecord.flags.rawValue)))"
            )
        }

        let attrs = try dirRecord.attributes()
        guard let indexRootAttr = attrs.first(where: {
            $0.type == .indexRoot && $0.nameOrEmpty == "$I30"
        }) else {
            throw NTFSError.corruptOnDisk(
                description: "directory record \(recordNumber) is missing $INDEX_ROOT:$I30"
            )
        }
        guard case let .resident(rootBytes, _) = indexRootAttr.value else {
            throw NTFSError.corruptOnDisk(description: "$INDEX_ROOT:$I30 must be resident")
        }

        let root = try IndexRoot.parse(rootBytes)
        var collected: [DirectoryEntry] = []
        var seenReferences: Set<UInt64> = []
        for indexEntry in root.entries {
            if let de = Self.directoryEntry(from: indexEntry),
               seenReferences.insert(de.fileReference).inserted {
                collected.append(de)
            }
        }

        // If the index spills into $INDEX_ALLOCATION, walk those blocks too.
        // The linear walk over every INDX block can double-count entries that
        // appear in both interior nodes and their leaves; the dedup set built
        // above carries through so each fileReference is yielded at most once.
        if root.isLargeIndex {
            collected.append(contentsOf: try await readIndexAllocation(
                attributes: attrs,
                directoryRecord: recordNumber,
                seenReferences: &seenReferences
            ))
        }

        return collected
    }

    /// Read a byte range from the file at `recordNumber` without
    /// materializing the whole file. Used by the FSKit adapter so kernel
    /// read callbacks don't pay O(N) per chunk.
    ///
    /// `offset` is the file-relative byte offset; `length` is the maximum
    /// number of bytes to return. The returned `Data` may be shorter if
    /// the request extends past the file's `realSize`.
    public func readFileSlice(
        at recordNumber: UInt64,
        offset: UInt64,
        length: Int
    ) async throws -> Data {
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        let attrs = try record.attributes()

        if attrs.contains(where: { $0.rawType == AttributeType.attributeList.rawValue }) {
            throw NTFSError.unsupportedFeature(
                description: "MFT record \(recordNumber) has $ATTRIBUTE_LIST — multi-record attributes are not yet supported"
            )
        }
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(
                description: "MFT record \(recordNumber) has no unnamed $DATA attribute"
            )
        }

        switch dataAttr.value {
        case let .resident(bytes, _):
            guard length >= 0 else {
                throw NTFSError.ioFailure(description: "negative length \(length)")
            }
            if offset >= UInt64(bytes.count) { return Data() }
            let start = Int(offset)
            let end = min(start + length, bytes.count)
            return bytes.subdata(in: start..<end)
        case let .nonResident(startingVCN, _, _, _, _, realSize, _, extents):
            guard startingVCN == 0 else {
                throw NTFSError.unsupportedFeature(
                    description: "$DATA fragment starts at VCN \(startingVCN); multi-fragment $DATA not supported"
                )
            }
            return try await readNonResidentSlice(
                extents: extents,
                realSize: realSize,
                offset: offset,
                length: length
            )
        }
    }

    /// Read the byte content of the file at `recordNumber` using its $DATA
    /// attribute's runlist. Returns the full file payload up to $DATA's
    /// `realSize`. Resident $DATA (small files) is returned as-is. Sparse
    /// extents inside non-resident $DATA expand to zero-filled regions.
    ///
    /// Rejects records that carry $ATTRIBUTE_LIST (type 0x20) — those split
    /// $DATA across multiple MFT records, and silently picking the first
    /// fragment would truncate the file. Block G will wire up the proper
    /// $ATTRIBUTE_LIST follower; until then `NTFSError.unsupportedFeature`
    /// is preferable to silently-wrong reads.
    public func readFile(at recordNumber: UInt64) async throws -> Data {
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        let attrs = try record.attributes()

        if attrs.contains(where: { $0.rawType == AttributeType.attributeList.rawValue }) {
            throw NTFSError.unsupportedFeature(
                description: "MFT record \(recordNumber) has $ATTRIBUTE_LIST — multi-record attributes are not yet supported"
            )
        }

        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(
                description: "MFT record \(recordNumber) has no unnamed $DATA attribute"
            )
        }

        switch dataAttr.value {
        case let .resident(bytes, _):
            return bytes
        case let .nonResident(startingVCN, lastVCN, _, _, _, realSize, _, extents):
            // Single-fragment guarantee: $DATA must cover startingVCN == 0 through
            // the full file. If it doesn't, this record only carries a slice and
            // the rest lives via $ATTRIBUTE_LIST — which we've already rejected.
            // This guard is belt-and-braces for fixtures or volumes that for some
            // reason carry a non-zero startingVCN without an $ATTRIBUTE_LIST.
            guard startingVCN == 0 else {
                throw NTFSError.unsupportedFeature(
                    description: "$DATA fragment starts at VCN \(startingVCN); multi-fragment $DATA not supported"
                )
            }
            return try await readNonResidentData(extents: extents, realSize: realSize, lastVCN: lastVCN)
        }
    }

    // MARK: — Helpers (actor-isolated)

    private static func directoryEntry(from indexEntry: IndexEntry) -> DirectoryEntry? {
        if indexEntry.isLast { return nil }
        guard let fn = indexEntry.fileName else { return nil }
        return DirectoryEntry(
            fileReference: indexEntry.fileReference,
            recordNumber: indexEntry.recordNumber,
            sequenceNumber: indexEntry.sequenceNumber,
            fileName: fn
        )
    }

    private func readIndexAllocation(
        attributes: [Attribute],
        directoryRecord: UInt64,
        seenReferences: inout Set<UInt64>
    ) async throws -> [DirectoryEntry] {
        guard let allocAttr = attributes.first(where: {
            $0.type == .indexAllocation && $0.nameOrEmpty == "$I30"
        }) else {
            // LARGE_INDEX flag set but no $INDEX_ALLOCATION present in
            // directory record \(directoryRecord) — treat as a fixture quirk;
            // the entries we already have from $INDEX_ROOT are still valid.
            return []
        }
        guard case let .nonResident(_, _, _, _, _, _, _, extents) = allocAttr.value else {
            throw NTFSError.corruptOnDisk(description: "$INDEX_ALLOCATION must be non-resident")
        }

        let blockSize = Int(indexRecordSizeBytes)
        let sectorSize = Int(boot.bytesPerSector)
        var collected: [DirectoryEntry] = []
        let clusterBytes = UInt64(bytesPerCluster)

        // INDX blocks are sized by indexRecordSizeBytes — not necessarily one
        // cluster. On a 4 KiB-cluster + 4 KiB-INDX volume (the common case)
        // each cluster IS one block, but on volumes where indexRecordSizeBytes
        // > bytesPerCluster (e.g. 4 KiB clusters + 8 KiB INDX records) each
        // INDX spans multiple clusters and stepping cluster-by-cluster
        // misaligns reads. Walk by block instead.
        guard blockSize > 0, blockSize % Int(clusterBytes) == 0 || Int(clusterBytes) % blockSize == 0 else {
            throw NTFSError.corruptOnDisk(
                description: "indexRecordSizeBytes \(blockSize) is not a multiple/divisor of cluster size \(clusterBytes)"
            )
        }
        let clustersPerBlock = max(UInt64(1), UInt64(blockSize) / clusterBytes)

        for extent in extents {
            guard let startLCN = extent.startLCN else { continue } // skip sparse
            // Stride by clustersPerBlock so we land on each INDX-block boundary.
            // For the common 1-cluster-per-block case this collapses to the
            // original per-cluster loop.
            var cluster: UInt64 = 0
            while cluster < extent.clusterCount {
                let (clusterLCN, addOverflow) = startLCN.addingReportingOverflow(cluster)
                guard !addOverflow else {
                    throw NTFSError.corruptOnDisk(description: "$INDEX_ALLOCATION extent cluster index overflows UInt64")
                }
                let (byteOffset, mulOverflow) = clusterLCN.multipliedReportingOverflow(by: clusterBytes)
                guard !mulOverflow else {
                    throw NTFSError.corruptOnDisk(description: "$INDEX_ALLOCATION byte offset overflows UInt64")
                }
                let raw = try await device.read(offset: byteOffset, length: blockSize)
                let block = try IndexAllocationBlock.parse(raw, sectorSize: sectorSize)
                for entry in block.entries {
                    // The B-tree's interior nodes contain the same fileReferences
                    // as the leaves below them (each interior key = smallest key
                    // of the right subtree). A linear sweep over every INDX block
                    // therefore double-counts. Dedup by fileReference is strictly
                    // safer than the naive walk; proper subnode-VCN descent is
                    // future work but not on Block D's critical path.
                    if let de = Self.directoryEntry(from: entry),
                       seenReferences.insert(de.fileReference).inserted {
                        collected.append(de)
                    }
                }
                cluster += clustersPerBlock
            }
        }
        return collected
    }

    /// Read non-resident $DATA via its extents. Sparse extents → zero fill.
    /// Truncates to `realSize`.
    ///
    /// Guards every arithmetic step against UInt64 overflow and Int cast trap.
    /// A corrupt or adversarial runlist (huge clusterCount, large startLCN, or
    /// a realSize larger than addressable on a 64-bit Int) should produce a
    /// typed NTFSError, never a process crash. This matters because Block E
    /// will feed user-supplied disk images through this path.
    ///
    /// 1 GiB hard cap on the returned buffer is a temporary safety net for
    /// the eager-load API: a streaming variant lands with Block G. Until then
    /// readFile refuses to materialize multi-GB files in memory.
    private static let maxEagerReadSize: UInt64 = 1 << 30  // 1 GiB

    /// Read a byte range from a non-resident $DATA runlist. Walks the
    /// extents until the offset falls inside one, then copies up to
    /// `length` bytes (truncated to `realSize`). Sparse extents inside the
    /// slice expand to zero-fill. This is the streaming entry point Block E
    /// and Block G both use; the eager `readFile` is built on top.
    private func readNonResidentSlice(
        extents: [Extent],
        realSize: UInt64,
        offset: UInt64,
        length: Int
    ) async throws -> Data {
        guard length >= 0 else {
            throw NTFSError.ioFailure(description: "negative length \(length)")
        }
        if length == 0 || offset >= realSize { return Data() }

        let clusterBytes = UInt64(bytesPerCluster)
        let endRequested = min(offset.addingReportingOverflow(UInt64(length)).0, realSize)
        // Cap the eventual buffer size by Int.max so the Data allocation can't trap.
        let desired = endRequested - offset
        guard desired <= UInt64(Int.max) else {
            throw NTFSError.corruptOnDisk(
                description: "slice length \(desired) exceeds Int.max"
            )
        }
        var out = Data()
        out.reserveCapacity(Int(desired))

        var cursorBytes: UInt64 = 0   // byte offset at the start of the current extent

        for extent in extents {
            let (extentBytesRaw, mulOverflow) = extent.clusterCount.multipliedReportingOverflow(by: clusterBytes)
            guard !mulOverflow else {
                throw NTFSError.corruptOnDisk(
                    description: "extent clusterCount \(extent.clusterCount) * \(clusterBytes) overflows UInt64"
                )
            }
            let extentEnd = cursorBytes.addingReportingOverflow(extentBytesRaw)
            guard !extentEnd.overflow else {
                throw NTFSError.corruptOnDisk(description: "extent end offset overflows UInt64")
            }
            let extentEndBytes = extentEnd.0

            // Skip extents entirely before the requested offset.
            if extentEndBytes <= offset {
                cursorBytes = extentEndBytes
                continue
            }
            // Stop once we've crossed the requested end.
            if cursorBytes >= endRequested { break }

            let sliceStartInExtent = (offset > cursorBytes) ? (offset - cursorBytes) : 0
            let sliceEndInExtent = min(extentBytesRaw, endRequested - cursorBytes)
            let takeBytes = Int(sliceEndInExtent - sliceStartInExtent)

            if let startLCN = extent.startLCN {
                let (extentByteOffset, ovf) = startLCN.multipliedReportingOverflow(by: clusterBytes)
                guard !ovf else {
                    throw NTFSError.corruptOnDisk(
                        description: "extent startLCN \(startLCN) * \(clusterBytes) overflows UInt64"
                    )
                }
                let chunk = try await device.read(
                    offset: extentByteOffset + sliceStartInExtent,
                    length: takeBytes
                )
                out.append(chunk)
            } else {
                out.append(Data(repeating: 0, count: takeBytes))
            }

            cursorBytes = extentEndBytes
        }

        return out
    }

    private func readNonResidentData(extents: [Extent], realSize: UInt64, lastVCN: UInt64) async throws -> Data {
        // lastVCN is the runlist's claimed final virtual-cluster index; the sum
        // of extent cluster counts must be lastVCN+1 (or more, if the trailing
        // allocation is larger than realSize). Catch mismatches early — a
        // corrupt runlist that lies about coverage would otherwise just
        // short-read with no signal.
        let totalRunClusters = DataRun.totalClusters(extents)
        if extents.count > 0, totalRunClusters < lastVCN + 1 {
            throw NTFSError.corruptOnDisk(
                description: "$DATA runlist covers \(totalRunClusters) clusters but lastVCN=\(lastVCN) requires at least \(lastVCN + 1)"
            )
        }

        guard realSize <= UInt64(Int.max) else {
            throw NTFSError.corruptOnDisk(
                description: "$DATA realSize \(realSize) exceeds Int.max — refusing to allocate"
            )
        }
        guard realSize <= Self.maxEagerReadSize else {
            throw NTFSError.unsupportedFeature(
                description: "$DATA realSize \(realSize) > 1 GiB — eager readFile cap. Streaming API lands in Phase 5."
            )
        }

        var out = Data()
        out.reserveCapacity(Int(realSize))
        var remaining = Int(realSize)

        let clusterBytes = UInt64(bytesPerCluster)

        for extent in extents where remaining > 0 {
            // extent.clusterCount * bytesPerCluster — overflow check.
            let (extentBytesRaw, extentMulOverflow) = extent.clusterCount.multipliedReportingOverflow(by: clusterBytes)
            guard !extentMulOverflow else {
                throw NTFSError.corruptOnDisk(
                    description: "extent clusterCount \(extent.clusterCount) * \(clusterBytes) overflows UInt64"
                )
            }
            guard extentBytesRaw <= UInt64(Int.max) else {
                throw NTFSError.corruptOnDisk(
                    description: "extent byte length \(extentBytesRaw) exceeds Int.max"
                )
            }
            let extentBytes = Int(extentBytesRaw)
            let takeBytes = min(extentBytes, remaining)

            if let startLCN = extent.startLCN {
                let (byteOffset, lcnMulOverflow) = startLCN.multipliedReportingOverflow(by: clusterBytes)
                guard !lcnMulOverflow else {
                    throw NTFSError.corruptOnDisk(
                        description: "extent startLCN \(startLCN) * \(clusterBytes) overflows UInt64"
                    )
                }
                let chunk = try await device.read(offset: byteOffset, length: takeBytes)
                out.append(chunk)
            } else {
                // Sparse: append zero-fill of takeBytes.
                out.append(Data(repeating: 0, count: takeBytes))
            }
            remaining -= takeBytes
        }

        return out
    }
}
