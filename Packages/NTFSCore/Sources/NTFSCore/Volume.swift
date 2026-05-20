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

    // v0.4 Phase 1: bulk-insert mode. When set, refreshParentI30Size becomes
    // a no-op for files whose parent matches `_bulkInsertParentRN`. cp -r
    // wraps each destination dir's batch of file inserts in beginBulkInsert
    // / endBulkInsert so the per-file size-hint refresh (which re-reads +
    // recomputes + rewrites the parent's $I30 entry, a ~4 KiB INDX-block
    // write each time on LARGE_INDEX dirs) is skipped. Size hints in $I30
    // are cosmetic (Windows Explorer file-size column); files are byte-
    // correct without them. Run `ntfsctl refresh-sizes` later if you care.
    private var _bulkInsertParentRN: UInt64?
    private var _bulkInsertSkippedRefreshCount: Int = 0
    // v0.4 Phase 2: INDX-leaf coalescing. While in bulk-insert mode, leaf
    // modifications are held in memory and flushed to disk in a single
    // pass at `endBulkInsert`. For cp -r, where 50+ consecutive files
    // land in the same leaf, this collapses 50 leaf-rewrites (~4 KiB
    // each) into one final write.
    private var _bulkInsertLeafCache: BulkLeafCache?
    // Counters snapshotted into the actor at `endBulkInsert` so tests
    // can read them after the cache reference has been cleared.
    private var _bulkInsertLastCacheHits: Int = 0
    private var _bulkInsertLastDirtyLeavesFlushed: Int = 0

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

    // v0.5 Fix B Step 2(A): $ATTRIBUTE_LIST-aware attribute lookup. When a
    // base MFT record's attributes overflow into extension records, the base
    // carries a $ATTRIBUTE_LIST (0x20) pointing at the extension recnums.
    // resolveAttribute / allAttributesOf walk that list and concatenate the
    // base + extension attributes so callers can find
    // $INDEX_ROOT / $INDEX_ALLOCATION / $BITMAP:$I30 even when they've
    // migrated out of the base. When $ATTRIBUTE_LIST is absent these
    // helpers behave identically to `record.attributes()` — read paths
    // that worked pre-Fix-B keep working.

    public func allAttributesOf(recordNumber: UInt64) async throws -> [Attribute] {
        let mft = self.mft()
        let base = try await mft.record(at: recordNumber)
        let baseAttrs = try base.attributes()
        guard let attrListAttr = baseAttrs.first(where: { $0.rawType == AttributeType.attributeList.rawValue }) else {
            return baseAttrs
        }
        let body: Data
        switch attrListAttr.value {
        case let .resident(b, _):
            body = b
        case let .nonResident(_, _, _, _, _, realSize, _, extents):
            body = try await readNonResidentData(
                extents: extents,
                realSize: realSize,
                lastVCN: 0
            )
        }
        let entries = try AttributeListEntry.parseAll(in: body)
        var seenExt: Set<UInt64> = []
        var extAttrs: [Attribute] = []
        for e in entries {
            let rn = e.recordNumber
            if rn == recordNumber { continue }
            if seenExt.contains(rn) { continue }
            seenExt.insert(rn)
            let extRec = try await mft.record(at: rn)
            // Defence in depth: an $ATTRIBUTE_LIST entry whose sequenceNumber
            // doesn't match the resolved extension record's sequenceNumber
            // means we're following a stale pointer at a recycled MFT slot.
            // Better to fail loud than silently read the wrong file's data.
            guard extRec.sequenceNumber == e.sequenceNumber else {
                throw NTFSError.corruptOnDisk(
                    description: "ATTR_LIST entry recnum \(rn) seq \(e.sequenceNumber) != record seq \(extRec.sequenceNumber) (base recnum \(recordNumber))"
                )
            }
            extAttrs.append(contentsOf: try extRec.attributes())
        }
        return baseAttrs + extAttrs
    }

    public func resolveAttribute(
        recordNumber: UInt64,
        type: AttributeType,
        name: String?
    ) async throws -> Attribute? {
        let all = try await allAttributesOf(recordNumber: recordNumber)
        return all.first { a in
            guard a.rawType == type.rawValue else { return false }
            if let n = name { return a.nameOrEmpty == n }
            return true
        }
    }

    /// MFT record number of the $Bitmap system file. Always 6 on every NTFS
    /// volume — this is part of the NTFS spec, not a per-volume value.
    public static let bitmapRecordNumber: UInt64 = 6

    private var _bitmap: Bitmap?

    /// Next-fit allocator search hint: the cluster immediately after the last
    /// one we allocated. `allocateClusters` searches from here (with wrap-
    /// around) so sequential writes during a single `cp -r` produce
    /// contiguous, single-extent runlists instead of refilling scattered
    /// holes near cluster 0. In-memory per-Volume state — resets to 0 on each
    /// fresh open; not persisted on disk (v0.5). `Volume` is an actor, so
    /// mutations are already serialized.
    private var _allocHint: UInt64 = 0

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

    /// Return $MFT.$DATA's runlist extents, or nil if record 0 hasn't been
    /// parsed yet (chicken-and-egg: to read the runlist we must read record
    /// 0 via the contiguous fast path first). Invalidated on $MFT growth.
    private var _mftDataExtents: [Extent]?
    public func mftDataExtents() async -> [Extent]? {
        if let cached = _mftDataExtents { return cached }
        // Read record 0 via the contiguous shortcut (mftByteOffset).
        let recordSize = UInt64(mftRecordSizeBytes)
        let sectorSize = Int(boot.bytesPerSector)
        do {
            let raw = try await device.read(offset: mftByteOffset, length: Int(recordSize))
            let rec = try MFTRecord.parse(raw, expectedSize: Int(recordSize), sectorSize: sectorSize)
            let attrs = try rec.attributes()
            guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }),
                  case let .nonResident(_, _, _, _, _, _, _, extents) = dataAttr.value else {
                return nil
            }
            _mftDataExtents = extents
            return extents
        } catch {
            return nil
        }
    }

    /// Invalidate the cached $MFT.$DATA runlist + bitmap. Called whenever
    /// growMFTDataByClusters mutates the runlist.
    public func invalidateMFTCaches() {
        _mftDataExtents = nil
        _mftBitmap = nil
    }

    // MARK: — MFT $BITMAP-based allocator
    //
    // $MFT (MFT record 0) has a $BITMAP attribute that tracks which MFT slots
    // are allocated. One bit per record: bit N == 1 means record N is in
    // use. The bitmap is the canonical NTFS authoritative source of "which
    // slots are free"; the IN_USE flag in each individual MFT record is a
    // (redundant) mirror. Real volumes — especially Windows-formatted ones
    // with thousands of existing files — rely on the bitmap because the
    // linear-scan approach gives up after a few thousand records.
    //
    // Pre-T1.1 (v0.1): findFreeRecordNumber linear-scanned the first 2048
    // slots. On a 4 TB drive with 3000+ existing files, the first ntfsctl
    // write attempt failed with `outOfSpace` — even though the drive had
    // terabytes free — because slots 16-2063 were all in use.
    //
    // Post-T1.1: allocate via the bitmap. Works for arbitrarily-sized MFTs.

    private var _mftBitmap: Bitmap?

    /// Read (and cache) the $MFT $BITMAP attribute. Returns a Bitmap whose
    /// `clusterCount` is actually "record count" (the abstraction is bit-
    /// indexed; semantics are the caller's problem).
    public func mftBitmap() async throws -> Bitmap {
        if let cached = _mftBitmap { return cached }
        let mft = self.mft()
        let r0 = try await mft.record(at: 0)
        let attrs = try r0.attributes()
        guard let bmAttr = attrs.first(where: { $0.rawType == 0xB0 && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(description: "$MFT (record 0) lacks $BITMAP attribute")
        }
        let bytes: Data
        switch bmAttr.value {
        case let .resident(b, _):
            bytes = b
        case let .nonResident(_, _, _, _, _, realSize, _, extents):
            var collected = Data()
            let take = Int(min(realSize, UInt64(Int.max)))
            collected.reserveCapacity(take)
            let clusterBytes = UInt64(bytesPerCluster)
            var remaining = take
            for extent in extents where remaining > 0 {
                let extentLen = Int(min(extent.clusterCount * clusterBytes, UInt64(remaining)))
                if let startLCN = extent.startLCN {
                    let chunk = try await device.read(offset: startLCN * clusterBytes, length: extentLen)
                    collected.append(chunk)
                } else {
                    collected.append(Data(repeating: 0, count: extentLen))
                }
                remaining -= extentLen
            }
            bytes = collected
        }
        let bm = Bitmap(bytes: bytes, clusterCount: UInt64(bytes.count) * 8)
        _mftBitmap = bm
        return bm
    }

    /// Allocate the next free MFT record (>= firstUserRecord). Marks the bit
    /// as in-use and persists the bitmap to disk atomically (in the sense
    /// that the on-disk bitmap is updated before this returns). The caller
    /// then writes the new MFT record's content with IN_USE=1.
    ///
    /// Throws `outOfSpace` if the bitmap has no free user-region bit. If the
    /// bitmap covers fewer slots than the user wants to allocate, the
    /// `unsupportedFeature` error nudges the user toward $MFT growth (which
    /// is a separate future feature; for now, full bitmaps are terminal).
    public func allocateMFTRecord() async throws -> UInt64 {
        var bm = try await mftBitmap()
        for n in MFT.firstUserRecord..<bm.clusterCount {
            if !bm.isAllocated(cluster: n) {
                // Materialized check: only allocate slots within $MFT.$DATA's
                // physical extent. Growth is implemented (growMFTDataByClusters)
                // but NOT auto-invoked from this allocator in v0.2 — the
                // grow + second-leaf-split interaction has a subtle
                // corruption bug under investigation. Real Windows-
                // formatted drives reserve 12.5% of the volume for $MFT
                // growth, so on a 4 TB drive `allocatedSize` covers
                // hundreds of millions of records — plenty for phone-
                // backup workloads. The cap mainly bites tiny fixtures.
                if try await isMFTRecordSlotMaterialized(n) {
                    try bm.markAllocated(startLCN: n, count: 1)
                    try await persistMFTBitmap(bm)
                    _mftBitmap = bm
                    try await bumpMFTDataRealSizeIfNeeded(toCoverSlot: n)
                    return n
                }
                throw NTFSError.unsupportedFeature(
                    description: "MFT slot \(n) is free in $MFT.$BITMAP but past $MFT.$DATA's allocatedSize; auto-grow is disabled in v0.2 (call growMFTDataByClusters() manually if needed)"
                )
            }
        }
        throw NTFSError.outOfSpace(requestedClusters: 1, freeClusters: 0)
    }

    /// Grow $MFT itself by N more clusters. Allocates from $Bitmap, zeros
    /// the new clusters (so they parse as never-used empty slots), extends
    /// $MFT.$DATA's runlist + allocatedSize, and extends $MFT.$BITMAP's
    /// realSize so the new slots are visible to the allocator.
    ///
    /// Failure ordering matters for crash safety:
    ///  1. Allocate clusters (volume $Bitmap updated + persisted).
    ///  2. Zero the new clusters (no MFT reference yet — a crash here just
    ///     leaks the clusters as "allocated but unreferenced," which chkdsk
    ///     reclaims).
    ///  3. Extend $MFT.$BITMAP's realSize.
    ///  4. Extend $MFT.$DATA's runlist + allocatedSize.
    /// Steps 3 + 4 should ideally be atomic; we order so $BITMAP grows first
    /// (slots become "free in bitmap" first), then $DATA covers them. A
    /// crash between 3 and 4 leaves bits 1 in bitmap referencing slots past
    /// $DATA.allocatedSize — caught by isMFTRecordSlotMaterialized() guard.
    ///
    /// `clusterCount` of 4-16 is the sweet spot — small enough that growth
    /// is granular, big enough that we're not paying overhead per record.
    public func growMFTDataByClusters(_ clusterCount: UInt64) async throws {
        guard clusterCount > 0 else { return }

        // 1. Allocate (volume bitmap).
        let extent = try await allocateClusters(clusterCount)
        guard let newLCN = extent.startLCN else {
            throw NTFSError.corruptOnDisk(description: "growMFTDataByClusters: sparse extent")
        }
        let clusterBytes = UInt64(bytesPerCluster)

        // 2. Zero the new clusters so they parse as "all-zero" empty MFT
        //    slots (magic=0x00000000 — our bitmap allocator already treats
        //    that as "free / never used"; verify() does the same).
        let zeroChunk = Data(repeating: 0, count: Int(clusterBytes))
        for c in 0..<clusterCount {
            try await device.write(offset: (newLCN + c) * clusterBytes, bytes: zeroChunk)
        }

        // Now compute what the new sizes will be.
        let mft = self.mft()
        let r0 = try await mft.record(at: 0)
        let attrs = try r0.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }),
              case let .nonResident(svcn, _, dro, cu, oldAllocated, realSize, initSize, oldExtents) = dataAttr.value else {
            throw NTFSError.unsupportedFeature(description: "growMFTDataByClusters: $MFT.$DATA must be non-resident")
        }
        // Merge with adjacent last extent if possible (keeps runlist short).
        var newExtents = oldExtents
        if let last = newExtents.last,
           let lastLCN = last.startLCN,
           lastLCN + last.clusterCount == newLCN {
            newExtents[newExtents.count - 1] = Extent(startLCN: lastLCN, clusterCount: last.clusterCount + clusterCount)
        } else {
            newExtents.append(extent)
        }
        let newTotalClusters = newExtents.reduce(0) { $0 + $1.clusterCount }
        let newAllocatedSize = newTotalClusters * clusterBytes
        let newLastVCN = newTotalClusters - 1
        let newRecordCount = newAllocatedSize / UInt64(mftRecordSizeBytes)
        let newRequiredBitmapBytes = (newRecordCount + 7) / 8

        // 3. Extend $MFT.$BITMAP if needed.
        try await growMFTBitmapToCoverBytes(newRequiredBitmapBytes)

        // 4. Rewrite $MFT record 0 with the extended $DATA attribute.
        //    (Use a freshly-read record 0; growMFTBitmapToCoverBytes may
        //    have rewritten it, invalidating our earlier read.)
        let r0Fresh = try await mft.record(at: 0)
        let newDataAttr = serializeMFTDataNonResident(
            attrID: dataAttr.header.attributeID,
            flags: dataAttr.header.flags,
            startingVCN: svcn,
            lastVCN: newLastVCN,
            dataRunsOffset: dro,
            compressionUnit: cu,
            allocatedSize: newAllocatedSize,
            realSize: realSize,
            initializedSize: initSize,
            extents: newExtents
        )
        let newRecord = try rewriteEntireAttribute(
            in: r0Fresh.bytes,
            firstAttributeOffset: Int(r0Fresh.firstAttributeOffset),
            usedSize: Int(r0Fresh.usedSize),
            recordSize: Int(r0Fresh.allocatedSize),
            replacingType: AttributeType.data.rawValue,
            attributeName: "",
            replacementBytes: newDataAttr
        )
        guard let mark = locateEndMarker(in: newRecord, fromOffset: Int(r0Fresh.firstAttributeOffset)) else {
            throw NTFSError.corruptOnDisk(description: "growMFTDataByClusters: rewritten $MFT has no end marker")
        }
        var updated = newRecord
        MFTRecord.writeU32LE(into: &updated, at: 24, value: UInt32(mark + 4))
        try await mft.writeRawRecord(at: 0, postFixupBytes: updated)
        _ = oldAllocated
        // Invalidate both caches so next reads pick up the new extents +
        // bitmap range.
        invalidateMFTCaches()
    }

    /// Extend $MFT.$BITMAP's realSize so it covers `targetBytes` bytes of
    /// bitmap (= targetBytes * 8 MFT slots). Idempotent / no-op if already
    /// at-or-above target. Currently only supports growth within the existing
    /// $BITMAP allocatedSize (no recursive bitmap-of-bitmap growth).
    private func growMFTBitmapToCoverBytes(_ targetBytes: UInt64) async throws {
        let mft = self.mft()
        let r0 = try await mft.record(at: 0)
        let attrs = try r0.attributes()
        guard let bmAttr = attrs.first(where: { $0.rawType == 0xB0 && $0.nameOrEmpty == "" }) else {
            return
        }
        switch bmAttr.value {
        case let .resident(b, _):
            // Resident bitmap (degenerate). If targetBytes > current size,
            // we'd need to grow the resident attribute, which means shifting
            // other attributes in the MFT record. Out of scope for v1.
            if UInt64(b.count) >= targetBytes { return }
            throw NTFSError.unsupportedFeature(
                description: "growMFTBitmap: resident $MFT.$BITMAP at \(b.count) bytes needs \(targetBytes); growing a resident bitmap is not yet supported"
            )
        case let .nonResident(svcn, lvcn, dro, cu, allocated, realSize, initSize, extents):
            if realSize >= targetBytes { return }
            guard targetBytes <= allocated else {
                throw NTFSError.unsupportedFeature(
                    description: "growMFTBitmap: $MFT.$BITMAP allocatedSize=\(allocated) too small for required \(targetBytes); cascading bitmap growth not yet implemented"
                )
            }
            // Zero the slack between realSize and targetBytes so the new bits read as "free".
            let clusterBytes = UInt64(bytesPerCluster)
            var bytesToZero = targetBytes - realSize
            var cursor = realSize
            for ex in extents where bytesToZero > 0 {
                guard let lcn = ex.startLCN else { continue }
                let extentBytes = ex.clusterCount * clusterBytes
                let extentEnd = (extents.prefix(while: { $0 != ex }).reduce(0) { $0 + $1.clusterCount } * clusterBytes) + extentBytes
                if cursor >= extentEnd { continue }
                let inExtent = cursor - (extentEnd - extentBytes)
                let writable = min(bytesToZero, extentBytes - inExtent)
                let off = lcn * clusterBytes + inExtent
                let zeroes = Data(repeating: 0, count: Int(writable))
                try await device.write(offset: off, bytes: zeroes)
                cursor += writable
                bytesToZero -= writable
            }
            // Re-serialize $BITMAP with the bumped realSize.
            let newAttr = serializeMFTBitmapNonResident(
                attrID: bmAttr.header.attributeID,
                flags: bmAttr.header.flags,
                startingVCN: svcn,
                lastVCN: lvcn,
                dataRunsOffset: dro,
                compressionUnit: cu,
                allocatedSize: allocated,
                realSize: targetBytes,
                initializedSize: max(initSize, targetBytes),
                extents: extents
            )
            let newRec = try rewriteEntireAttribute(
                in: r0.bytes,
                firstAttributeOffset: Int(r0.firstAttributeOffset),
                usedSize: Int(r0.usedSize),
                recordSize: Int(r0.allocatedSize),
                replacingType: 0xB0,
                attributeName: "",
                replacementBytes: newAttr
            )
            guard let mark = locateEndMarker(in: newRec, fromOffset: Int(r0.firstAttributeOffset)) else {
                throw NTFSError.corruptOnDisk(description: "growMFTBitmap: rewritten $MFT has no end marker")
            }
            var updated = newRec
            MFTRecord.writeU32LE(into: &updated, at: 24, value: UInt32(mark + 4))
            try await mft.writeRawRecord(at: 0, postFixupBytes: updated)
            _mftBitmap = nil
        }
    }

    /// Build a $BITMAP non-resident attribute preserving header fields. Mirror
    /// of serializeMFTDataNonResident but with type 0xB0.
    private func serializeMFTBitmapNonResident(
        attrID: UInt16,
        flags: UInt16,
        startingVCN: UInt64,
        lastVCN: UInt64,
        dataRunsOffset: UInt16,
        compressionUnit: UInt8,
        allocatedSize: UInt64,
        realSize: UInt64,
        initializedSize: UInt64,
        extents: [Extent]
    ) -> Data {
        let runlist = encodeRunlist(extents: extents)
        let bodyLen = 64 + runlist.count
        let alignedLen = ((bodyLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &data, at: 0,  value: 0xB0)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 1
        data[data.startIndex + 9] = 0
        MFTRecord.writeU16LE(into: &data, at: 10, value: 0)
        MFTRecord.writeU16LE(into: &data, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        MFTRecord.writeU64LE(into: &data, at: 16, value: startingVCN)
        MFTRecord.writeU64LE(into: &data, at: 24, value: lastVCN)
        MFTRecord.writeU16LE(into: &data, at: 32, value: 64)
        data[data.startIndex + 34] = compressionUnit
        MFTRecord.writeU64LE(into: &data, at: 40, value: allocatedSize)
        MFTRecord.writeU64LE(into: &data, at: 48, value: realSize)
        MFTRecord.writeU64LE(into: &data, at: 56, value: initializedSize)
        for (i, byte) in runlist.enumerated() {
            data[data.startIndex + 64 + i] = byte
        }
        _ = dataRunsOffset
        return data
    }

    /// Ensure $MFT.$DATA's realSize covers at least `(slot+1) * recordSize`.
    /// Idempotent / cheap when realSize is already large enough. Called from
    /// allocateMFTRecord whenever a freshly-allocated slot is past the
    /// previous high-water mark.
    private func bumpMFTDataRealSizeIfNeeded(toCoverSlot slot: UInt64) async throws {
        let mft = self.mft()
        let r0 = try await mft.record(at: 0)
        let attrs = try r0.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            return
        }
        guard case let .nonResident(svcn, lvcn, dro, cu, allocated, realSize, _, extents) = dataAttr.value else {
            return  // resident $MFT.$DATA only happens on degenerate fixtures
        }
        let need = (slot + 1) * UInt64(mftRecordSizeBytes)
        if realSize >= need { return }
        // Refuse to bump past allocatedSize (that would require growing the
        // $DATA runlist — separate feature).
        guard need <= allocated else {
            throw NTFSError.unsupportedFeature(
                description: "bumpMFTDataRealSize: slot \(slot) needs realSize=\(need) but allocatedSize=\(allocated); growing $MFT.$DATA runlist not yet implemented"
            )
        }
        // Re-serialize the $DATA attribute with new realSize + initializedSize.
        // Use the existing serializeNonResidentDataAttribute helper but feed
        // the existing extents + the new realSize.
        let newDataAttr = serializeMFTDataNonResident(
            attrID: dataAttr.header.attributeID,
            flags: dataAttr.header.flags,
            startingVCN: svcn,
            lastVCN: lvcn,
            dataRunsOffset: dro,
            compressionUnit: cu,
            allocatedSize: allocated,
            realSize: need,
            initializedSize: need,
            extents: extents
        )
        let newRecordBytes = try rewriteEntireAttribute(
            in: r0.bytes,
            firstAttributeOffset: Int(r0.firstAttributeOffset),
            usedSize: Int(r0.usedSize),
            recordSize: Int(r0.allocatedSize),
            replacingType: AttributeType.data.rawValue,
            attributeName: "",
            replacementBytes: newDataAttr
        )
        guard let mark = locateEndMarker(in: newRecordBytes, fromOffset: Int(r0.firstAttributeOffset)) else {
            throw NTFSError.corruptOnDisk(description: "bumpMFTDataRealSize: rewritten $MFT has no end marker")
        }
        var updated = newRecordBytes
        MFTRecord.writeU32LE(into: &updated, at: 24, value: UInt32(mark + 4))
        try await mft.writeRawRecord(at: 0, postFixupBytes: updated)
    }

    /// Build a $DATA non-resident attribute preserving all the existing
    /// header fields (startingVCN, lastVCN, compressionUnit, runlist) — used
    /// by bumpMFTDataRealSizeIfNeeded which needs to update realSize while
    /// keeping everything else identical to the on-disk attribute.
    private func serializeMFTDataNonResident(
        attrID: UInt16,
        flags: UInt16,
        startingVCN: UInt64,
        lastVCN: UInt64,
        dataRunsOffset: UInt16,
        compressionUnit: UInt8,
        allocatedSize: UInt64,
        realSize: UInt64,
        initializedSize: UInt64,
        extents: [Extent]
    ) -> Data {
        let runlist = encodeRunlist(extents: extents)
        let bodyLen = 64 + runlist.count
        let alignedLen = ((bodyLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &data, at: 0,  value: AttributeType.data.rawValue)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 1           // non-resident
        data[data.startIndex + 9] = 0           // nameLength = 0 (unnamed $DATA)
        MFTRecord.writeU16LE(into: &data, at: 10, value: 0)
        MFTRecord.writeU16LE(into: &data, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        MFTRecord.writeU64LE(into: &data, at: 16, value: startingVCN)
        MFTRecord.writeU64LE(into: &data, at: 24, value: lastVCN)
        MFTRecord.writeU16LE(into: &data, at: 32, value: 64)   // dataRunsOffset right after non-res ext
        data[data.startIndex + 34] = compressionUnit
        // 35-39 reserved zero
        MFTRecord.writeU64LE(into: &data, at: 40, value: allocatedSize)
        MFTRecord.writeU64LE(into: &data, at: 48, value: realSize)
        MFTRecord.writeU64LE(into: &data, at: 56, value: initializedSize)
        for (i, byte) in runlist.enumerated() {
            data[data.startIndex + 64 + i] = byte
        }
        _ = dataRunsOffset
        return data
    }

    /// Mark an MFT record as free in the $BITMAP. Called from deleteFile and
    /// the rollback path in createFile. Idempotent.
    public func freeMFTRecord(_ recordNumber: UInt64) async throws {
        var bm = try await mftBitmap()
        if recordNumber >= bm.clusterCount { return }
        if !bm.isAllocated(cluster: recordNumber) { return }
        try bm.markFree(startLCN: recordNumber, count: 1)
        try await persistMFTBitmap(bm)
        _mftBitmap = bm
    }

    /// Mark a record as allocated in the $BITMAP. Mirror of freeMFTRecord;
    /// used when promoting an existing record (e.g. a manually-written
    /// record-by-recnum to the bitmap-tracked state). Idempotent.
    public func markMFTRecordAllocated(_ recordNumber: UInt64) async throws {
        var bm = try await mftBitmap()
        if recordNumber >= bm.clusterCount { return }
        if bm.isAllocated(cluster: recordNumber) { return }
        try bm.markAllocated(startLCN: recordNumber, count: 1)
        try await persistMFTBitmap(bm)
        _mftBitmap = bm
    }

    /// Is the MFT slot physically allocated in $MFT.$DATA (i.e., disk space
    /// for the record exists, not just a free bitmap bit)? Uses
    /// `allocatedSize` rather than `realSize` because NTFS pre-allocates
    /// clusters for $MFT in chunks; slots within allocatedSize have backing
    /// storage even if they're past the high-water mark realSize. Slots past
    /// allocatedSize require growing $MFT.$DATA itself (a separate feature).
    private func isMFTRecordSlotMaterialized(_ recordNumber: UInt64) async throws -> Bool {
        let mft = self.mft()
        let r0 = try await mft.record(at: 0)
        let attrs = try r0.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            return false
        }
        let allocatedSize: UInt64
        switch dataAttr.value {
        case let .resident(b, _): allocatedSize = UInt64(b.count)
        case let .nonResident(_, _, _, _, a, _, _, _): allocatedSize = a
        }
        let logicalRecords = allocatedSize / UInt64(mftRecordSizeBytes)
        return recordNumber < logicalRecords
    }

    /// Write the $BITMAP bytes back to whatever storage backs them (resident
    /// → rewrite the $MFT MFT record; non-resident → write to the extents).
    private func persistMFTBitmap(_ bm: Bitmap) async throws {
        let mft = self.mft()
        let r0 = try await mft.record(at: 0)
        let attrs = try r0.attributes()
        guard let bmAttr = attrs.first(where: { $0.rawType == 0xB0 && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(description: "persistMFTBitmap: $MFT lacks $BITMAP")
        }
        switch bmAttr.value {
        case .resident:
            // Rewrite the $MFT MFT record with the new $BITMAP value.
            let newAttrBytes = serializeResidentAttribute(
                type: 0xB0,
                attrID: bmAttr.header.attributeID,
                flags: bmAttr.header.flags,
                attributeName: "",
                value: bm.bytes
            )
            let newRecordBytes = try rewriteEntireAttribute(
                in: r0.bytes,
                firstAttributeOffset: Int(r0.firstAttributeOffset),
                usedSize: Int(r0.usedSize),
                recordSize: Int(r0.allocatedSize),
                replacingType: 0xB0,
                attributeName: "",
                replacementBytes: newAttrBytes
            )
            guard let mark = locateEndMarker(in: newRecordBytes, fromOffset: Int(r0.firstAttributeOffset)) else {
                throw NTFSError.corruptOnDisk(description: "persistMFTBitmap: rewritten $MFT has no end marker")
            }
            var updated = newRecordBytes
            MFTRecord.writeU32LE(into: &updated, at: 24, value: UInt32(mark + 4))
            try await mft.writeRawRecord(at: 0, postFixupBytes: updated)
        case let .nonResident(_, _, _, _, _, _, _, extents):
            let clusterBytes = UInt64(bytesPerCluster)
            var bytesRemaining = bm.bytes
            for extent in extents where !bytesRemaining.isEmpty {
                guard let startLCN = extent.startLCN else { continue }
                let extentBytes = Int(min(extent.clusterCount * clusterBytes, UInt64(bytesRemaining.count)))
                let chunk = bytesRemaining.prefix(extentBytes)
                try await device.write(offset: startLCN * clusterBytes, bytes: Data(chunk))
                bytesRemaining = bytesRemaining.dropFirst(extentBytes)
            }
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
        // T1.1: allocate via $MFT.$BITMAP (authoritative). Fall back to the
        // linear scan only if no $BITMAP attribute exists (degenerate fixture
        // — shouldn't happen on real volumes).
        let recordNumber: UInt64
        do {
            recordNumber = try await allocateMFTRecord()
        } catch NTFSError.corruptOnDisk {
            // No $BITMAP — degenerate; fall back to the legacy linear scan.
            recordNumber = try await mft.findFreeRecordNumber()
        }

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
            try? await reclaimOrphanedMFTRecord(at: recordNumber)
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
        let attrs = try await allAttributesOf(recordNumber: parentRecordNumber)

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
            // LARGE_INDEX path: descend the B-tree to find the right leaf and
            // insert there. The MFT record / $INDEX_ROOT is unchanged; the
            // mutation happens entirely inside an INDX block in $INDEX_ALLOCATION.
            guard let allocAttr = attrs.first(where: {
                $0.type == .indexAllocation && $0.nameOrEmpty == "$I30"
            }) else {
                throw NTFSError.corruptOnDisk(
                    description: "LARGE_INDEX parent \(parentRecordNumber) is missing $INDEX_ALLOCATION:$I30"
                )
            }
            guard case let .nonResident(_, _, _, _, _, _, _, allocExtents) = allocAttr.value else {
                throw NTFSError.corruptOnDisk(description: "$INDEX_ALLOCATION:$I30 must be non-resident")
            }
            let parentRef = (UInt64(parent.sequenceNumber) << 48) | (parentRecordNumber & 0x0000_FFFF_FFFF_FFFF)
            let childRef  = (UInt64(childSequence) << 48) | (childRecordNumber & 0x0000_FFFF_FFFF_FFFF)
            let childBody = buildFileNameBody(
                parentReference: parentRef,
                fileName: childFileName,
                isDirectory: isDirectory,
                nowFiletime: nowFiletime
            )
            let outcome = try await IndexAllocationWriter.insert(
                rootBody: rootBytes,
                allocationExtents: allocExtents,
                indexRecordSizeBytes: indexRecordSizeBytes,
                bytesPerCluster: bytesPerCluster,
                sectorSize: Int(boot.bytesPerSector),
                device: device,
                newSortKey: childFileName,
                newEntryFileRef: childRef,
                newEntryBody: childBody,
                leafCache: _bulkInsertLeafCache
            )
            switch outcome {
            case .inserted:
                return
            case let .leafFull(leafVCN, leafByteOffset, _, _, _, merged):
                // T1.2: split the full leaf, promote the median into $INDEX_ROOT.
                try await splitLeafAndPromote(
                    parentRecordNumber: parentRecordNumber,
                    leafVCN: leafVCN,
                    leafByteOffset: leafByteOffset,
                    mergedSortedEntries: merged,
                    rootBytes: rootBytes,
                    indexRoot: root,
                    allocationExtents: allocExtents
                )
                return
            }
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
        // Detect the overflow case and trigger a small→LARGE_INDEX promotion
        // so the directory can grow past the resident-only ceiling
        // (~5-7 entries for typical name lengths on a 1024-byte MFT record).
        do {
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
        } catch NTFSError.unsupportedFeature(let desc) where isOverflowDescription(desc) {
            // v0.5 Fix B Step 3: predicate widened to catch both
            // `rewriteResidentAttribute` ($INDEX_ROOT) and
            // `rewriteEntireAttribute` ($INDEX_ALLOCATION / $BITMAP)
            // overflow throws — though only the small→LARGE_INDEX
            // promotion below makes sense here, because at this
            // point the directory is still resident-only and has no
            // $INDEX_ALLOCATION attribute to migrate. The migration
            // helper is wired into the LARGE_INDEX leaf-split catch
            // sites in `computeParentRecordBytesForSplit` and
            // `promoteThroughInteriorChain`.
            //
            // Promote to LARGE_INDEX and retry. The promotion moves the existing
            // entries (without the new one — we'll re-insert through the
            // LARGE_INDEX path) into a fresh $INDEX_ALLOCATION leaf and shrinks
            // $INDEX_ROOT to an empty interior root.
            try await promoteDirectoryToLargeIndex(parentRecordNumber: parentRecordNumber)
            // Re-call ourselves; this time root.isLargeIndex == true so the
            // first branch (LARGE_INDEX leaf insert) runs.
            try await insertIntoParentI30(
                parentRecordNumber: parentRecordNumber,
                childRecordNumber: childRecordNumber,
                childSequence: childSequence,
                childFileName: childFileName,
                isDirectory: isDirectory,
                nowFiletime: nowFiletime
            )
        }
    }

    /// Promote a resident-only ("small") directory to LARGE_INDEX by:
    ///   1) allocating one cluster for a fresh $INDEX_ALLOCATION leaf
    ///   2) moving all existing $INDEX_ROOT entries into that leaf
    ///   3) replacing $INDEX_ROOT with an empty interior root (LAST sentinel
    ///      with HAS_SUBNODE pointing at VCN 0)
    ///   4) inserting $INDEX_ALLOCATION:$I30 (non-resident runlist) and
    ///      $BITMAP:$I30 (resident, 8 bytes) attributes into the parent record
    ///
    /// After promotion, the existing LARGE_INDEX insert path can handle
    /// arbitrarily many subsequent inserts (until any single INDX leaf fills).
    private func promoteDirectoryToLargeIndex(parentRecordNumber: UInt64) async throws {
        let mft = self.mft()
        let parent = try await mft.record(at: parentRecordNumber)
        let attrs = try await allAttributesOf(recordNumber: parentRecordNumber)
        guard let indexRootAttr = attrs.first(where: {
            $0.type == .indexRoot && $0.nameOrEmpty == "$I30"
        }) else {
            throw NTFSError.corruptOnDisk(description: "promote: parent \(parentRecordNumber) lacks $INDEX_ROOT:$I30")
        }
        guard case let .resident(rootBytes, _) = indexRootAttr.value else {
            throw NTFSError.corruptOnDisk(description: "promote: $INDEX_ROOT:$I30 must be resident")
        }
        let root = try IndexRoot.parse(rootBytes)
        if root.isLargeIndex {
            return  // already promoted; nothing to do
        }

        // 1) Allocate one cluster for the leaf INDX block. The block size
        //    equals indexRecordSizeBytes (typically 4096) — for the very
        //    common 4 KiB cluster + 4 KiB INDX volume this is exactly one
        //    cluster. If indexRecordSizeBytes > bytesPerCluster the math
        //    would need clusters_per_block; we reject that mismatch.
        let clusterBytes = UInt64(bytesPerCluster)
        guard UInt64(indexRecordSizeBytes) == clusterBytes else {
            throw NTFSError.unsupportedFeature(
                description: "promote: indexRecordSizeBytes (\(indexRecordSizeBytes)) != bytesPerCluster (\(clusterBytes)) — multi-cluster INDX promotion not yet supported"
            )
        }
        let extent = try await allocateClusters(1)
        guard let leafLCN = extent.startLCN else {
            throw NTFSError.corruptOnDisk(description: "promote: allocator returned sparse extent")
        }

        // 2) Build the leaf INDX block with all current entries.
        var leafEntries: [(UInt64, Data, String)] = []
        for entry in root.entries {
            guard !entry.isLast, let fn = entry.fileName else { continue }
            leafEntries.append((entry.fileReference, reserializeFileNameBody(fn), fn.name))
        }
        leafEntries.sort { IndexBuilder.collationFilenameSortsBefore($0.2, $1.2) }

        let indxBytes = try buildEmptyIndxBlock(
            blockSize: Int(indexRecordSizeBytes),
            sectorSize: Int(boot.bytesPerSector),
            vcn: 0,
            entries: leafEntries
        )
        let indxOnDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: indxBytes,
            usaOffset: Int(try indxBytes.readU16LE(at: 4)),
            usaCount: Int(try indxBytes.readU16LE(at: 6)),
            blockSize: Int(boot.bytesPerSector)
        )
        try await device.write(offset: leafLCN * clusterBytes, bytes: indxOnDisk)

        // 3) Build new $INDEX_ROOT: empty entries list with LAST+HAS_SUBNODE→VCN 0.
        let newRootBody = buildLargeIndexEmptyRoot(
            indexAllocationBlockSize: UInt32(indexRecordSizeBytes),
            clustersPerIndexBlock: root.clustersPerIndexBlock,
            firstSubnodeVCN: 0
        )

        // 4) Build new $INDEX_ALLOCATION:$I30 attribute (non-resident, single-extent runlist).
        let allocAttrID: UInt16 = UInt16(parent.nextAttributeID)
        let bitmapAttrID: UInt16 = UInt16(parent.nextAttributeID &+ 1)
        let allocAttrBytes = buildIndexAllocationAttribute(
            attrID: allocAttrID,
            extent: extent,
            clusterBytes: clusterBytes
        )
        // 5) Build $BITMAP:$I30 — 8 bytes resident (room for 64 INDX blocks; promote
        //    when we exceed that).
        var bitmapBody = Data(count: 8)
        bitmapBody[0] = 0x01   // INDX block 0 is allocated
        let bitmapAttrBytes = buildNamedResidentAttribute(
            type: 0xB0,   // $BITMAP
            attrID: bitmapAttrID,
            flags: 0,
            attributeName: "$I30",
            value: bitmapBody
        )

        // 6) Rewrite parent: replace $INDEX_ROOT in place + append the two new attributes
        //    before the end marker.
        var newParent = try rewriteResidentAttribute(
            in: parent.bytes,
            firstAttributeOffset: Int(parent.firstAttributeOffset),
            usedSize: Int(parent.usedSize),
            recordSize: Int(parent.allocatedSize),
            replacingType: AttributeType.indexRoot.rawValue,
            attributeName: "$I30",
            newValueBytes: newRootBody
        )
        // Locate the new end marker and splice in the two new attributes before it.
        guard var endMarkerPos = locateEndMarker(in: newParent, fromOffset: Int(parent.firstAttributeOffset)) else {
            throw NTFSError.corruptOnDisk(description: "promote: rewritten parent missing end marker")
        }
        let combinedNewAttrs = allocAttrBytes + bitmapAttrBytes
        guard endMarkerPos + combinedNewAttrs.count + 4 <= Int(parent.allocatedSize) else {
            throw NTFSError.unsupportedFeature(
                description: "promote: parent record (\(parent.allocatedSize)) cannot fit additional \(combinedNewAttrs.count) bytes for $INDEX_ALLOCATION + $BITMAP"
            )
        }
        // Splice: write the new attributes at endMarkerPos, then end marker after.
        for (i, byte) in combinedNewAttrs.enumerated() {
            newParent[newParent.startIndex + endMarkerPos + i] = byte
        }
        endMarkerPos += combinedNewAttrs.count
        MFTRecord.writeU32LE(into: &newParent, at: endMarkerPos, value: AttributeType.endMarker)
        // Clear any leftover bytes between new end marker and old usedSize.
        let usedAfter = endMarkerPos + 4
        if usedAfter < Int(parent.usedSize) + combinedNewAttrs.count {
            // No-op: Data(count: recordSize) already zeroed; but rewriteResidentAttribute
            // copied tail bytes that may contain stale content. Zero them now.
            for i in usedAfter..<Int(parent.allocatedSize) {
                newParent[newParent.startIndex + i] = 0
            }
        }
        MFTRecord.writeU32LE(into: &newParent, at: 24, value: UInt32(usedAfter))
        // Bump nextAttributeID by 2 (we consumed two IDs).
        MFTRecord.writeU16LE(into: &newParent, at: 40, value: parent.nextAttributeID &+ 2)
        try await mft.writeRawRecord(at: parentRecordNumber, postFixupBytes: newParent)
    }

    /// Leaf split scaffold (NOT YET WIRED): when a LARGE_INDEX leaf is full,
    /// divide its entries (plus the new entry, already merged into sorted
    /// order) across two leaves, promote the median entry into $INDEX_ROOT
    /// as an interior entry, and extend the directory's $INDEX_ALLOCATION +
    /// $BITMAP to cover the new leaf block.
    ///
    /// **Currently disabled** — the parent-record rewrite after a second
    /// split (when $INDEX_ROOT already has an interior entry) produces a
    /// corrupted MFT record. The first split works in isolation but the
    /// second corrupts state in a way that USA fix-up later rejects. Needs
    /// more careful design + testing; see STATUS.md #2.
    // T1.2: enabled.
    ///
    /// v1 scope:
    ///  - Only handles single-level trees ($INDEX_ROOT directly points at
    ///    leaves; promoted median lands in $INDEX_ROOT). If the existing
    ///    $INDEX_ROOT already has too many interior entries to absorb one
    ///    more, this throws unsupportedFeature — tree-height growth is a
    ///    future enhancement.
    ///  - Only handles indexRecordSizeBytes == bytesPerCluster (the common
    ///    case). Otherwise multi-cluster INDX block math would be needed.
    private func splitLeafAndPromote(
        parentRecordNumber: UInt64,
        leafVCN: UInt64,
        leafByteOffset: UInt64,
        mergedSortedEntries: [(fileRef: UInt64, body: Data, sortKey: String)],
        rootBytes: Data,
        indexRoot: IndexRoot,
        allocationExtents: [Extent]
    ) async throws {
        // Snapshot whole-tree state BEFORE the split so the post-split
        // verification can compare delta correctly. Expected after split:
        // exactly +1 entry (the new one we're trying to insert).
        let beforeSplitRefs = try await collectAllFileRefsInLargeIndex(parentRecordNumber: parentRecordNumber)
        let newEntryRef = mergedSortedEntries.first(where: { !beforeSplitRefs.contains($0.fileRef) })?.fileRef ?? 0
        let clusterBytes = UInt64(bytesPerCluster)
        guard UInt64(indexRecordSizeBytes) == clusterBytes else {
            throw NTFSError.unsupportedFeature(
                description: "splitLeaf: indexRecordSizeBytes (\(indexRecordSizeBytes)) != bytesPerCluster (\(clusterBytes)) not supported"
            )
        }

        // 1. Choose the median entry. Bisect by byte size so left and right
        //    are roughly balanced — using count alone biases when entry sizes
        //    vary (filenames of different lengths).
        let entries = mergedSortedEntries
        let totalEntryBytes = entries.reduce(0) { acc, e in
            let rawLen = 16 + e.body.count
            return acc + ((rawLen + 7) / 8) * 8
        }
        var accumulated = 0
        var medianIdx = entries.count / 2  // default
        for (i, e) in entries.enumerated() {
            let rawLen = 16 + e.body.count
            accumulated += ((rawLen + 7) / 8) * 8
            if accumulated * 2 >= totalEntryBytes {
                medianIdx = i
                break
            }
        }
        if medianIdx == 0 { medianIdx = 1 }
        if medianIdx >= entries.count { medianIdx = entries.count - 1 }
        let median = entries[medianIdx]
        let leftEntries = Array(entries[0..<medianIdx])
        let rightEntries = Array(entries[(medianIdx + 1)..<entries.count])
        // Guard: empty halves would mean we can't actually split anything.
        guard !leftEntries.isEmpty, !rightEntries.isEmpty else {
            throw NTFSError.unsupportedFeature(
                description: "splitLeaf: cannot bisect \(entries.count) entries (median index \(medianIdx))"
            )
        }

        // 2. Allocate one new cluster for the right-half leaf.
        let newExtent = try await allocateClusters(1)
        guard let newLCN = newExtent.startLCN else {
            throw NTFSError.corruptOnDisk(description: "splitLeaf: allocator returned sparse extent")
        }
        let newVCN = allocationExtents.reduce(0) { $0 + $1.clusterCount }
        // Sanity check: the allocator should never hand us a cluster that's
        // already in use by THIS directory's $INDEX_ALLOCATION extents.
        // If it does, our subsequent write would clobber existing leaves
        // — the orphan bug. Loud failure here is far better than silent
        // data loss.
        for existing in allocationExtents {
            guard let exLCN = existing.startLCN else { continue }
            let exEnd = exLCN + existing.clusterCount
            if newLCN >= exLCN && newLCN < exEnd {
                throw NTFSError.corruptOnDisk(
                    description: "splitLeaf: allocator returned LCN \(newLCN) which overlaps existing $INDEX_ALLOCATION extent [\(exLCN)..\(exEnd)). Cluster-reuse bug — refusing to write."
                )
            }
        }

        // 3. Pre-flight: compute the new parent MFT record bytes IN MEMORY
        //    before mutating any disk state. This is where the v0.3
        //    silent-orphan bug used to live — `rewriteIndexRootForSplit`
        //    threw "would overflow parent record" AFTER the LEFT/RIGHT leaf
        //    writes had already mutated disk, leaving the original leaf
        //    half-rewritten and the new cluster unreachable. By moving the
        //    in-memory build (and its overflow check) ahead of the leaf
        //    writes, an overflow now aborts cleanly: only the freshly
        //    allocated cluster has been touched, and we free it below.
        let computed: ComputedSplit
        do {
            computed = try await computeParentRecordBytesForSplit(
                parentRecordNumber: parentRecordNumber,
                indexRoot: indexRoot,
                rootBytes: rootBytes,
                splitLeafVCN: leafVCN,
                newLeafVCN: newVCN,
                medianEntry: median,
                allocationExtents: allocationExtents,
                newExtent: newExtent
            )
        } catch {
            // Compute step failed (out-of-space allocating intermediates,
            // or some other unrecoverable error). Release the leaf cluster
            // we provisionally allocated — disk is otherwise pristine.
            // height-grow path's intermediate allocations are freed inside
            // computeParentRecordBytesForSplit on its own throw.
            try? await freeClusters(newExtent)
            throw error
        }
        let newParentRecordBytes = computed.parentRecordBytes

        // 4. Build the LEFT leaf — rewrite original leaf bytes with leftEntries.
        let blockSize = Int(indexRecordSizeBytes)
        let sectorSize = Int(boot.bytesPerSector)
        let originalLeafRaw = try await device.read(offset: leafByteOffset, length: blockSize)
        let originalLeafFixed = try UpdateSequenceArray.applyFixup(
            recordBytes: originalLeafRaw,
            usaOffset: Int(try originalLeafRaw.readU16LE(at: 4)),
            usaCount: Int(try originalLeafRaw.readU16LE(at: 6)),
            blockSize: sectorSize
        )
        let leftBlock = try IndexAllocationWriter.buildLeafIndexBlock(
            sourceBlockBytes: originalLeafFixed,
            sortedEntries: leftEntries.map { ($0.fileRef, $0.body, $0.sortKey) },
            blockSize: blockSize
        )
        let leftOnDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: leftBlock,
            usaOffset: Int(try leftBlock.readU16LE(at: 4)),
            usaCount: Int(try leftBlock.readU16LE(at: 6)),
            blockSize: sectorSize
        )
        try await device.write(offset: leafByteOffset, bytes: leftOnDisk)

        // 5. Build the RIGHT leaf at the new VCN — fresh block with rightEntries.
        let rightBlock = try buildEmptyIndxBlock(
            blockSize: blockSize,
            sectorSize: sectorSize,
            vcn: newVCN,
            entries: rightEntries.map { ($0.fileRef, $0.body, $0.sortKey) }
        )
        let rightOnDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: rightBlock,
            usaOffset: Int(try rightBlock.readU16LE(at: 4)),
            usaCount: Int(try rightBlock.readU16LE(at: 6)),
            blockSize: sectorSize
        )
        try await device.write(offset: newLCN * clusterBytes, bytes: rightOnDisk)

        // 6. (v0.4 Phase 3(A)) If height-grow fired, write the new
        //    intermediate INDX blocks BEFORE committing the parent record.
        //    Order matters: the parent record's new $INDEX_ROOT will point
        //    at these intermediates, so they must exist on disk first or a
        //    crash between writes would orphan dependent references.
        for intermediate in computed.intermediates {
            try await device.write(
                offset: intermediate.byteOffset,
                bytes: intermediate.postFixupBytes
            )
        }

        // 7. Commit the precomputed parent MFT record (overflow already
        //    ruled out in step 3, possibly after a height-grow). This
        //    finalizes the split atomically from the tree-shape
        //    perspective.
        let mft = self.mft()
        try await mft.writeRawRecord(at: parentRecordNumber, postFixupBytes: newParentRecordBytes)
        // Self-check: re-read + re-parse + walk attributes. Any malformation
        // surfaces here with a precise location rather than as a later
        // mysterious USA-fixup mismatch in the next descent.
        try await verifyParentRecord(parentRecordNumber, context: "after split of leaf VCN \(leafVCN)")

        // T1.2 deep verification: walk the tree post-split and compare to
        // the pre-split snapshot. After exactly one split that promoted
        // the median into $INDEX_ROOT, the tree should hold (before +
        // newEntryRef) entries — no more, no less. Captures the
        // silent-orphan bug at the moment of corruption.
        let afterSplitRefs = try await collectAllFileRefsInLargeIndex(parentRecordNumber: parentRecordNumber)
        let expectedAfter = beforeSplitRefs.union([newEntryRef])
        if afterSplitRefs != expectedAfter {
            let missing = expectedAfter.subtracting(afterSplitRefs).sorted()
            let extra = afterSplitRefs.subtracting(expectedAfter).sorted()
            let report = "[split-verify FAIL] parent=\(parentRecordNumber) splitLeafVCN=\(leafVCN) newLeafVCN=\(newVCN) before=\(beforeSplitRefs.count) after=\(afterSplitRefs.count) expected=\(expectedAfter.count) newEntry=\(newEntryRef) missing=\(missing) extra=\(extra)\n"
            FileHandle.standardError.write(Data(report.utf8))
            throw NTFSError.corruptOnDisk(
                description: "splitLeafAndPromote: post-split state mismatch — before=\(beforeSplitRefs.count) after=\(afterSplitRefs.count) expected=\(expectedAfter.count) missing=\(missing.count) extra=\(extra.count). Leaf-split orphan bug at moment of corruption."
            )
        }
    }

    /// v0.4 Phase 3(A): result of `computeParentRecordBytesForSplit`. The
    /// common case has `intermediates` empty + `extraClustersAllocated`
    /// empty. The height-grow case has 2 intermediate INDX blocks the
    /// caller must write to disk BEFORE the parent record write, plus
    /// the 2 extra cluster extents (caller frees these on failure).
    private struct ComputedSplit {
        let parentRecordBytes: Data
        /// Each entry: (byteOffset on disk, post-USA-fixup bytes to write).
        /// Empty when no height-grow occurred.
        let intermediates: [(byteOffset: UInt64, postFixupBytes: Data)]
        /// Extra cluster extents allocated DURING this compute (beyond the
        /// caller's primary leaf cluster). Caller must free on any
        /// failure between compute and parent-record commit.
        let extraClustersAllocated: [Extent]
    }

    /// Build the new MFT record bytes that would result from updating the
    /// parent's $INDEX_ROOT after a leaf split, AND its $INDEX_ALLOCATION
    /// runlist + $BITMAP to cover the new leaf block.
    ///
    /// **Pure compute — never mutates disk EXCEPT for allocating clusters
    /// (which mutate the volume `$Bitmap`). Allocations are returned in
    /// `extraClustersAllocated` so callers can roll them back on failure.**
    ///
    /// Throws only on unrecoverable error (corrupted on-disk shape, out of
    /// space). The v0.3 silent-orphan trigger ($INDEX_ROOT overflow on
    /// median promotion) is handled internally by height-growing the tree
    /// into 2 intermediate INDX blocks — caller doesn't see the throw.
    private func computeParentRecordBytesForSplit(
        parentRecordNumber: UInt64,
        indexRoot: IndexRoot,
        rootBytes: Data,
        splitLeafVCN: UInt64,
        newLeafVCN: UInt64,
        medianEntry: (fileRef: UInt64, body: Data, sortKey: String),
        allocationExtents: [Extent],
        newExtent: Extent
    ) async throws -> ComputedSplit {
        let mft = self.mft()
        let parent = try await mft.record(at: parentRecordNumber)
        let attrs = try await allAttributesOf(recordNumber: parentRecordNumber)

        // 5a) Build the new $INDEX_ROOT body.
        //
        // Parse current interior entries (everything before LAST sentinel),
        // insert the median as a new interior entry, and retarget pointers so
        // splitLeafVCN keeps pointing to the left (original) leaf and the
        // newLeafVCN replaces it as the "rightmost subtree" if appropriate.
        //
        // Current shape: each interior entry has a key + HAS_SUBNODE→VCN
        // pointing at the subtree whose keys are LESS than this entry's key.
        // The LAST sentinel (HAS_SUBNODE only) points at the rightmost subtree.
        let rootEntriesStart = 16 + Int(indexRoot.header.entriesOffset)
        let rootEntriesEnd = 16 + Int(indexRoot.header.usedSize)
        let parsedEntries = try parseRootInteriorEntries(in: rootBytes, start: rootEntriesStart, limit: rootEntriesEnd)

        // Decompose: real interior entries (with key+subnode) + LAST sentinel (subnode only).
        var interior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)] = []
        var lastSubnodeVCN: UInt64 = 0
        for e in parsedEntries {
            if e.isLast {
                lastSubnodeVCN = e.subnodeVCN ?? 0
            } else if let key = e.keyName {
                interior.append((
                    key: key,
                    body: e.keyBytes,
                    fileRef: e.fileReference,
                    subnodeVCN: e.subnodeVCN ?? 0
                ))
            }
        }

        // Where does splitLeafVCN sit in the current pointer set?
        //  - if lastSubnodeVCN == splitLeafVCN: the leaf we split is the RIGHTMOST
        //    leaf. The new interior entry holds the median pointing at splitLeafVCN
        //    (now containing keys < median). LAST.subnode retargets to newLeafVCN.
        //  - else splitLeafVCN appears in some interior entry's subnode pointer.
        //    That entry's subnode now points at splitLeafVCN (left half), and we
        //    insert a NEW interior entry between it and the next entry whose key
        //    is the median, pointing at... wait, this needs care.
        //
        // The classic split-promote: the leaf being split currently corresponds
        // to ONE pointer in the parent. After split, that pointer covers the
        // LEFT half (keys < median) and we need a NEW adjacent pointer covering
        // the RIGHT half (keys > median), separated by an interior entry holding
        // the median key.
        //
        // Implementation: walk parent's pointers in order. Find the slot where
        // splitLeafVCN lives. Replace that slot with: (splitLeafVCN keeping its
        // left position) + (new interior entry: median key, subnode=splitLeafVCN)
        // + (newLeafVCN as the right position). But the existing interior entry
        // ABOVE splitLeafVCN (if any) is what points at it, and the entry BELOW
        // (or LAST) is what holds the next key.
        //
        // The cleanest representation: model the parent as a sequence of
        // "tokens" — alternating (key) and (subnode VCN) — terminated by a
        // subnode VCN. e.g. [V0, K1, V1, K2, V2, ..., Kn, Vn] where K_i are
        // keys and V_i are subnode VCNs.
        var tokens: [(kind: String, key: String?, body: Data?, fileRef: UInt64?, vcn: UInt64?)] = []
        // First leftmost subnode = first interior entry's subnode if any, else lastSubnodeVCN
        if interior.isEmpty {
            tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: lastSubnodeVCN))
        } else {
            tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: interior[0].subnodeVCN))
            for i in 0..<interior.count {
                tokens.append((kind: "key", key: interior[i].key, body: interior[i].body, fileRef: interior[i].fileRef, vcn: nil))
                if i + 1 < interior.count {
                    tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: interior[i + 1].subnodeVCN))
                } else {
                    tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: lastSubnodeVCN))
                }
            }
        }

        // Find the VCN token matching splitLeafVCN, and splice in the new median + newLeafVCN AFTER it.
        var spliced = false
        var newTokens: [(kind: String, key: String?, body: Data?, fileRef: UInt64?, vcn: UInt64?)] = []
        for t in tokens {
            newTokens.append(t)
            if !spliced, t.kind == "vcn", t.vcn == splitLeafVCN {
                newTokens.append((kind: "key", key: medianEntry.sortKey, body: medianEntry.body, fileRef: medianEntry.fileRef, vcn: nil))
                newTokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: newLeafVCN))
                spliced = true
            }
        }
        if !spliced {
            // v0.4 Phase 3(B): splitLeafVCN isn't a direct child of
            // $INDEX_ROOT — the tree is depth ≥ 3 after a prior height-
            // grow. Find the leaf's direct parent (an intermediate INDX
            // block) and promote the new (median, newLeafVCN) into THAT
            // block. If the intermediate fits, we just rewrite it; if
            // overflowing, the intermediate must split too (cascade up).
            return try await promoteThroughInteriorChain(
                parent: parent,
                attrs: attrs,
                indexRoot: indexRoot,
                rootInterior: interior,
                rootLastSubnodeVCN: lastSubnodeVCN,
                rootBytes: rootBytes,
                allocationExtents: allocationExtents,
                primaryNewExtent: newExtent,
                splitLeafVCN: splitLeafVCN,
                newLeafVCN: newLeafVCN,
                medianEntry: medianEntry
            )
        }

        // Re-collapse tokens back into interior entries + LAST sentinel.
        // Tokens after splice: [V, K, V, K, V, ..., K, V] (alternating starting and ending with V).
        // Interior entries take (V_i, K_{i+1}) for i in 0..<n-1; LAST sentinel takes final V.
        var newInterior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)] = []
        var idx = 0
        while idx + 2 < newTokens.count {
            // newTokens[idx] is VCN, newTokens[idx+1] is KEY, newTokens[idx+2] is VCN
            let leftVCN = newTokens[idx].vcn ?? 0
            let key = newTokens[idx + 1]
            newInterior.append((
                key: key.key ?? "",
                body: key.body ?? Data(),
                fileRef: key.fileRef ?? 0,
                subnodeVCN: leftVCN
            ))
            idx += 2
        }
        let newLastVCN = newTokens.last?.vcn ?? 0

        // 5b) Serialize the new $INDEX_ROOT body.
        let newRootBody = serializeLargeIndexRoot(
            indexAllocationBlockSize: indexRoot.indexAllocationBlockSize,
            clustersPerIndexBlock: indexRoot.clustersPerIndexBlock,
            interior: newInterior,
            lastSubnodeVCN: newLastVCN
        )

        // 5c) Compute the new $INDEX_ALLOCATION runlist (existing extents + newExtent).
        let updatedExtents = mergeAdjacentExtents(allocationExtents + [newExtent])
        let totalIndexAllocClusters = updatedExtents.reduce(0) { $0 + $1.clusterCount }
        let clusterBytes = UInt64(bytesPerCluster)
        let updatedIndexAllocAttrBytes = serializeIndexAllocationAttribute(
            attrID: try findIndexAllocationAttributeID(attrs: attrs),
            extents: updatedExtents,
            totalBytes: totalIndexAllocClusters * clusterBytes
        )

        // 5d) Update $BITMAP:$I30 — set the bit at index = newVCN / clustersPerBlock.
        let updatedBitmapAttrBytes = try updateBitmapAttribute(
            attrs: attrs,
            blockIndex: newLeafVCN  // since indexRecordSizeBytes == bytesPerCluster, VCN==block index
        )

        // 5e) Rebuild the parent MFT record with all three updates.
        //     If the new $INDEX_ROOT body (with the just-promoted median
        //     interior entry) no longer fits in the parent record's slack,
        //     `rewriteParentForLeafSplit` throws "would overflow parent
        //     record". In v0.3 this aborted the operation cleanly; in
        //     v0.4 Phase 3(A) we recover via $INDEX_ROOT height-grow.
        do {
            let newRecordBytes = try rewriteParentForLeafSplit(
                parent: parent,
                newRootBody: newRootBody,
                newIndexAllocAttrBytes: updatedIndexAllocAttrBytes,
                newBitmapAttrBytes: updatedBitmapAttrBytes
            )
            return ComputedSplit(
                parentRecordBytes: newRecordBytes,
                intermediates: [],
                extraClustersAllocated: []
            )
        } catch NTFSError.unsupportedFeature(let desc) where isOverflowDescription(desc) {
            // v0.5 Fix B Step 3: if the non-resident $INDEX_ALLOCATION
            // attribute overflowed the base record's slack — the runlist
            // grew past the cap at the ~350-file `cp -r` boundary —
            // migrate $INDEX_ALLOCATION:$I30 into a fresh extension
            // record (with a resident $ATTRIBUTE_LIST on the base) and
            // retry `rewriteParentForLeafSplit` against a freshly-read
            // parent. The migrated base now has slack for the larger
            // non-resident attribute.
            //
            // For $INDEX_ROOT (Step A) and $BITMAP (Step C) overflow,
            // fall through to the v0.4 height-grow path; $BITMAP-only
            // migration is deferred (see follow-up #11).
            let overflowType = overflowingAttributeType(from: desc)
            if overflowType == AttributeType.indexAllocation.rawValue {
                try await migrateIndexAllocationOnOverflow(
                    baseRecordNumber: parentRecordNumber,
                    overflowDescription: desc
                )
                // Re-read parent post-migration: the on-disk record now
                // has $ATTRIBUTE_LIST in place of $INDEX_ALLOCATION, so
                // the stale `parent` value would re-introduce the
                // migrant and undo the migration.
                let refreshedParent = try await mft.record(at: parentRecordNumber)
                let newRecordBytes = try rewriteParentForLeafSplit(
                    parent: refreshedParent,
                    newRootBody: newRootBody,
                    newIndexAllocAttrBytes: updatedIndexAllocAttrBytes,
                    newBitmapAttrBytes: updatedBitmapAttrBytes
                )
                return ComputedSplit(
                    parentRecordBytes: newRecordBytes,
                    intermediates: [],
                    extraClustersAllocated: []
                )
            }

            // v0.4 Phase 3(A): height-grow $INDEX_ROOT.
            //
            // Bisect newInterior into two halves around a new median; move
            // each half into a fresh interior INDX block; replace $INDEX_ROOT
            // with a tiny new root containing just (newMedian → leftInter)
            // + LAST → rightInter. New cap: ~3-6k files/dir, up from ~60.
            return try await heightGrowIndexRoot(
                parent: parent,
                attrs: attrs,
                indexRoot: indexRoot,
                newInterior: newInterior,
                newLastVCN: newLastVCN,
                allocationExtents: allocationExtents,
                primaryNewExtent: newExtent,
                newLeafVCN: newLeafVCN
            )
        }
    }

    /// v0.4 Phase 3(A): height-grow $INDEX_ROOT into a 2-level interior tree.
    ///
    /// Allocates 2 new clusters for left/right intermediate interior INDX
    /// blocks, bisects `newInterior` around its midpoint, and replaces the
    /// parent's $INDEX_ROOT with a tiny new root: 1 interior entry pointing
    /// at the left intermediate + LAST sentinel pointing at the right.
    ///
    /// Returns a `ComputedSplit` carrying:
    /// - new parent record bytes (much smaller $INDEX_ROOT now fits cleanly)
    /// - the 2 intermediate blocks (caller writes BEFORE the parent record)
    /// - the 2 extra cluster extents (caller frees on commit failure)
    ///
    /// Cluster allocations happen here; on any thrown error the caller's
    /// outer rollback frees them along with the primary leaf extent.
    private func heightGrowIndexRoot(
        parent: MFTRecord,
        attrs: [Attribute],
        indexRoot: IndexRoot,
        newInterior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)],
        newLastVCN: UInt64,
        allocationExtents: [Extent],
        primaryNewExtent: Extent,
        newLeafVCN: UInt64,
        // v0.4 Phase 3(D): additional context for cascade-driven height-grow.
        // These represent state ALREADY accumulated by an in-flight cascade
        // (interior splits up the chain that ran before reaching root). The
        // simple direct-from-leaf height-grow path leaves them empty.
        cascadeAccumulatedExtents: [Extent] = [],
        cascadeBitmapVCNs: [UInt64] = []
    ) async throws -> ComputedSplit {
        guard newInterior.count >= 2 else {
            // Height-grow can't help — $INDEX_ROOT has only 0 or 1 interior
            // entries. The overflow must be a different cause (e.g., other
            // attributes consuming the record). Re-throw the original error.
            throw NTFSError.unsupportedFeature(
                description: "heightGrowIndexRoot: too few interior entries (\(newInterior.count)) to bisect — parent record overflow is not caused by $INDEX_ROOT growth"
            )
        }

        let medianIdx = newInterior.count / 2
        let medianEntry = newInterior[medianIdx]
        let leftEntries = Array(newInterior[0..<medianIdx])
        let rightEntries = Array(newInterior[(medianIdx + 1)..<newInterior.count])
        // The left intermediate's LAST sentinel points at where the median's
        // subnode used to live (subtree to the LEFT of the median key).
        let leftIntermediateLastVCN = medianEntry.subnodeVCN
        // The right intermediate's LAST sentinel inherits the original
        // $INDEX_ROOT's LAST → newLastVCN target.
        let rightIntermediateLastVCN = newLastVCN

        // Allocate 2 new clusters. The primary leaf extent is independent;
        // it's already in `primaryNewExtent`. Track our extra allocations
        // so the caller can free them on commit failure.
        let leftInterExtent = try await allocateClusters(1)
        let rightInterExtent: Extent
        do {
            rightInterExtent = try await allocateClusters(1)
        } catch {
            try? await freeClusters(leftInterExtent)
            throw error
        }
        var extraClusters = [leftInterExtent, rightInterExtent]

        guard let leftInterLCN = leftInterExtent.startLCN,
              let rightInterLCN = rightInterExtent.startLCN else {
            for ext in extraClusters { try? await freeClusters(ext) }
            throw NTFSError.corruptOnDisk(description: "heightGrowIndexRoot: allocator returned sparse extent")
        }

        let clusterBytes = UInt64(bytesPerCluster)
        // The new VCNs for the intermediates: they extend the existing
        // $INDEX_ALLOCATION runlist. Account for the primary leaf extent
        // AND any cascade-accumulated extents that already extended the
        // runlist (Phase 3(D) re-entry).
        let existingVCNCount = allocationExtents.reduce(0) { $0 + $1.clusterCount }
        let primaryClusters = primaryNewExtent.clusterCount
        let cascadeClusters = cascadeAccumulatedExtents.reduce(0) { $0 + $1.clusterCount }
        let leftInterVCN = existingVCNCount + primaryClusters + cascadeClusters
        let rightInterVCN = leftInterVCN + 1

        // Build the two intermediate interior INDX blocks (in memory).
        let blockSize = Int(indexRecordSizeBytes)
        let sectorSize = Int(boot.bytesPerSector)
        do {
            let leftBlock = try buildInteriorIndxBlock(
                blockSize: blockSize,
                sectorSize: sectorSize,
                vcn: leftInterVCN,
                interior: leftEntries,
                lastSubnodeVCN: leftIntermediateLastVCN
            )
            let leftOnDisk = try UpdateSequenceArray.reverseFixup(
                recordBytes: leftBlock,
                usaOffset: Int(try leftBlock.readU16LE(at: 4)),
                usaCount: Int(try leftBlock.readU16LE(at: 6)),
                blockSize: sectorSize
            )
            let rightBlock = try buildInteriorIndxBlock(
                blockSize: blockSize,
                sectorSize: sectorSize,
                vcn: rightInterVCN,
                interior: rightEntries,
                lastSubnodeVCN: rightIntermediateLastVCN
            )
            let rightOnDisk = try UpdateSequenceArray.reverseFixup(
                recordBytes: rightBlock,
                usaOffset: Int(try rightBlock.readU16LE(at: 4)),
                usaCount: Int(try rightBlock.readU16LE(at: 6)),
                blockSize: sectorSize
            )

            // Build the NEW tiny $INDEX_ROOT body: 1 interior entry +
            // LAST sentinel.
            let newRootInterior = [(
                key: medianEntry.key,
                body: medianEntry.body,
                fileRef: medianEntry.fileRef,
                subnodeVCN: leftInterVCN
            )]
            let newTinyRootBody = serializeLargeIndexRoot(
                indexAllocationBlockSize: indexRoot.indexAllocationBlockSize,
                clustersPerIndexBlock: indexRoot.clustersPerIndexBlock,
                interior: newRootInterior,
                lastSubnodeVCN: rightInterVCN
            )

            // Updated $INDEX_ALLOCATION runlist: existing + primary leaf
            // extent + cascade-accumulated extents + left/right new
            // intermediate extents (in that VCN order).
            var allExtentsForRunlist: [Extent] = allocationExtents
            allExtentsForRunlist.append(primaryNewExtent)
            allExtentsForRunlist.append(contentsOf: cascadeAccumulatedExtents)
            allExtentsForRunlist.append(leftInterExtent)
            allExtentsForRunlist.append(rightInterExtent)
            let updatedExtents = mergeAdjacentExtents(allExtentsForRunlist)
            let totalIndexAllocClusters = updatedExtents.reduce(0) { $0 + $1.clusterCount }
            let updatedIndexAllocAttrBytes = serializeIndexAllocationAttribute(
                attrID: try findIndexAllocationAttributeID(attrs: attrs),
                extents: updatedExtents,
                totalBytes: totalIndexAllocClusters * clusterBytes
            )

            // Updated $BITMAP: cascade's already-set bits + the 2 new
            // intermediates. (newLeafVCN may already be in cascadeBitmapVCNs;
            // updateBitmapAttribute is idempotent on duplicates.)
            var allBitmapVCNs: [UInt64] = []
            if cascadeBitmapVCNs.isEmpty {
                allBitmapVCNs = [newLeafVCN]
            } else {
                allBitmapVCNs = cascadeBitmapVCNs
            }
            allBitmapVCNs.append(leftInterVCN)
            allBitmapVCNs.append(rightInterVCN)
            let updatedBitmapAttrBytes = try updateBitmapAttribute(
                attrs: attrs,
                blockIndices: allBitmapVCNs
            )

            // Build the parent record bytes — should now fit (tiny root).
            let newRecordBytes = try rewriteParentForLeafSplit(
                parent: parent,
                newRootBody: newTinyRootBody,
                newIndexAllocAttrBytes: updatedIndexAllocAttrBytes,
                newBitmapAttrBytes: updatedBitmapAttrBytes
            )

            return ComputedSplit(
                parentRecordBytes: newRecordBytes,
                intermediates: [
                    (byteOffset: leftInterLCN * clusterBytes, postFixupBytes: leftOnDisk),
                    (byteOffset: rightInterLCN * clusterBytes, postFixupBytes: rightOnDisk)
                ],
                extraClustersAllocated: extraClusters
            )
        } catch {
            // Any build/serialize failure → free both intermediates + rethrow.
            for ext in extraClusters { try? await freeClusters(ext) }
            extraClusters.removeAll()
            throw error
        }
    }

    /// v0.4 Phase 3(B): in-memory snapshot of an intermediate (non-root)
    /// interior INDX block. Built by `findInteriorParentChainForLeaf`.
    private struct InteriorBlockInfo {
        let blockVCN: UInt64
        let byteOffset: UInt64
        /// USA-applied source bytes — caller needs the headers when
        /// rebuilding the block.
        let blockBytesFixedUp: Data
        let blockSize: Int
        let sectorSize: Int
        let entriesOffsetWithinHeader: Int
        let allocatedSizeWithinHeader: Int
        /// Non-LAST interior entries in this block.
        let interior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)]
        /// LAST sentinel's subnode VCN.
        let lastSubnodeVCN: UInt64
    }

    /// v0.4 Phase 3(B): walk the tree from $INDEX_ROOT's pointers down to
    /// find the chain of interior INDX blocks leading to the leaf at
    /// `leafVCN`. Returns the chain root-first (chain[0] is the first
    /// intermediate visited from $INDEX_ROOT; chain[last] is the leaf's
    /// direct parent).
    ///
    /// Uses key-based descent (same selector as `IndexAllocationWriter.
    /// pickSubnode`). `searchKey` is any key that resides in the leaf —
    /// in practice we pass the first entry of the merged sorted list.
    /// Reaching the target leaf at the end of descent confirms we found
    /// the right path; mismatch means the tree state diverged from
    /// expectations and we abort with a clear error.
    private func findInteriorParentChainForLeaf(
        rootInterior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)],
        rootLastSubnodeVCN: UInt64,
        allocationExtents: [Extent],
        searchKey: String,
        leafVCN: UInt64
    ) async throws -> [InteriorBlockInfo] {
        let blockSize = Int(indexRecordSizeBytes)
        let sectorSize = Int(boot.bytesPerSector)
        let clusterBytes = UInt64(bytesPerCluster)

        // Step 1: pick the $INDEX_ROOT subnode to descend into.
        var currentVCN: UInt64 = rootLastSubnodeVCN
        for entry in rootInterior {
            if !IndexBuilder.collationFilenameSortsBefore(entry.key, searchKey) {
                currentVCN = entry.subnodeVCN
                break
            }
        }

        var chain: [InteriorBlockInfo] = []
        var visited: Set<UInt64> = []

        while true {
            if visited.contains(currentVCN) {
                throw NTFSError.corruptOnDisk(
                    description: "findInteriorParentChainForLeaf: cycle detected at VCN \(currentVCN)"
                )
            }
            visited.insert(currentVCN)

            let byteOffset = try vcnToByteOffsetInAllocation(
                vcn: currentVCN,
                extents: allocationExtents,
                clusterBytes: clusterBytes
            )
            let raw = try await device.read(offset: byteOffset, length: blockSize)
            let usaOffset = Int(try raw.readU16LE(at: 4))
            let usaCount = Int(try raw.readU16LE(at: 6))
            let fixed = try UpdateSequenceArray.applyFixup(
                recordBytes: raw,
                usaOffset: usaOffset,
                usaCount: usaCount,
                blockSize: sectorSize
            )

            // INDEX_HEADER at offset 24 in the block.
            let entriesOffsetWithinHeader = Int(try fixed.readU32LE(at: 24))
            let usedSizeWithinHeader = Int(try fixed.readU32LE(at: 28))
            let allocatedSizeWithinHeader = Int(try fixed.readU32LE(at: 32))

            let entriesStart = 24 + entriesOffsetWithinHeader
            let entriesEnd = 24 + usedSizeWithinHeader
            let parsed = try parseRootInteriorEntries(in: fixed, start: entriesStart, limit: entriesEnd)

            // Decompose entries into [(non-LAST)] + LAST.subnodeVCN.
            var interior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)] = []
            var lastSub: UInt64 = 0
            for e in parsed {
                if e.isLast {
                    lastSub = e.subnodeVCN ?? 0
                } else if let key = e.keyName, e.hasSubnode {
                    interior.append((key: key, body: e.keyBytes, fileRef: e.fileReference, subnodeVCN: e.subnodeVCN ?? 0))
                }
            }

            // Is this an INTERIOR block (has subnodes) or a LEAF (no subnodes)?
            // Interior iff at least one entry — including LAST — has a subnode.
            let hasAnySubnode = !interior.isEmpty || parsed.contains(where: { $0.isLast && $0.hasSubnode })

            // Check whether THIS block's pointer set contains leafVCN.
            // If so, this block IS the leaf's direct parent — append to
            // chain and return.
            let pointsAtLeaf = interior.contains(where: { $0.subnodeVCN == leafVCN }) || lastSub == leafVCN
            if pointsAtLeaf {
                chain.append(InteriorBlockInfo(
                    blockVCN: currentVCN,
                    byteOffset: byteOffset,
                    blockBytesFixedUp: fixed,
                    blockSize: blockSize,
                    sectorSize: sectorSize,
                    entriesOffsetWithinHeader: entriesOffsetWithinHeader,
                    allocatedSizeWithinHeader: allocatedSizeWithinHeader,
                    interior: interior,
                    lastSubnodeVCN: lastSub
                ))
                return chain
            }

            // Not the direct parent — must be an interior block whose
            // subnodes are themselves interior. Record + descend.
            guard hasAnySubnode else {
                // This is a leaf (no subnodes) but it's not leafVCN — the
                // descent didn't reach the target. Tree state diverged.
                throw NTFSError.corruptOnDisk(
                    description: "findInteriorParentChainForLeaf: descent landed at leaf VCN \(currentVCN), not target \(leafVCN)"
                )
            }

            chain.append(InteriorBlockInfo(
                blockVCN: currentVCN,
                byteOffset: byteOffset,
                blockBytesFixedUp: fixed,
                blockSize: blockSize,
                sectorSize: sectorSize,
                entriesOffsetWithinHeader: entriesOffsetWithinHeader,
                allocatedSizeWithinHeader: allocatedSizeWithinHeader,
                interior: interior,
                lastSubnodeVCN: lastSub
            ))

            // Pick next subnode using key-based descent.
            var nextVCN: UInt64 = lastSub
            for entry in interior {
                if !IndexBuilder.collationFilenameSortsBefore(entry.key, searchKey) {
                    nextVCN = entry.subnodeVCN
                    break
                }
            }
            currentVCN = nextVCN
        }
    }

    /// VCN→byte offset using the directory's $INDEX_ALLOCATION runlist.
    private func vcnToByteOffsetInAllocation(vcn: UInt64, extents: [Extent], clusterBytes: UInt64) throws -> UInt64 {
        var cumulative: UInt64 = 0
        for extent in extents {
            if vcn < cumulative + extent.clusterCount {
                let clusterInExtent = vcn - cumulative
                guard let startLCN = extent.startLCN else {
                    throw NTFSError.corruptOnDisk(description: "vcnToByteOffsetInAllocation: sparse extent at VCN \(vcn)")
                }
                return (startLCN + clusterInExtent) * clusterBytes
            }
            cumulative += extent.clusterCount
        }
        throw NTFSError.corruptOnDisk(description: "vcnToByteOffsetInAllocation: VCN \(vcn) beyond runlist (total \(cumulative))")
    }

    /// v0.4 Phase 3(B) + 3(C): promote (newKey, newRightSubnodeVCN) through
    /// the chain of intermediate INDX blocks from leaf's direct parent up
    /// toward `$INDEX_ROOT`, splitting any intermediate that overflows and
    /// cascading the new median up to the next level. If the cascade
    /// reaches `$INDEX_ROOT`, the existing root-update path takes over
    /// (with Phase 3(A) height-grow as the final fallback).
    ///
    /// Algorithm (iterative, leaf-side-first):
    /// 1. At each level (chain[i], from leaf up to root):
    ///    a. Splice the pending (key, rightVCN) into the level's interior
    ///       entries after the existing leftSubnode pointer.
    ///    b. Try to build the new interior block. Fits → rewrite this
    ///       intermediate in place; cascade stops here.
    ///    c. Overflow → bisect the spliced entries, allocate 1 new
    ///       cluster for the right half. Write left half (overwriting
    ///       this intermediate's original location) + right half (new
    ///       cluster). Promote the bisection median up to the next level.
    /// 2. If the loop exhausts the chain, the bisection median needs to
    ///    go into `$INDEX_ROOT`. We invoke the existing root-update path
    ///    via `computeRootUpdateAfterCascade`, which itself can
    ///    height-grow if `$INDEX_ROOT` is full.
    ///
    /// Tracks all allocated extents in `extraClustersAllocated` so the
    /// caller's outer rollback frees them on any failure between compute
    /// and parent-record commit.
    private func promoteThroughInteriorChain(
        parent: MFTRecord,
        attrs: [Attribute],
        indexRoot: IndexRoot,
        rootInterior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)],
        rootLastSubnodeVCN: UInt64,
        rootBytes: Data,
        allocationExtents: [Extent],
        primaryNewExtent: Extent,
        splitLeafVCN: UInt64,
        newLeafVCN: UInt64,
        medianEntry: (fileRef: UInt64, body: Data, sortKey: String)
    ) async throws -> ComputedSplit {
        // Walk tree to find leaf's direct parent + its ancestor intermediates.
        let chain = try await findInteriorParentChainForLeaf(
            rootInterior: rootInterior,
            rootLastSubnodeVCN: rootLastSubnodeVCN,
            allocationExtents: allocationExtents,
            searchKey: medianEntry.sortKey,
            leafVCN: splitLeafVCN
        )
        guard !chain.isEmpty else {
            throw NTFSError.corruptOnDisk(
                description: "promoteThroughInteriorChain: empty chain for leafVCN \(splitLeafVCN)"
            )
        }

        let clusterBytes = UInt64(bytesPerCluster)
        // Existing $INDEX_ALLOCATION total VCNs, BEFORE primaryNewExtent.
        // Each new cluster we allocate during cascade gets the next VCN.
        let existingVCNCount = allocationExtents.reduce(0) { $0 + $1.clusterCount }
        var nextNewVCN = existingVCNCount + primaryNewExtent.clusterCount  // VCN of next new cluster

        var pendingKey = medianEntry.sortKey
        var pendingBody = medianEntry.body
        var pendingFileRef = medianEntry.fileRef
        var pendingRightVCN = newLeafVCN
        var existingLeftSubnodeVCN = splitLeafVCN

        var intermediateWrites: [(byteOffset: UInt64, postFixupBytes: Data)] = []
        var extraExtents: [Extent] = []
        var newVCNsForBitmap: [UInt64] = [newLeafVCN]

        var cascadeExhaustedChain = false

        // Walk chain from leaf-side (chain.last) up to root-side (chain.first).
        for level in chain.reversed() {
            let splice = try spliceInteriorEntries(
                interior: level.interior,
                lastSubnodeVCN: level.lastSubnodeVCN,
                afterSubnode: existingLeftSubnodeVCN,
                newKey: pendingKey,
                newKeyBody: pendingBody,
                newKeyFileRef: pendingFileRef,
                newRightSubnode: pendingRightVCN
            )

            // Attempt fits-in-place build.
            do {
                let newBlock = try buildInteriorIndxBlock(
                    blockSize: level.blockSize,
                    sectorSize: level.sectorSize,
                    vcn: level.blockVCN,
                    interior: splice.newInterior,
                    lastSubnodeVCN: splice.newLastVCN
                )
                let onDisk = try UpdateSequenceArray.reverseFixup(
                    recordBytes: newBlock,
                    usaOffset: Int(try newBlock.readU16LE(at: 4)),
                    usaCount: Int(try newBlock.readU16LE(at: 6)),
                    blockSize: level.sectorSize
                )
                intermediateWrites.append((byteOffset: level.byteOffset, postFixupBytes: onDisk))
                // Cascade stops here.
                cascadeExhaustedChain = false
                break
            } catch NTFSError.unsupportedFeature(let desc) where desc.contains("overflow block") {
                // This intermediate is full. Split it: bisect spliced
                // entries around midpoint, allocate cluster for right
                // half.
                let mid = splice.newInterior.count / 2
                guard splice.newInterior.count >= 2 else {
                    // Single-entry intermediate that can't even fit one
                    // more — pathological tree shape. Roll back all
                    // pending allocations and surface.
                    for ext in extraExtents { try? await freeClusters(ext) }
                    throw NTFSError.corruptOnDisk(
                        description: "promoteThroughInteriorChain: intermediate at VCN \(level.blockVCN) reports overflow with only \(splice.newInterior.count) entries — \(desc)"
                    )
                }
                let medianInter = splice.newInterior[mid]
                let leftHalf = Array(splice.newInterior[0..<mid])
                let rightHalf = Array(splice.newInterior[(mid + 1)..<splice.newInterior.count])

                // Allocate cluster for right half.
                let rightExtent: Extent
                do {
                    rightExtent = try await allocateClusters(1)
                } catch {
                    for ext in extraExtents { try? await freeClusters(ext) }
                    throw error
                }
                guard let rightLCN = rightExtent.startLCN else {
                    for ext in extraExtents { try? await freeClusters(ext) }
                    try? await freeClusters(rightExtent)
                    throw NTFSError.corruptOnDisk(description: "promoteThroughInteriorChain: allocator returned sparse extent")
                }
                extraExtents.append(rightExtent)
                let rightVCN = nextNewVCN
                nextNewVCN += 1
                newVCNsForBitmap.append(rightVCN)

                // Build LEFT half (overwrites the original block at level.blockVCN).
                let leftBlock = try buildInteriorIndxBlock(
                    blockSize: level.blockSize,
                    sectorSize: level.sectorSize,
                    vcn: level.blockVCN,
                    interior: leftHalf,
                    lastSubnodeVCN: medianInter.subnodeVCN
                )
                let leftOnDisk = try UpdateSequenceArray.reverseFixup(
                    recordBytes: leftBlock,
                    usaOffset: Int(try leftBlock.readU16LE(at: 4)),
                    usaCount: Int(try leftBlock.readU16LE(at: 6)),
                    blockSize: level.sectorSize
                )
                intermediateWrites.append((byteOffset: level.byteOffset, postFixupBytes: leftOnDisk))

                // Build RIGHT half (new cluster).
                let rightBlock = try buildInteriorIndxBlock(
                    blockSize: level.blockSize,
                    sectorSize: level.sectorSize,
                    vcn: rightVCN,
                    interior: rightHalf,
                    lastSubnodeVCN: splice.newLastVCN
                )
                let rightOnDisk = try UpdateSequenceArray.reverseFixup(
                    recordBytes: rightBlock,
                    usaOffset: Int(try rightBlock.readU16LE(at: 4)),
                    usaCount: Int(try rightBlock.readU16LE(at: 6)),
                    blockSize: level.sectorSize
                )
                intermediateWrites.append((byteOffset: rightLCN * clusterBytes, postFixupBytes: rightOnDisk))

                // Setup for next iteration: the bisection median must be
                // promoted to the LEVEL ABOVE this one. The "existing
                // left subnode" up there is this level's blockVCN
                // (which now points at the LEFT half) — Phase 3(B)'s
                // spliceInteriorEntries(afterSubnode: ...) will find it
                // and splice in (newKey, rightVCN) right after.
                pendingKey = medianInter.key
                pendingBody = medianInter.body
                pendingFileRef = medianInter.fileRef
                pendingRightVCN = rightVCN
                existingLeftSubnodeVCN = level.blockVCN
                cascadeExhaustedChain = true  // continues unless next iter breaks
            }
        }

        // Build updated $INDEX_ALLOCATION runlist (existing + primary leaf +
        // any new cluster extents from interior splits).
        let updatedExtents = mergeAdjacentExtents(allocationExtents + [primaryNewExtent] + extraExtents)
        let totalIndexAllocClusters = updatedExtents.reduce(0) { $0 + $1.clusterCount }
        let updatedIndexAllocAttrBytes = serializeIndexAllocationAttribute(
            attrID: try findIndexAllocationAttributeID(attrs: attrs),
            extents: updatedExtents,
            totalBytes: totalIndexAllocClusters * clusterBytes
        )
        let updatedBitmapAttrBytes = try updateBitmapAttribute(
            attrs: attrs,
            blockIndices: newVCNsForBitmap
        )

        if !cascadeExhaustedChain {
            // Cascade stopped at some intermediate level. $INDEX_ROOT body
            // is UNCHANGED. Just rewrite parent record with updated
            // runlist + bitmap.
            let newRecordBytes = try rewriteParentForLeafSplit(
                parent: parent,
                newRootBody: rootBytes,  // unchanged
                newIndexAllocAttrBytes: updatedIndexAllocAttrBytes,
                newBitmapAttrBytes: updatedBitmapAttrBytes
            )
            return ComputedSplit(
                parentRecordBytes: newRecordBytes,
                intermediates: intermediateWrites,
                extraClustersAllocated: extraExtents
            )
        }

        // Phase 3(C) cascade exhausted the chain. The pending median needs
        // to land in $INDEX_ROOT. Splice into the root's interior + LAST
        // sentinel; if root overflows, height-grow.
        let rootSplice = try spliceInteriorEntries(
            interior: rootInterior,
            lastSubnodeVCN: rootLastSubnodeVCN,
            afterSubnode: existingLeftSubnodeVCN,
            newKey: pendingKey,
            newKeyBody: pendingBody,
            newKeyFileRef: pendingFileRef,
            newRightSubnode: pendingRightVCN
        )
        let newRootBody = serializeLargeIndexRoot(
            indexAllocationBlockSize: indexRoot.indexAllocationBlockSize,
            clustersPerIndexBlock: indexRoot.clustersPerIndexBlock,
            interior: rootSplice.newInterior,
            lastSubnodeVCN: rootSplice.newLastVCN
        )

        do {
            let newRecordBytes = try rewriteParentForLeafSplit(
                parent: parent,
                newRootBody: newRootBody,
                newIndexAllocAttrBytes: updatedIndexAllocAttrBytes,
                newBitmapAttrBytes: updatedBitmapAttrBytes
            )
            return ComputedSplit(
                parentRecordBytes: newRecordBytes,
                intermediates: intermediateWrites,
                extraClustersAllocated: extraExtents
            )
        } catch NTFSError.unsupportedFeature(let desc) where isOverflowDescription(desc) {
            // v0.5 Fix B Step 3: if the non-resident
            // $INDEX_ALLOCATION is what overflowed the base record
            // (not $INDEX_ROOT, not $BITMAP), migrate the
            // $INDEX_ALLOCATION:$I30 attribute into an extension
            // record + resident $ATTRIBUTE_LIST and retry against a
            // freshly-read parent. The migrated base now has slack to
            // accept the grown non-resident attribute. $BITMAP-only
            // migration is deferred — fall through to v0.4 height-grow.
            let overflowType = overflowingAttributeType(from: desc)
            if overflowType == AttributeType.indexAllocation.rawValue {
                let baseRN = UInt64(parent.mftRecordNumber)
                try await migrateIndexAllocationOnOverflow(
                    baseRecordNumber: baseRN,
                    overflowDescription: desc
                )
                let refreshedParent = try await self.mft().record(at: baseRN)
                let newRecordBytes = try rewriteParentForLeafSplit(
                    parent: refreshedParent,
                    newRootBody: newRootBody,
                    newIndexAllocAttrBytes: updatedIndexAllocAttrBytes,
                    newBitmapAttrBytes: updatedBitmapAttrBytes
                )
                return ComputedSplit(
                    parentRecordBytes: newRecordBytes,
                    intermediates: intermediateWrites,
                    extraClustersAllocated: extraExtents
                )
            }

            // v0.4 Phase 3(D): cascade reached $INDEX_ROOT AND root would
            // also overflow with the cascade's bubbled-up median. Apply
            // height-grow ON TOP of the cascade's accumulated state.
            // heightGrowIndexRoot allocates 2 more clusters, splits the
            // post-splice root entries into intermediates, and replaces
            // $INDEX_ROOT with a tiny new root. All cascade extents and
            // bitmap VCNs are passed through so the merged runlist +
            // bitmap reflect the full picture.
            let grown = try await heightGrowIndexRoot(
                parent: parent,
                attrs: attrs,
                indexRoot: indexRoot,
                newInterior: rootSplice.newInterior,
                newLastVCN: rootSplice.newLastVCN,
                allocationExtents: allocationExtents,
                primaryNewExtent: primaryNewExtent,
                newLeafVCN: newLeafVCN,
                cascadeAccumulatedExtents: extraExtents,
                cascadeBitmapVCNs: newVCNsForBitmap
            )
            // Merge cascade intermediates + height-grow intermediates.
            // Order matters for write sequencing — both arrays are
            // already in "write these in order before parent" form.
            var combined = intermediateWrites
            combined.append(contentsOf: grown.intermediates)
            return ComputedSplit(
                parentRecordBytes: grown.parentRecordBytes,
                intermediates: combined,
                extraClustersAllocated: extraExtents + grown.extraClustersAllocated
            )
        }
    }

    /// v0.4 Phase 3(B): splice (newKey, newRightSubnodeVCN) into an
    /// interior-entry list just AFTER the pointer at `existingChildVCN`.
    /// Returns the new entry list + new LAST subnode VCN. Used by both
    /// the $INDEX_ROOT update path AND the intermediate-INDX-block
    /// rewrite path.
    private struct InteriorEntriesSplice {
        let newInterior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)]
        let newLastVCN: UInt64
    }

    private func spliceInteriorEntries(
        interior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)],
        lastSubnodeVCN: UInt64,
        afterSubnode existingChildVCN: UInt64,
        newKey: String,
        newKeyBody: Data,
        newKeyFileRef: UInt64,
        newRightSubnode: UInt64
    ) throws -> InteriorEntriesSplice {
        // Model as token list: [V_0, K_1, V_1, K_2, V_2, ..., K_n, V_n].
        var tokens: [(kind: String, key: String?, body: Data?, fileRef: UInt64?, vcn: UInt64?)] = []
        if interior.isEmpty {
            tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: lastSubnodeVCN))
        } else {
            tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: interior[0].subnodeVCN))
            for i in 0..<interior.count {
                tokens.append((kind: "key", key: interior[i].key, body: interior[i].body, fileRef: interior[i].fileRef, vcn: nil))
                if i + 1 < interior.count {
                    tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: interior[i + 1].subnodeVCN))
                } else {
                    tokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: lastSubnodeVCN))
                }
            }
        }

        // Splice in (newKey, newRightSubnode) AFTER the VCN token matching existingChildVCN.
        var spliced = false
        var newTokens: [(kind: String, key: String?, body: Data?, fileRef: UInt64?, vcn: UInt64?)] = []
        for t in tokens {
            newTokens.append(t)
            if !spliced, t.kind == "vcn", t.vcn == existingChildVCN {
                newTokens.append((kind: "key", key: newKey, body: newKeyBody, fileRef: newKeyFileRef, vcn: nil))
                newTokens.append((kind: "vcn", key: nil, body: nil, fileRef: nil, vcn: newRightSubnode))
                spliced = true
            }
        }
        guard spliced else {
            throw NTFSError.corruptOnDisk(
                description: "spliceInteriorEntries: existingChildVCN \(existingChildVCN) not found among interior pointers"
            )
        }

        // Re-collapse tokens into interior entries + LAST.
        var newInterior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)] = []
        var idx = 0
        while idx + 2 < newTokens.count {
            let leftVCN = newTokens[idx].vcn ?? 0
            let key = newTokens[idx + 1]
            newInterior.append((
                key: key.key ?? "",
                body: key.body ?? Data(),
                fileRef: key.fileRef ?? 0,
                subnodeVCN: leftVCN
            ))
            idx += 2
        }
        let newLastVCN = newTokens.last?.vcn ?? 0

        return InteriorEntriesSplice(newInterior: newInterior, newLastVCN: newLastVCN)
    }

    /// Walk the entire LARGE_INDEX tree of `parentRecordNumber` and return
    /// the set of distinct fileReferences visible. Used as a post-split
    /// self-check.
    private func collectAllFileRefsInLargeIndex(parentRecordNumber: UInt64) async throws -> Set<UInt64> {
        let attrs = try await allAttributesOf(recordNumber: parentRecordNumber)
        guard let irAttr = attrs.first(where: { $0.type == .indexRoot && $0.nameOrEmpty == "$I30" }),
              case let .resident(rootBytes, _) = irAttr.value else {
            return []
        }
        let root = try IndexRoot.parse(rootBytes)
        var refs: Set<UInt64> = []
        // Collect from $INDEX_ROOT entries (interior + leaf-style).
        for e in root.entries where !e.isLast {
            refs.insert(e.fileReference)
        }
        // Collect from $INDEX_ALLOCATION leaves if LARGE_INDEX.
        if root.isLargeIndex,
           let allocAttr = attrs.first(where: { $0.type == .indexAllocation && $0.nameOrEmpty == "$I30" }),
           case let .nonResident(_, _, _, _, _, _, _, extents) = allocAttr.value {
            let clusterBytes = UInt64(bytesPerCluster)
            let blockSize = Int(indexRecordSizeBytes)
            let sectorSize = Int(boot.bytesPerSector)
            let clustersPerBlock = max(UInt64(1), UInt64(blockSize) / clusterBytes)
            for extent in extents {
                guard let startLCN = extent.startLCN else { continue }
                var cluster: UInt64 = 0
                while cluster < extent.clusterCount {
                    let lcn = startLCN + cluster
                    let raw = try await device.read(offset: lcn * clusterBytes, length: blockSize)
                    let block = try IndexAllocationBlock.parse(raw, sectorSize: sectorSize)
                    for e in block.entries where !e.isLast {
                        refs.insert(e.fileReference)
                    }
                    cluster += clustersPerBlock
                }
            }
        }
        return refs
    }

    /// Re-read + re-parse an MFT record + walk every attribute. Throws with
    /// detail if any of: USA fix-up rejects the bytes, the attribute chain is
    /// malformed, the end marker is missing, or expected attributes (e.g.
    /// $INDEX_ROOT:$I30 for directories) can't be re-parsed.
    ///
    /// Used as a self-check after each complex parent-record rewrite path
    /// (split, promote). If a future write corrupts the record, we want to
    /// fail at the corrupt site, not later when something tries to read it.
    private func verifyParentRecord(_ recordNumber: UInt64, context: String) async throws {
        let mft = self.mft()
        let rec: MFTRecord
        do {
            rec = try await mft.record(at: recordNumber)
        } catch {
            throw NTFSError.corruptOnDisk(
                description: "verifyParentRecord(\(recordNumber), \(context)): re-read failed: \(error)"
            )
        }
        let attrs: [Attribute]
        do {
            // $ATTRIBUTE_LIST-aware: once Fix B Step 3 migrates $INDEX_ALLOCATION
            // into an extension record, the verifier must follow the same path
            // every reader does. The base-only `rec.attributes()` would miss
            // the migrated attribute and the LARGE_INDEX assertion below
            // would false-positive on a well-formed migrated record.
            attrs = try await allAttributesOf(recordNumber: recordNumber)
        } catch {
            throw NTFSError.corruptOnDisk(
                description: "verifyParentRecord(\(recordNumber), \(context)): attribute iteration failed: \(error)"
            )
        }
        // For LARGE_INDEX directories we expect $INDEX_ROOT, $INDEX_ALLOCATION, $BITMAP.
        if rec.isDirectory {
            guard let irAttr = attrs.first(where: { $0.type == .indexRoot && $0.nameOrEmpty == "$I30" }),
                  case let .resident(rootBytes, _) = irAttr.value else {
                throw NTFSError.corruptOnDisk(
                    description: "verifyParentRecord(\(recordNumber), \(context)): missing or non-resident $INDEX_ROOT:$I30"
                )
            }
            do {
                _ = try IndexRoot.parse(rootBytes)
            } catch {
                throw NTFSError.corruptOnDisk(
                    description: "verifyParentRecord(\(recordNumber), \(context)): $INDEX_ROOT body failed to parse: \(error)"
                )
            }
        }
        // Each attribute's resident value or non-resident extents already
        // parsed cleanly by the iterator; if anything was wrong it threw above.
    }

    /// Parse $INDEX_ROOT entries including the LAST sentinel (which carries
    /// the rightmost-subtree pointer when LARGE_INDEX). The shared
    /// IndexEntryParser drops LAST so we re-walk raw bytes here.
    private struct _InteriorEntry {
        let fileReference: UInt64
        let entryLength: Int
        let keyLength: Int
        let flags: UInt16
        let keyBytes: Data
        let keyName: String?
        let subnodeVCN: UInt64?
        var isLast: Bool { (flags & 0x02) != 0 }
        var hasSubnode: Bool { (flags & 0x01) != 0 }
    }

    private func parseRootInteriorEntries(in data: Data, start: Int, limit: Int) throws -> [_InteriorEntry] {
        var entries: [_InteriorEntry] = []
        var pos = start
        let end = min(limit, data.count)
        while pos + 16 <= end {
            let fileRef = try data.readU64LE(at: pos + 0)
            let entryLength = Int(try data.readU16LE(at: pos + 8))
            let keyLength = Int(try data.readU16LE(at: pos + 10))
            let flags = try data.readU16LE(at: pos + 12)
            guard entryLength >= 16, pos + entryLength <= end else {
                throw NTFSError.corruptOnDisk(description: "$INDEX_ROOT entry malformed at \(pos)")
            }
            let isLast = (flags & 0x02) != 0
            let hasSubnode = (flags & 0x01) != 0
            var keyBytes = Data()
            var keyName: String?
            if !isLast, keyLength > 0 {
                let keyStart = pos + 16
                let keyEnd = keyStart + keyLength
                keyBytes = Data(data[(data.startIndex + keyStart)..<(data.startIndex + keyEnd)])
                if let fn = try? FileName.parse(keyBytes) { keyName = fn.name }
            }
            var subnodeVCN: UInt64?
            if hasSubnode {
                subnodeVCN = try data.readU64LE(at: pos + entryLength - 8)
            }
            entries.append(_InteriorEntry(
                fileReference: fileRef,
                entryLength: entryLength,
                keyLength: keyLength,
                flags: flags,
                keyBytes: keyBytes,
                keyName: keyName,
                subnodeVCN: subnodeVCN
            ))
            pos += entryLength
            if isLast { break }
        }
        return entries
    }

    /// Serialize a $INDEX_ROOT body for a LARGE_INDEX tree with `interior`
    /// entries (each with a key + subnode VCN) terminated by a LAST sentinel
    /// whose subnode is `lastSubnodeVCN`.
    private func serializeLargeIndexRoot(
        indexAllocationBlockSize: UInt32,
        clustersPerIndexBlock: Int8,
        interior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)],
        lastSubnodeVCN: UInt64
    ) -> Data {
        // Compute total entry bytes.
        var entriesBytes = Data()
        for e in interior {
            // INDEX_ENTRY with key + subnode VCN: header(16) + keyBytes + alignment + 8 bytes subnode VCN at end.
            let rawLen = 16 + e.body.count
            let aligned = ((rawLen + 7) / 8) * 8
            let totalLen = aligned + 8  // append subnode VCN at the very end
            var entry = Data(count: totalLen)
            MFTRecord.writeU64LE(into: &entry, at: 0, value: e.fileRef)
            MFTRecord.writeU16LE(into: &entry, at: 8, value: UInt16(totalLen))
            MFTRecord.writeU16LE(into: &entry, at: 10, value: UInt16(e.body.count))
            MFTRecord.writeU16LE(into: &entry, at: 12, value: 0x01)  // HAS_SUBNODE
            MFTRecord.writeU16LE(into: &entry, at: 14, value: 0)
            for (i, byte) in e.body.enumerated() {
                entry[entry.startIndex + 16 + i] = byte
            }
            MFTRecord.writeU64LE(into: &entry, at: totalLen - 8, value: e.subnodeVCN)
            entriesBytes.append(entry)
        }
        // LAST sentinel with HAS_SUBNODE.
        var last = Data(count: 24)
        MFTRecord.writeU64LE(into: &last, at: 0, value: 0)
        MFTRecord.writeU16LE(into: &last, at: 8, value: 24)
        MFTRecord.writeU16LE(into: &last, at: 10, value: 0)
        MFTRecord.writeU16LE(into: &last, at: 12, value: 0x03)  // LAST | HAS_SUBNODE
        MFTRecord.writeU16LE(into: &last, at: 14, value: 0)
        MFTRecord.writeU64LE(into: &last, at: 16, value: lastSubnodeVCN)
        entriesBytes.append(last)

        // Preamble (16) + INDEX_HEADER (16) + entries.
        var body = Data(count: 32 + entriesBytes.count)
        MFTRecord.writeU32LE(into: &body, at: 0,  value: 0x30)
        MFTRecord.writeU32LE(into: &body, at: 4,  value: 0x01)
        MFTRecord.writeU32LE(into: &body, at: 8,  value: indexAllocationBlockSize)
        body[body.startIndex + 12] = UInt8(bitPattern: clustersPerIndexBlock)
        // INDEX_HEADER at offset 16
        MFTRecord.writeU32LE(into: &body, at: 16, value: 16)
        MFTRecord.writeU32LE(into: &body, at: 20, value: UInt32(16 + entriesBytes.count))
        MFTRecord.writeU32LE(into: &body, at: 24, value: UInt32(16 + entriesBytes.count))
        body[body.startIndex + 28] = 0x01  // LARGE_INDEX
        for (i, byte) in entriesBytes.enumerated() {
            body[body.startIndex + 32 + i] = byte
        }
        return body
    }

    /// Merge adjacent extents (same direction, contiguous LCNs). Keeps the
    /// runlist short — important since $INDEX_ALLOCATION must fit in the
    /// parent MFT record's slack.
    private func mergeAdjacentExtents(_ extents: [Extent]) -> [Extent] {
        var merged: [Extent] = []
        for e in extents {
            if let last = merged.last,
               let lastLCN = last.startLCN,
               let thisLCN = e.startLCN,
               lastLCN + last.clusterCount == thisLCN {
                merged[merged.count - 1] = Extent(startLCN: lastLCN, clusterCount: last.clusterCount + e.clusterCount)
            } else {
                merged.append(e)
            }
        }
        return merged
    }

    private func findIndexAllocationAttributeID(attrs: [Attribute]) throws -> UInt16 {
        guard let attr = attrs.first(where: {
            $0.type == .indexAllocation && $0.nameOrEmpty == "$I30"
        }) else {
            throw NTFSError.corruptOnDisk(description: "splitLeaf: $INDEX_ALLOCATION:$I30 missing")
        }
        return attr.header.attributeID
    }

    /// Re-serialize the $INDEX_ALLOCATION:$I30 attribute with new extents.
    private func serializeIndexAllocationAttribute(
        attrID: UInt16,
        extents: [Extent],
        totalBytes: UInt64
    ) -> Data {
        let nameUTF16 = Array("$I30".utf16)
        let nameByteCount = nameUTF16.count * 2
        let runlist = encodeRunlist(extents: extents)
        let runlistOffset = 64 + nameByteCount
        let rawLen = runlistOffset + runlist.count
        let alignedLen = ((rawLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        let totalClusters = extents.reduce(0) { $0 + $1.clusterCount }
        MFTRecord.writeU32LE(into: &data, at: 0,  value: AttributeType.indexAllocation.rawValue)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 1
        data[data.startIndex + 9] = UInt8(nameUTF16.count)
        MFTRecord.writeU16LE(into: &data, at: 10, value: 64)
        MFTRecord.writeU16LE(into: &data, at: 12, value: 0)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        MFTRecord.writeU64LE(into: &data, at: 16, value: 0)
        MFTRecord.writeU64LE(into: &data, at: 24, value: totalClusters - 1)
        MFTRecord.writeU16LE(into: &data, at: 32, value: UInt16(runlistOffset))
        data[data.startIndex + 34] = 0
        MFTRecord.writeU64LE(into: &data, at: 40, value: totalBytes)
        MFTRecord.writeU64LE(into: &data, at: 48, value: totalBytes)
        MFTRecord.writeU64LE(into: &data, at: 56, value: totalBytes)
        for (i, codeUnit) in nameUTF16.enumerated() {
            data[data.startIndex + 64 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[data.startIndex + 64 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        for (i, byte) in runlist.enumerated() {
            data[data.startIndex + runlistOffset + i] = byte
        }
        return data
    }

    /// Update the $BITMAP:$I30 attribute by setting the bit at `blockIndex`.
    /// Returns the serialized replacement attribute bytes.
    private func updateBitmapAttribute(attrs: [Attribute], blockIndex: UInt64) throws -> Data {
        try updateBitmapAttribute(attrs: attrs, blockIndices: [blockIndex])
    }

    /// v0.4 Phase 3(A): set multiple bits in $BITMAP:$I30 in one rebuild.
    /// Used by `heightGrowIndexRoot` where 3 new blocks (the primary new
    /// leaf + 2 intermediates) need their bits set together.
    private func updateBitmapAttribute(attrs: [Attribute], blockIndices: [UInt64]) throws -> Data {
        guard let attr = attrs.first(where: {
            $0.rawType == 0xB0 && $0.nameOrEmpty == "$I30"
        }) else {
            throw NTFSError.corruptOnDisk(description: "updateBitmap: $BITMAP:$I30 missing")
        }
        guard case let .resident(bytes, _) = attr.value else {
            throw NTFSError.unsupportedFeature(description: "updateBitmap: $BITMAP:$I30 must be resident (non-resident bitmaps not yet supported)")
        }
        var updated = bytes
        for blockIndex in blockIndices {
            let byteIdx = Int(blockIndex / 8)
            let bitIdx = Int(blockIndex % 8)
            guard byteIdx < updated.count else {
                throw NTFSError.unsupportedFeature(
                    description: "updateBitmap: block index \(blockIndex) exceeds bitmap capacity \(updated.count * 8); growing $BITMAP not yet supported"
                )
            }
            updated[updated.startIndex + byteIdx] |= (UInt8(1) << bitIdx)
        }
        return buildNamedResidentAttribute(
            type: 0xB0,
            attrID: attr.header.attributeID,
            flags: attr.header.flags,
            attributeName: "$I30",
            value: updated
        )
    }

    /// Rewrite the parent MFT record swapping $INDEX_ROOT body, $INDEX_ALLOCATION
    /// attribute, and $BITMAP attribute in one shot. The shared helper
    /// `rewriteEntireAttribute` operates on one attribute at a time; we apply
    /// it sequentially.
    private func rewriteParentForLeafSplit(
        parent: MFTRecord,
        newRootBody: Data,
        newIndexAllocAttrBytes: Data,
        newBitmapAttrBytes: Data
    ) throws -> Data {
        // `usedSize` here follows the header-field convention: byte offset AFTER
        // the end marker (i.e., end-marker-offset + 4). Both `rewriteResident
        // Attribute` and `rewriteEntireAttribute` expect that form.

        // Step A: replace $INDEX_ROOT body.
        var bytes = try rewriteResidentAttribute(
            in: parent.bytes,
            firstAttributeOffset: Int(parent.firstAttributeOffset),
            usedSize: Int(parent.usedSize),
            recordSize: Int(parent.allocatedSize),
            replacingType: AttributeType.indexRoot.rawValue,
            attributeName: "$I30",
            newValueBytes: newRootBody
        )
        var usedSize = (locateEndMarker(in: bytes, fromOffset: Int(parent.firstAttributeOffset)) ?? 0) + 4
        MFTRecord.writeU32LE(into: &bytes, at: 24, value: UInt32(usedSize))

        // Step B: replace $INDEX_ALLOCATION attribute.
        bytes = try rewriteEntireAttribute(
            in: bytes,
            firstAttributeOffset: Int(parent.firstAttributeOffset),
            usedSize: usedSize,
            recordSize: Int(parent.allocatedSize),
            replacingType: AttributeType.indexAllocation.rawValue,
            attributeName: "$I30",
            replacementBytes: newIndexAllocAttrBytes
        )
        usedSize = (locateEndMarker(in: bytes, fromOffset: Int(parent.firstAttributeOffset)) ?? 0) + 4
        MFTRecord.writeU32LE(into: &bytes, at: 24, value: UInt32(usedSize))

        // Step C: replace $BITMAP attribute.
        bytes = try rewriteEntireAttribute(
            in: bytes,
            firstAttributeOffset: Int(parent.firstAttributeOffset),
            usedSize: usedSize,
            recordSize: Int(parent.allocatedSize),
            replacingType: 0xB0,
            attributeName: "$I30",
            replacementBytes: newBitmapAttrBytes
        )
        usedSize = (locateEndMarker(in: bytes, fromOffset: Int(parent.firstAttributeOffset)) ?? 0) + 4
        MFTRecord.writeU32LE(into: &bytes, at: 24, value: UInt32(usedSize))
        return bytes
    }

    /// Build a $INDEX_ROOT body for an empty LARGE_INDEX directory (no real
    /// entries; just a LAST+HAS_SUBNODE sentinel pointing at the first leaf).
    private func buildLargeIndexEmptyRoot(
        indexAllocationBlockSize: UInt32,
        clustersPerIndexBlock: Int8,
        firstSubnodeVCN: UInt64
    ) -> Data {
        // Preamble (16) + INDEX_HEADER (16) + LAST sentinel WITH subnode (24).
        var body = Data(count: 16 + 16 + 24)
        MFTRecord.writeU32LE(into: &body, at: 0,  value: 0x30)          // attributeTypeIndexed
        MFTRecord.writeU32LE(into: &body, at: 4,  value: 0x01)          // COLLATION_FILENAME
        MFTRecord.writeU32LE(into: &body, at: 8,  value: indexAllocationBlockSize)
        body[body.startIndex + 12] = UInt8(bitPattern: clustersPerIndexBlock)
        // INDEX_HEADER at offset 16
        MFTRecord.writeU32LE(into: &body, at: 16, value: 16)            // entriesOffset
        MFTRecord.writeU32LE(into: &body, at: 20, value: UInt32(16 + 24)) // usedSize (header + LAST-with-subnode)
        MFTRecord.writeU32LE(into: &body, at: 24, value: UInt32(16 + 24)) // allocatedSize
        body[body.startIndex + 28] = 0x01                                 // LARGE_INDEX flag
        // LAST sentinel at offset 32: 24 bytes (16 header + 8 subnode VCN).
        MFTRecord.writeU64LE(into: &body, at: 32, value: 0)              // fileReference unused
        MFTRecord.writeU16LE(into: &body, at: 40, value: 24)             // entryLength
        MFTRecord.writeU16LE(into: &body, at: 42, value: 0)              // keyLength
        MFTRecord.writeU16LE(into: &body, at: 44, value: 0x03)           // flags: LAST | HAS_SUBNODE
        MFTRecord.writeU16LE(into: &body, at: 46, value: 0)              // reserved
        MFTRecord.writeU64LE(into: &body, at: 48, value: firstSubnodeVCN)
        return body
    }

    /// v0.4 Phase 3(A): Build an INTERIOR INDX block (pre-USA) with the
    /// given (key + subnode VCN) entries + LAST sentinel pointing at
    /// `lastSubnodeVCN`. Used by the $INDEX_ROOT height-grow path when
    /// the parent MFT record can't fit another interior entry — we move
    /// existing interior entries from $INDEX_ROOT into intermediate INDX
    /// blocks (one per half of the bisection), allocated in
    /// $INDEX_ALLOCATION.
    ///
    /// Interior entry layout: header(16) + keyBytes + 8-byte alignment +
    /// 8-byte subnode VCN. The HAS_SUBNODE flag (0x01) is set on every
    /// non-LAST entry; the LAST sentinel has flags = LAST|HAS_SUBNODE
    /// (0x03) with no key + 8-byte subnode VCN.
    private func buildInteriorIndxBlock(
        blockSize: Int,
        sectorSize: Int,
        vcn: UInt64,
        interior: [(key: String, body: Data, fileRef: UInt64, subnodeVCN: UInt64)],
        lastSubnodeVCN: UInt64
    ) throws -> Data {
        var block = Data(count: blockSize)
        let fixupCount = blockSize / sectorSize
        let usaCount = UInt16(1 + fixupCount)
        let usaOffset: UInt16 = 40
        MFTRecord.writeU32LE(into: &block, at: 0,  value: IndexAllocationBlock.magicINDX)
        MFTRecord.writeU16LE(into: &block, at: 4,  value: usaOffset)
        MFTRecord.writeU16LE(into: &block, at: 6,  value: usaCount)
        MFTRecord.writeU64LE(into: &block, at: 8,  value: 0)              // LSN
        MFTRecord.writeU64LE(into: &block, at: 16, value: vcn)
        MFTRecord.writeU16LE(into: &block, at: Int(usaOffset), value: 1)

        let usaBytes = Int(usaCount) * 2
        let entriesStart = ((40 + usaBytes + 7) / 8) * 8
        let entriesOffsetWithinHeader = entriesStart - 24

        // Serialize interior entries + LAST sentinel (each with HAS_SUBNODE).
        var entryBytes = Data()
        for e in interior {
            let rawLen = 16 + e.body.count
            let aligned = ((rawLen + 7) / 8) * 8
            let totalLen = aligned + 8  // 8-byte subnode VCN at end
            var entry = Data(count: totalLen)
            MFTRecord.writeU64LE(into: &entry, at: 0, value: e.fileRef)
            MFTRecord.writeU16LE(into: &entry, at: 8, value: UInt16(totalLen))
            MFTRecord.writeU16LE(into: &entry, at: 10, value: UInt16(e.body.count))
            MFTRecord.writeU16LE(into: &entry, at: 12, value: 0x01)  // HAS_SUBNODE
            MFTRecord.writeU16LE(into: &entry, at: 14, value: 0)
            for (i, byte) in e.body.enumerated() {
                entry[entry.startIndex + 16 + i] = byte
            }
            MFTRecord.writeU64LE(into: &entry, at: totalLen - 8, value: e.subnodeVCN)
            entryBytes.append(entry)
        }
        // LAST sentinel with HAS_SUBNODE.
        var lastSentinel = Data(count: 24)
        MFTRecord.writeU64LE(into: &lastSentinel, at: 0, value: 0)
        MFTRecord.writeU16LE(into: &lastSentinel, at: 8, value: 24)
        MFTRecord.writeU16LE(into: &lastSentinel, at: 10, value: 0)
        MFTRecord.writeU16LE(into: &lastSentinel, at: 12, value: 0x03)  // LAST | HAS_SUBNODE
        MFTRecord.writeU16LE(into: &lastSentinel, at: 14, value: 0)
        MFTRecord.writeU64LE(into: &lastSentinel, at: 16, value: lastSubnodeVCN)
        entryBytes.append(lastSentinel)

        guard entriesStart + entryBytes.count <= blockSize else {
            throw NTFSError.unsupportedFeature(
                description: "buildInteriorIndxBlock: \(interior.count) interior entries (\(entryBytes.count) bytes) overflow block (start \(entriesStart), block \(blockSize)) — interior INDX block can hold ~40-60 entries depending on key length"
            )
        }
        for (i, byte) in entryBytes.enumerated() {
            block[block.startIndex + entriesStart + i] = byte
        }
        MFTRecord.writeU32LE(into: &block, at: 24, value: UInt32(entriesOffsetWithinHeader))
        MFTRecord.writeU32LE(into: &block, at: 28, value: UInt32(entriesOffsetWithinHeader + entryBytes.count))
        MFTRecord.writeU32LE(into: &block, at: 32, value: UInt32(blockSize - 24))
        block[block.startIndex + 36] = 0x01  // flags: LARGE_INDEX (this is an interior block)
        return block
    }

    /// Build an INDX block (pre-USA, ready for reverseFixup) with `entries`
    /// as a leaf (no subnodes). vcn is the block's VCN within $INDEX_ALLOCATION.
    private func buildEmptyIndxBlock(
        blockSize: Int,
        sectorSize: Int,
        vcn: UInt64,
        entries: [(UInt64, Data, String)]
    ) throws -> Data {
        var block = Data(count: blockSize)
        let fixupCount = blockSize / sectorSize
        let usaCount = UInt16(1 + fixupCount)
        let usaOffset: UInt16 = 40           // INDX header is 24 bytes, INDEX_HEADER 16 = 40
        // INDX magic + USA + LSN + VCN
        MFTRecord.writeU32LE(into: &block, at: 0,  value: IndexAllocationBlock.magicINDX)
        MFTRecord.writeU16LE(into: &block, at: 4,  value: usaOffset)
        MFTRecord.writeU16LE(into: &block, at: 6,  value: usaCount)
        MFTRecord.writeU64LE(into: &block, at: 8,  value: 0)              // LSN
        MFTRecord.writeU64LE(into: &block, at: 16, value: vcn)
        // USA[0] sentinel = 1; USA fix-up slots remain zero (reverseFixup populates).
        MFTRecord.writeU16LE(into: &block, at: Int(usaOffset), value: 1)

        // Compute where INDEX_HEADER + entries live. INDEX_HEADER at offset 24,
        // but the USA at offset 40 (size usaCount * 2) sits between the INDEX_HEADER
        // and the first entry. The cleanest layout: shift entries start past USA.
        // Standard NTFS INDX header layout:
        //   24: INDEX_HEADER (16 bytes)
        //   40: USA (1 + N fix-ups, here usaCount * 2 bytes)
        //   40 + usaCount*2, rounded up to 8: entries
        let usaBytes = Int(usaCount) * 2
        let entriesStart = ((40 + usaBytes + 7) / 8) * 8
        let entriesOffsetWithinHeader = entriesStart - 24

        // Serialize entries + LAST sentinel.
        var entryBytes = Data()
        for entry in entries {
            entryBytes.append(IndexBuilder.serializeEntry(fileReference: entry.0, fileNameBody: entry.1))
        }
        entryBytes.append(IndexBuilder.serializeLastSentinel())
        guard entriesStart + entryBytes.count <= blockSize else {
            throw NTFSError.unsupportedFeature(
                description: "buildEmptyIndxBlock: entries (\(entryBytes.count) bytes) overflow block (start \(entriesStart), block \(blockSize))"
            )
        }
        for (i, byte) in entryBytes.enumerated() {
            block[block.startIndex + entriesStart + i] = byte
        }
        // INDEX_HEADER at offset 24
        MFTRecord.writeU32LE(into: &block, at: 24, value: UInt32(entriesOffsetWithinHeader))
        // usedSize (relative to INDEX_HEADER start) = entriesOffset + entry bytes
        MFTRecord.writeU32LE(into: &block, at: 28, value: UInt32(entriesOffsetWithinHeader + entryBytes.count))
        // allocatedSize = block size - 24 (offset of INDEX_HEADER)
        MFTRecord.writeU32LE(into: &block, at: 32, value: UInt32(blockSize - 24))
        block[block.startIndex + 36] = 0  // flags: not LARGE (this IS the leaf)
        return block
    }

    /// Build a non-resident $INDEX_ALLOCATION:$I30 attribute carrying `extent`.
    private func buildIndexAllocationAttribute(
        attrID: UInt16,
        extent: Extent,
        clusterBytes: UInt64
    ) -> Data {
        let nameUTF16 = Array("$I30".utf16)
        let nameByteCount = nameUTF16.count * 2
        let runlist = encodeRunlist(extents: [extent])
        // Header (16) + non-resident ext (48) + name bytes + runlist + 8-byte align.
        let runlistOffset = 64 + nameByteCount  // place name right after non-resident ext, then runlist
        let rawLen = runlistOffset + runlist.count
        let alignedLen = ((rawLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &data, at: 0,  value: AttributeType.indexAllocation.rawValue)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 1                                     // non-resident
        data[data.startIndex + 9] = UInt8(nameUTF16.count)
        MFTRecord.writeU16LE(into: &data, at: 10, value: 64)              // nameOffset
        MFTRecord.writeU16LE(into: &data, at: 12, value: 0)               // flags
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        // Non-resident extension.
        MFTRecord.writeU64LE(into: &data, at: 16, value: 0)               // startingVCN
        MFTRecord.writeU64LE(into: &data, at: 24, value: extent.clusterCount - 1) // lastVCN
        MFTRecord.writeU16LE(into: &data, at: 32, value: UInt16(runlistOffset))
        data[data.startIndex + 34] = 0                                     // compressionUnit
        let totalBytes = extent.clusterCount * clusterBytes
        MFTRecord.writeU64LE(into: &data, at: 40, value: totalBytes)      // allocatedSize
        MFTRecord.writeU64LE(into: &data, at: 48, value: totalBytes)      // realSize
        MFTRecord.writeU64LE(into: &data, at: 56, value: totalBytes)      // initializedSize
        // Name bytes at offset 64.
        for (i, codeUnit) in nameUTF16.enumerated() {
            data[data.startIndex + 64 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[data.startIndex + 64 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        for (i, byte) in runlist.enumerated() {
            data[data.startIndex + runlistOffset + i] = byte
        }
        return data
    }

    /// Build a generic named resident attribute (header + 8-byte resident ext + name + value).
    private func buildNamedResidentAttribute(
        type: UInt32,
        attrID: UInt16,
        flags: UInt16,
        attributeName: String,
        value: Data
    ) -> Data {
        let nameUTF16 = Array(attributeName.utf16)
        let nameByteCount = nameUTF16.count * 2
        let valueOffset = 24 + nameByteCount
        let rawLen = valueOffset + value.count
        let alignedLen = ((rawLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &data, at: 0,  value: type)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 0                                     // resident
        data[data.startIndex + 9] = UInt8(nameUTF16.count)
        MFTRecord.writeU16LE(into: &data, at: 10, value: 24)
        MFTRecord.writeU16LE(into: &data, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        MFTRecord.writeU32LE(into: &data, at: 16, value: UInt32(value.count))
        MFTRecord.writeU16LE(into: &data, at: 20, value: UInt16(valueOffset))
        data[data.startIndex + 22] = 0
        data[data.startIndex + 23] = 0
        for (i, codeUnit) in nameUTF16.enumerated() {
            data[data.startIndex + 24 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[data.startIndex + 24 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        for (i, byte) in value.enumerated() {
            data[data.startIndex + valueOffset + i] = byte
        }
        return data
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
        let attrs = try await allAttributesOf(recordNumber: parentRecordNumber)

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
            // LARGE_INDEX path: find the entry in some leaf INDX block and rewrite that block.
            guard let allocAttr = attrs.first(where: {
                $0.type == .indexAllocation && $0.nameOrEmpty == "$I30"
            }) else { return }  // no $INDEX_ALLOCATION — nothing to remove
            guard case let .nonResident(_, _, _, _, _, _, _, allocExtents) = allocAttr.value else {
                return
            }
            _ = try await IndexAllocationWriter.remove(
                rootBody: rootBytes,
                allocationExtents: allocExtents,
                indexRecordSizeBytes: indexRecordSizeBytes,
                bytesPerCluster: bytesPerCluster,
                sectorSize: Int(boot.bytesPerSector),
                device: device,
                targetName: childFileName
            )
            return
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
                description: "rewriteResidentAttribute: new attribute (\(newAttrLength) bytes) would overflow parent record (used \(usedSize), record \(recordSize), type 0x\(String(replacingType, radix: 16, uppercase: true)))"
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

    // MARK: — Block G stage 5: $Volume dirty-bit management

    /// MFT record number of the $Volume system file. Always 3 per NTFS spec.
    public static let volumeRecordNumber: UInt64 = 3

    /// Read the current $VOLUME_INFORMATION attribute. Cheap — small resident
    /// 12-byte attribute on a record we touch rarely.
    public func volumeInformation() async throws -> VolumeInformation {
        let mft = self.mft()
        let record = try await mft.record(at: Self.volumeRecordNumber)
        let attrs = try record.attributes()
        // $VOLUME_INFORMATION = attribute type 0x70.
        guard let attr = attrs.first(where: { $0.rawType == 0x70 }) else {
            throw NTFSError.corruptOnDisk(
                description: "$Volume record \(Self.volumeRecordNumber) lacks $VOLUME_INFORMATION"
            )
        }
        guard case let .resident(bytes, _) = attr.value else {
            throw NTFSError.corruptOnDisk(description: "$VOLUME_INFORMATION must be resident")
        }
        return try VolumeInformation.parse(bytes)
    }

    /// Whether the volume's "needs recovery" flag is set. NTFS sets this on
    /// mount and clears it on clean unmount; chkdsk / ntfsfix check it first
    /// when deciding whether to scan.
    public func isDirty() async throws -> Bool {
        try await volumeInformation().flags.contains(.isDirty)
    }

    /// Mark the volume dirty + flush. Call this immediately after opening a
    /// volume for writes, BEFORE any mutation. Pairs with `endWriteSession()`
    /// which clears the dirty bit + flushes again. The window between the two
    /// is the only state in which an interrupted ntfsctl invocation can leave
    /// inconsistent metadata — and dirty=1 tells Windows / chkdsk to scan it.
    ///
    /// Idempotent: setting dirty=1 when already dirty is a no-op (just a re-
    /// write of the same byte).
    public func beginWriteSession() async throws {
        try await setDirty(true)
        try await device.synchronize()
    }

    /// Clear the dirty bit + flush. Call AFTER all mutations are complete.
    /// The flush before clearing is critical: without it a kernel buffer
    /// reorder could land dirty=0 on disk while the data writes are still
    /// in cache, and a fast unplug at that moment loses the data while
    /// Windows trusts the volume.
    public func endWriteSession() async throws {
        // Flush data first.
        try await device.synchronize()
        try await setDirty(false)
        // Flush the dirty-bit clear too.
        try await device.synchronize()
    }

    /// v0.4 Phase 1: enter bulk-insert mode for one destination directory.
    ///
    /// While this mode is active, `refreshParentI30Size` (called from every
    /// `Volume.write` / `Volume.writeFile` to keep $I30's size hints in
    /// sync with the file's actual size) is skipped for files whose parent
    /// recnum matches `parentRN`. On a 22 k-file `cp -r`, this is the
    /// difference between 22 k INDX-block rewrites and zero.
    ///
    /// `endBulkInsert` MUST be called to leave bulk-insert mode. Use
    /// `Swift`'s `defer { try? await volume.endBulkInsert() }` pattern.
    ///
    /// Nesting / re-entry is **not** supported. Calling `beginBulkInsert`
    /// while already in bulk-insert mode throws — the consumer (typically
    /// `cp -r`) finishes one destination dir before starting the next.
    ///
    /// Size hints in $I30 are cosmetic — they drive the Windows Explorer
    /// "Size" column and similar UI surfaces. Files copied during bulk
    /// insert are **byte-correct on disk** but will show 0 / stale sizes
    /// in some UIs until a subsequent write or an explicit hint-refresh
    /// pass updates them.
    public func beginBulkInsert(into parentRN: UInt64) async throws {
        if _bulkInsertParentRN != nil {
            throw NTFSError.unsupportedFeature(
                description: "beginBulkInsert: already in bulk-insert mode for parent \(_bulkInsertParentRN!); nested bulk insert is not supported"
            )
        }
        _bulkInsertParentRN = parentRN
        _bulkInsertSkippedRefreshCount = 0
        _bulkInsertLeafCache = BulkLeafCache()
        _bulkInsertLastCacheHits = 0
        _bulkInsertLastDirtyLeavesFlushed = 0
    }

    /// v0.4 Phase 1+2: leave bulk-insert mode. Flushes any cached leaf
    /// writes to disk, returns the number of size-hint refreshes that
    /// were skipped during the session (for diagnostics + tests).
    /// Idempotent — calling outside bulk-insert mode is a no-op returning 0.
    @discardableResult
    public func endBulkInsert() async throws -> Int {
        let n = _bulkInsertSkippedRefreshCount
        if let cache = _bulkInsertLeafCache {
            _ = try await cache.flushAll(device: device)
            // Snapshot counters before dropping the cache reference so
            // post-end introspection hooks have something to read.
            _bulkInsertLastCacheHits = cache.cacheHits
            _bulkInsertLastDirtyLeavesFlushed = cache.totalDirtyLeavesFlushed
        }
        _bulkInsertLeafCache = nil
        _bulkInsertParentRN = nil
        _bulkInsertSkippedRefreshCount = 0
        return n
    }

    /// v0.4 Phase 1: introspection hook for tests. Returns the count of
    /// `refreshParentI30Size` calls skipped so far in the current bulk-
    /// insert session, or 0 if not in one.
    public func bulkInsertSkippedRefreshCount() async -> Int {
        _bulkInsertSkippedRefreshCount
    }

    /// v0.4 Phase 2: introspection hook for tests. Returns the count of
    /// leaf-cache hits during the most recent bulk-insert session.
    /// Reads from a snapshot captured at `endBulkInsert`, so it's valid
    /// AFTER the session ends.
    public func bulkInsertLeafCacheHits() async -> Int {
        if let cache = _bulkInsertLeafCache {
            return cache.cacheHits
        }
        return _bulkInsertLastCacheHits
    }

    /// v0.4 Phase 2: introspection hook for tests. Returns the number of
    /// dirty leaves flushed during the most recent bulk-insert session
    /// (cumulative across both flushOne calls and the final flushAll).
    /// Reads from a snapshot captured at `endBulkInsert`.
    public func bulkInsertDirtyLeavesFlushed() async -> Int {
        if let cache = _bulkInsertLeafCache {
            return cache.totalDirtyLeavesFlushed
        }
        return _bulkInsertLastDirtyLeavesFlushed
    }

    /// Set or clear the $VOLUME_INFORMATION dirty bit. After every batch of
    /// writes is complete, callers should `setDirty(false)` so that chkdsk /
    /// ntfsfix treat the volume as cleanly-unmounted.
    public func setDirty(_ dirty: Bool) async throws {
        let mft = self.mft()
        let record = try await mft.record(at: Self.volumeRecordNumber)
        let attrs = try record.attributes()
        guard let attr = attrs.first(where: { $0.rawType == 0x70 }) else {
            throw NTFSError.corruptOnDisk(
                description: "setDirty: $VOLUME_INFORMATION not found in $Volume record"
            )
        }
        guard case let .resident(bytes, _) = attr.value else {
            throw NTFSError.corruptOnDisk(description: "setDirty: $VOLUME_INFORMATION must be resident")
        }
        let current = try VolumeInformation.parse(bytes)
        let updated = current.setting(.isDirty, to: dirty)
        let newAttrBytes = serializeResidentAttribute(
            type: 0x70,
            attrID: attr.header.attributeID,
            flags: attr.header.flags,
            attributeName: "",
            value: updated.serialize()
        )
        let newRecordBytes = try rewriteEntireAttribute(
            in: record.bytes,
            firstAttributeOffset: Int(record.firstAttributeOffset),
            usedSize: Int(record.usedSize),
            recordSize: Int(record.allocatedSize),
            replacingType: 0x70,
            attributeName: "",
            replacementBytes: newAttrBytes
        )
        let newUsedSize = locateEndMarker(in: newRecordBytes, fromOffset: Int(record.firstAttributeOffset))
        guard let newUsedSize = newUsedSize else {
            throw NTFSError.corruptOnDisk(description: "setDirty: rewritten record has no end marker")
        }
        var updatedBytes = newRecordBytes
        MFTRecord.writeU32LE(into: &updatedBytes, at: 24, value: UInt32(newUsedSize + 4))
        try await mft.writeRawRecord(at: Self.volumeRecordNumber, postFixupBytes: updatedBytes)
    }

    /// Generic resident-attribute serializer (no name). Variant of the
    /// $DATA-specific one used by Stage 4; this one is parameterized over
    /// type. Used by setDirty's $VOLUME_INFORMATION rewrite.
    private func serializeResidentAttribute(
        type: UInt32,
        attrID: UInt16,
        flags: UInt16,
        attributeName: String,
        value: Data
    ) -> Data {
        let nameByteCount = attributeName.utf16.count * 2
        let bodyLen = value.count
        let rawLen = 16 + 8 + nameByteCount + bodyLen
        let alignedLen = ((rawLen + 7) / 8) * 8
        var data = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &data, at: 0,  value: type)
        MFTRecord.writeU32LE(into: &data, at: 4,  value: UInt32(alignedLen))
        data[data.startIndex + 8] = 0
        data[data.startIndex + 9] = UInt8(attributeName.utf16.count)
        MFTRecord.writeU16LE(into: &data, at: 10, value: nameByteCount > 0 ? 24 : 0)
        MFTRecord.writeU16LE(into: &data, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &data, at: 14, value: attrID)
        MFTRecord.writeU32LE(into: &data, at: 16, value: UInt32(bodyLen))
        let valueOffset: UInt16 = UInt16(24 + nameByteCount)
        MFTRecord.writeU16LE(into: &data, at: 20, value: valueOffset)
        for (i, codeUnit) in attributeName.utf16.enumerated() {
            data[data.startIndex + 24 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[data.startIndex + 24 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        for (i, byte) in value.enumerated() {
            data[data.startIndex + Int(valueOffset) + i] = byte
        }
        return data
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

        // Three supported modes:
        //  - offset == 0: full rewrite (existing path below).
        //  - offset == existingSize: append (existing path below).
        //  - 0 < offset < existingSize AND offset + bytes.count <= existingSize:
        //    mid-file overwrite. No new allocations needed — patch the right
        //    clusters in place for non-resident, or read-modify-write for
        //    resident. Handled inline here and returns early.
        if offset > 0, offset < existingSize,
           offset.addingReportingOverflow(UInt64(bytes.count)).0 <= existingSize {
            try await overwriteRange(
                recordNumber: recordNumber,
                record: record,
                dataAttr: dataAttr,
                offset: offset,
                bytes: bytes
            )
            return
        }
        guard offset == 0 || offset == existingSize else {
            throw NTFSError.unsupportedFeature(
                description: "write: supported offsets are 0 (rewrite), \(existingSize) (append), or 0 < N <= \(existingSize) - bytes.count (mid-file in-place overwrite); got \(offset) + \(bytes.count) bytes"
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
        // Refresh size hints + mtime on both this record's $STANDARD_INFORMATION
        // and the parent's $I30 entry so list / Finder / sync tools see the
        // right state. Best-effort.
        try? await refreshParentI30Size(recordNumber: recordNumber, newRealSize: UInt64(bytes.count))
        try? await bumpMTimeOnWrite(recordNumber: recordNumber)
    }

    /// Bump $STANDARD_INFORMATION's mtime + mft-change time to "now" on the
    /// given file's MFT record AND refresh the parent's $I30 entry's
    /// $FILE_NAME mtime hints. Real apps (Finder, Lightroom, Google Photos,
    /// every photo organizer) read mtime to dedupe / sort / detect changes;
    /// without this every file ntfsctl writes has its mtime frozen at
    /// creation, breaking timestamp-dependent workflows.
    ///
    /// Best-effort: any sub-failure is swallowed because the underlying
    /// write already succeeded. The volume is still consistent — the
    /// timestamps just stay stale.
    private func bumpMTimeOnWrite(recordNumber: UInt64) async throws {
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        let attrs = try record.attributes()
        guard let stdInfo = attrs.first(where: { $0.type == .standardInformation }),
              case let .resident(stdBytes, _) = stdInfo.value else {
            return
        }
        let now = MFTRecordBuilder.windowsFiletimeNow()
        var newStd = stdBytes
        // $STANDARD_INFORMATION layout: 0=create, 8=mod, 16=mft-change, 24=access
        MFTRecord.writeU64LE(into: &newStd, at: 8,  value: now)
        MFTRecord.writeU64LE(into: &newStd, at: 16, value: now)
        // Wrap in a fresh resident attribute and replace.
        let newAttrBytes = serializeResidentAttribute(
            type: AttributeType.standardInformation.rawValue,
            attrID: stdInfo.header.attributeID,
            flags: stdInfo.header.flags,
            attributeName: "",
            value: newStd
        )
        let newRecordBytes = try rewriteEntireAttribute(
            in: record.bytes,
            firstAttributeOffset: Int(record.firstAttributeOffset),
            usedSize: Int(record.usedSize),
            recordSize: Int(record.allocatedSize),
            replacingType: AttributeType.standardInformation.rawValue,
            attributeName: "",
            replacementBytes: newAttrBytes
        )
        guard let mark = locateEndMarker(in: newRecordBytes, fromOffset: Int(record.firstAttributeOffset)) else {
            return
        }
        var updated = newRecordBytes
        MFTRecord.writeU32LE(into: &updated, at: 24, value: UInt32(mark + 4))
        try await mft.writeRawRecord(at: recordNumber, postFixupBytes: updated)
    }

    /// Update the $FILE_NAME size hints (realSize, allocatedSize) inside the
    /// parent directory's $I30 entry. Best-effort; ignored if the parent is
    /// LARGE_INDEX (would require descending the B-tree to find + rewrite the
    /// leaf entry). Real drivers compute from $DATA, so this is purely for
    /// `ntfsctl list --long` cosmetics.
    private func refreshParentI30Size(recordNumber: UInt64, newRealSize: UInt64) async throws {
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        let attrs = try record.attributes()
        guard let fnAttr = attrs.first(where: { $0.type == .fileName }),
              case let .resident(fnBytes, _) = fnAttr.value,
              let fn = try? FileName.parse(fnBytes) else {
            return
        }
        let parentRN = fn.parentRecordNumber
        // v0.4 Phase 1: skip during bulk insert into this parent. Size
        // hints in $I30 are cosmetic; the file's actual content is
        // already on disk and reachable through $I30 (just with stale /
        // zero size in the Windows Explorer column).
        if _bulkInsertParentRN == parentRN {
            _bulkInsertSkippedRefreshCount += 1
            return
        }
        let parent = try await mft.record(at: parentRN)
        let parentAttrs = try await allAttributesOf(recordNumber: parentRN)
        guard let irAttr = parentAttrs.first(where: { $0.type == .indexRoot && $0.nameOrEmpty == "$I30" }),
              case let .resident(rootBytes, _) = irAttr.value else {
            return
        }
        let root = try IndexRoot.parse(rootBytes)
        if root.isLargeIndex {
            // T1.3: LARGE_INDEX path. Walk the leaves via IndexAllocationWriter,
            // find the entry by name, rewrite its keyBytes with bumped sizes.
            guard let allocAttr = parentAttrs.first(where: {
                $0.type == .indexAllocation && $0.nameOrEmpty == "$I30"
            }), case let .nonResident(_, _, _, _, _, _, _, allocExtents) = allocAttr.value else {
                return
            }
            // Build the new $FILE_NAME body with bumped sizes — same length
            // as the existing one (only size hints change).
            var newBody = reserializeFileNameBody(fn)
            let allocSize = ((newRealSize + UInt64(bytesPerCluster) - 1) / UInt64(bytesPerCluster)) * UInt64(bytesPerCluster)
            MFTRecord.writeU64LE(into: &newBody, at: 40, value: allocSize)
            MFTRecord.writeU64LE(into: &newBody, at: 48, value: newRealSize)
            _ = try await IndexAllocationWriter.updateEntry(
                rootBody: rootBytes,
                allocationExtents: allocExtents,
                indexRecordSizeBytes: indexRecordSizeBytes,
                bytesPerCluster: bytesPerCluster,
                sectorSize: Int(boot.bytesPerSector),
                device: device,
                targetName: fn.name,
                newKeyBytes: newBody
            )
            return
        }

        var entries: [(fileReference: UInt64, fileNameBody: Data, sortKey: String)] = []
        for entry in root.entries {
            guard !entry.isLast, let efn = entry.fileName else { continue }
            if efn.name == fn.name && efn.namespace != .dos {
                var body = reserializeFileNameBody(efn)
                let allocSize = ((newRealSize + UInt64(bytesPerCluster) - 1) / UInt64(bytesPerCluster)) * UInt64(bytesPerCluster)
                MFTRecord.writeU64LE(into: &body, at: 40, value: allocSize)
                MFTRecord.writeU64LE(into: &body, at: 48, value: newRealSize)
                entries.append((entry.fileReference, body, efn.name))
            } else {
                entries.append((entry.fileReference, reserializeFileNameBody(efn), efn.name))
            }
        }
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
        guard let mark = locateEndMarker(in: newParentBytes, fromOffset: Int(parent.firstAttributeOffset)) else { return }
        var updated = newParentBytes
        MFTRecord.writeU32LE(into: &updated, at: 24, value: UInt32(mark + 4))
        try await mft.writeRawRecord(at: parentRN, postFixupBytes: updated)
    }

    /// Mid-file in-place overwrite. Caller guarantees offset + bytes.count <= existingSize.
    /// For resident $DATA, read-modify-write the whole content via the resident
    /// path. For non-resident, find each affected extent, compute the
    /// physical LCN+offset, and write directly — no allocation, no MFT touch.
    private func overwriteRange(
        recordNumber: UInt64,
        record: MFTRecord,
        dataAttr: Attribute,
        offset: UInt64,
        bytes: Data
    ) async throws {
        switch dataAttr.value {
        case let .resident(value, _):
            // Patch in memory, then re-write via the resident path.
            var patched = value
            for (i, b) in bytes.enumerated() {
                patched[patched.startIndex + Int(offset) + i] = b
            }
            try await write(at: recordNumber, offset: 0, bytes: patched)
        case let .nonResident(_, _, _, _, _, _, _, extents):
            let clusterBytes = UInt64(bytesPerCluster)
            var fileCursor: UInt64 = 0
            var srcCursor: Int = 0
            let endOffset = offset + UInt64(bytes.count)
            for extent in extents {
                let (extentBytesRaw, mulOverflow) = extent.clusterCount.multipliedReportingOverflow(by: clusterBytes)
                guard !mulOverflow else {
                    throw NTFSError.corruptOnDisk(description: "overwriteRange: extent length overflow")
                }
                let extentEnd = fileCursor + extentBytesRaw
                // Skip extents entirely before the requested region.
                if extentEnd <= offset {
                    fileCursor = extentEnd
                    continue
                }
                if fileCursor >= endOffset { break }
                let sliceStartInExtent = (offset > fileCursor) ? (offset - fileCursor) : 0
                let sliceEndInExtent = min(extentBytesRaw, endOffset - fileCursor)
                let writeBytes = Int(sliceEndInExtent - sliceStartInExtent)
                guard let startLCN = extent.startLCN else {
                    throw NTFSError.unsupportedFeature(description: "overwriteRange: sparse extent encountered (write would require allocation)")
                }
                let deviceOffset = startLCN * clusterBytes + sliceStartInExtent
                let chunk = bytes.subdata(in: srcCursor..<(srcCursor + writeBytes))
                try await device.write(offset: deviceOffset, bytes: chunk)
                srcCursor += writeBytes
                fileCursor = extentEnd
            }
            guard srcCursor == bytes.count else {
                throw NTFSError.corruptOnDisk(
                    description: "overwriteRange: wrote \(srcCursor) bytes, expected \(bytes.count) — runlist may not cover requested range"
                )
            }
        }
    }

    /// Streaming write: replace the file's `$DATA` with `totalSize` bytes
    /// fed by repeated `nextChunk` calls. Lets callers handle multi-GB files
    /// without materializing them in memory — the original `write(at:offset:
    /// bytes:)` requires the full payload as `Data`, which both caps practical
    /// file size and pegs RSS at file-size.
    ///
    /// Caller contract: chunk lengths sum to exactly `totalSize`. The closure
    /// is invoked until that total is reached; it must not return an empty
    /// `Data` until total bytes have been delivered. Mismatches throw
    /// `NTFSError.ioFailure`.
    ///
    /// Implementation strategy:
    ///  - Below `residentDataThreshold`: gather all chunks into memory and
    ///    fall through to the resident path; resident $DATA caps below ~700 B
    ///    so RSS impact is negligible.
    ///  - Above threshold: allocate clusters for the whole `totalSize` (may
    ///    be split across multiple extents on fragmented volumes), stream
    ///    each chunk into its position via the underlying `BlockDevice.write`,
    ///    then write the MFT record with the resulting non-resident $DATA.
    ///
    /// Crash safety: the bitmap is persisted as part of `allocateClusters`
    /// before any payload writes, so a crash mid-write leaves the bytes
    /// allocated but unreferenced (recoverable via `chkdsk`). This matches
    /// the existing `write` semantics.
    public func writeFile(
        at recordNumber: UInt64,
        totalSize: UInt64,
        nextChunk: () async throws -> Data
    ) async throws {
        guard recordNumber >= MFT.firstUserRecord else {
            throw NTFSError.unsupportedFeature(
                description: "writeFile: refusing to mutate reserved MFT record \(recordNumber)"
            )
        }
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        guard record.isInUse else {
            throw NTFSError.corruptOnDisk(description: "writeFile: MFT record \(recordNumber) is not in use")
        }
        if record.isDirectory {
            throw NTFSError.unsupportedFeature(description: "writeFile: target is a directory")
        }

        let attrs = try record.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(description: "writeFile: MFT record \(recordNumber) lacks unnamed $DATA")
        }

        // Free any old non-resident extents — we're rewriting.
        if case let .nonResident(_, _, _, _, _, _, _, oldExtents) = dataAttr.value {
            for extent in oldExtents {
                try await freeClusters(extent)
            }
        }

        let newDataAttr: Data
        if totalSize <= UInt64(Self.residentDataThreshold) {
            // Small file — collect chunks and use resident path. The cap is
            // ~700 bytes so this is bounded memory.
            var collected = Data()
            collected.reserveCapacity(Int(totalSize))
            while UInt64(collected.count) < totalSize {
                let chunk = try await nextChunk()
                if chunk.isEmpty {
                    throw NTFSError.ioFailure(
                        description: "writeFile: chunk source returned empty before reaching totalSize \(totalSize) (got \(collected.count))"
                    )
                }
                collected.append(chunk)
            }
            guard UInt64(collected.count) == totalSize else {
                throw NTFSError.ioFailure(
                    description: "writeFile: chunk source delivered \(collected.count) bytes, expected \(totalSize)"
                )
            }
            newDataAttr = serializeResidentDataAttribute(
                attrID: dataAttr.header.attributeID,
                flags: dataAttr.header.flags,
                value: collected
            )
        } else {
            // Big file — allocate clusters once (possibly split across extents
            // on fragmented volumes), then stream chunks into position.
            let clusterBytes = UInt64(bytesPerCluster)
            let clustersNeeded = (totalSize + clusterBytes - 1) / clusterBytes
            let extents = try await allocateClustersFragmented(count: clustersNeeded)
            let allocatedSize = clustersNeeded * clusterBytes

            try await streamChunksAcrossExtents(
                extents: extents,
                totalSize: totalSize,
                nextChunk: nextChunk
            )

            newDataAttr = serializeNonResidentDataAttribute(
                attrID: dataAttr.header.attributeID,
                flags: dataAttr.header.flags,
                realSize: totalSize,
                allocatedSize: allocatedSize,
                extentList: extents
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
            throw NTFSError.corruptOnDisk(description: "writeFile: rewritten record has no end marker")
        }
        var updatedBytes = newRecordBytes
        MFTRecord.writeU32LE(into: &updatedBytes, at: 24, value: UInt32(newUsedSize + 4))
        try await mft.writeRawRecord(at: recordNumber, postFixupBytes: updatedBytes)
        try? await refreshParentI30Size(recordNumber: recordNumber, newRealSize: totalSize)
        try? await bumpMTimeOnWrite(recordNumber: recordNumber)
    }

    /// Streaming write from a host file path. Convenience wrapper around
    /// `writeFile(at:totalSize:nextChunk:)`. Uses fixed-size pread chunks
    /// (default 1 MiB) so RSS stays flat regardless of file size.
    public func writeFile(
        at recordNumber: UInt64,
        fromFileAt sourceURL: URL,
        chunkSize: Int = 1 << 20
    ) async throws {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        let fileSize = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? UInt64 ?? 0

        var remaining = fileSize
        try await writeFile(at: recordNumber, totalSize: fileSize) {
            if remaining == 0 { return Data() }
            let take = Int(min(UInt64(chunkSize), remaining))
            let chunk = (try? handle.read(upToCount: take)) ?? Data()
            remaining -= UInt64(chunk.count)
            return chunk
        }
    }

    /// Allocate `count` clusters as one or more extents. Tries a single
    /// contiguous run first (cheap, no fragmentation). If the bitmap has no
    /// run that long, walks the bitmap repeatedly taking the largest available
    /// free run until the request is satisfied. Throws `outOfSpace` only if
    /// the total free count is genuinely insufficient.
    public func allocateClustersFragmented(count: UInt64) async throws -> [Extent] {
        if count == 0 { return [] }
        if let single = try? await allocateClusters(count) {
            return [single]
        }
        // Fall back to greedy multi-extent allocation.
        var bm = try await bitmap()
        var remaining = count
        var extents: [Extent] = []
        while remaining > 0 {
            // Take the largest run that fits (cap at remaining).
            var taken: UInt64 = 0
            // Try descending sizes; for v1 we just take the first run found
            // at the requested size. Start from remaining and halve until 1.
            var trySize = remaining
            while trySize >= 1 {
                if let extent = try? bm.allocate(trySize, startingAt: _allocHint) {
                    extents.append(extent)
                    taken = trySize
                    // Advance the hint so the next sub-run continues from where
                    // this one ended, keeping the fragments as close to
                    // contiguous as the bitmap allows.
                    advanceAllocHint(after: extent, clusterCount: bm.clusterCount)
                    break
                }
                if trySize == 1 { break }
                trySize = max(1, trySize / 2)
            }
            if taken == 0 {
                // Free what we already took, then surface outOfSpace.
                for e in extents { try? bm.free(e) }
                throw NTFSError.outOfSpace(requestedClusters: count, freeClusters: bm.freeClusterCount)
            }
            remaining -= taken
        }
        try await persistBitmap(bm)
        bm.clearDirty()
        _bitmap = bm
        return extents
    }

    /// Drive nextChunk() across `extents`, writing each chunk into the right
    /// LCN+offset. Pads the trailing partial cluster with zeros.
    private func streamChunksAcrossExtents(
        extents: [Extent],
        totalSize: UInt64,
        nextChunk: () async throws -> Data
    ) async throws {
        let clusterBytes = UInt64(bytesPerCluster)
        var extentIndex = 0
        var byteInExtent: UInt64 = 0
        var bytesWritten: UInt64 = 0

        while bytesWritten < totalSize {
            let chunk = try await nextChunk()
            if chunk.isEmpty {
                throw NTFSError.ioFailure(
                    description: "writeFile: chunk source returned empty after \(bytesWritten) of \(totalSize) bytes"
                )
            }
            var chunkOffset = 0
            while chunkOffset < chunk.count {
                if extentIndex >= extents.count {
                    throw NTFSError.ioFailure(
                        description: "writeFile: ran out of allocated extents at \(bytesWritten + UInt64(chunkOffset)) of \(totalSize)"
                    )
                }
                let extent = extents[extentIndex]
                guard let startLCN = extent.startLCN else {
                    throw NTFSError.corruptOnDisk(description: "writeFile: sparse extent in fresh allocation")
                }
                let extentBytes = extent.clusterCount * clusterBytes
                let spaceLeftInExtent = extentBytes - byteInExtent
                let chunkBytesLeft = UInt64(chunk.count - chunkOffset)
                let writeBytes = Int(min(spaceLeftInExtent, chunkBytesLeft))
                let slice = chunk.subdata(in: chunkOffset..<(chunkOffset + writeBytes))
                let deviceOffset = startLCN * clusterBytes + byteInExtent
                try await device.write(offset: deviceOffset, bytes: slice)
                chunkOffset += writeBytes
                byteInExtent += UInt64(writeBytes)
                if byteInExtent >= extentBytes {
                    extentIndex += 1
                    byteInExtent = 0
                }
            }
            bytesWritten += UInt64(chunk.count)
            if bytesWritten > totalSize {
                throw NTFSError.ioFailure(
                    description: "writeFile: chunk source overshot totalSize \(totalSize) by \(bytesWritten - totalSize) bytes"
                )
            }
        }

        // Pad final partial cluster with zeros so we don't leak previous
        // contents (matches writeContentToExtent semantics).
        let tailBytes = totalSize % clusterBytes
        if tailBytes != 0, extentIndex < extents.count || (extentIndex == extents.count && byteInExtent > 0) {
            let padCount = Int(clusterBytes - tailBytes)
            // Position is the current write head, which is at extents[extentIndex-1] end OR extents[extentIndex] byteInExtent
            // After the loop, byteInExtent points to the offset of the next-byte-to-write within the current extent.
            // If byteInExtent == 0, the write head just rolled into a fresh extent (extentIndex).
            let (effectiveIndex, effectiveOffset): (Int, UInt64) = {
                if byteInExtent == 0 && extentIndex > 0 {
                    return (extentIndex - 1, extents[extentIndex - 1].clusterCount * clusterBytes)
                }
                return (extentIndex, byteInExtent)
            }()
            if effectiveIndex < extents.count, let lcn = extents[effectiveIndex].startLCN {
                let pad = Data(repeating: 0, count: padCount)
                try await device.write(offset: lcn * clusterBytes + effectiveOffset, bytes: pad)
            }
        }
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

        let clusterBytes = UInt64(bytesPerCluster)

        // Resident-shrink path: simply slice the $DATA bytes and rewrite.
        if case let .resident(value, _) = dataAttr.value {
            let oldSize = UInt64(value.count)
            guard newSize <= oldSize else {
                throw NTFSError.unsupportedFeature(
                    description: "truncate: extending via truncate() not yet supported (use write())"
                )
            }
            let truncated = value.subdata(in: 0..<Int(newSize))
            try await write(at: recordNumber, offset: 0, bytes: truncated)
            return
        }

        // Non-resident, byte-precise shrink path: drop any extents past
        // ceil(newSize / clusterBytes), keep the rest, update realSize.
        // The trailing partial cluster (if newSize isn't cluster-aligned)
        // keeps its slack — the realSize bound stops reads at the right byte.
        let alignedClustersToKeep = (newSize + clusterBytes - 1) / clusterBytes
        if alignedClustersToKeep > 0 {
            try await shrinkNonResidentTo(
                recordNumber: recordNumber,
                dataAttr: dataAttr,
                newRealSize: newSize,
                keepClusters: alignedClustersToKeep
            )
            return
        }

        // Fall-through: original cluster-aligned path retained for the legacy
        // contract (cluster-aligned shrinks against non-resident $DATA).
        guard newSize % clusterBytes == 0 else {
            throw NTFSError.unsupportedFeature(
                description: "truncate: internal: cluster-aligned path reached with non-aligned newSize \(newSize)"
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

    /// Byte-precise non-resident truncate: keep the first `keepClusters`
    /// worth of extents, free the rest, set realSize/allocatedSize
    /// appropriately. The trailing partial cluster (when `newRealSize` isn't
    /// cluster-aligned) keeps its slack — reads stop at realSize.
    private func shrinkNonResidentTo(
        recordNumber: UInt64,
        dataAttr: Attribute,
        newRealSize: UInt64,
        keepClusters: UInt64
    ) async throws {
        guard case let .nonResident(_, _, _, _, _, _, _, extents) = dataAttr.value else {
            throw NTFSError.unsupportedFeature(description: "shrinkNonResidentTo: called on resident $DATA")
        }
        let clusterBytes = UInt64(bytesPerCluster)

        var keptExtents: [Extent] = []
        var clustersKept: UInt64 = 0
        var extentIdx = 0
        for extent in extents {
            if clustersKept >= keepClusters { break }
            let needed = keepClusters - clustersKept
            if extent.clusterCount <= needed {
                keptExtents.append(extent)
                clustersKept += extent.clusterCount
            } else {
                let trimmed = Extent(startLCN: extent.startLCN, clusterCount: needed)
                keptExtents.append(trimmed)
                if let lcn = extent.startLCN {
                    let toFree = Extent(startLCN: lcn + needed, clusterCount: extent.clusterCount - needed)
                    try await freeClusters(toFree)
                }
                clustersKept = keepClusters
            }
            extentIdx += 1
        }
        for extent in extents.suffix(from: extentIdx) {
            try await freeClusters(extent)
        }

        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        let allocatedSize = clustersKept * clusterBytes
        let newDataAttr = serializeNonResidentDataAttribute(
            attrID: dataAttr.header.attributeID,
            flags: dataAttr.header.flags,
            realSize: newRealSize,
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
                description: "rewriteEntireAttribute: new attribute (\(replacementBytes.count) bytes) would overflow record (used \(usedSize), record \(recordSize), type 0x\(String(replacingType, radix: 16, uppercase: true)))"
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

    /// v0.5 Fix B Step 3: matches BOTH overflow throw substrings used by
    /// `rewriteResidentAttribute` (Step A, $INDEX_ROOT) and
    /// `rewriteEntireAttribute` (Steps B/C, $INDEX_ALLOCATION / $BITMAP).
    /// The two helpers throw slightly different wording — we need to
    /// recognise either when wiring the $ATTRIBUTE_LIST migration into
    /// the leaf-split overflow catch sites.
    @inline(__always)
    fileprivate func isOverflowDescription(_ description: String) -> Bool {
        description.contains("would overflow parent record")
            || description.contains("would overflow record")
    }

    /// v0.5 Fix B Step 3: parse the `, type 0xHEX` suffix the two
    /// overflow throw messages now carry. Returns nil if the suffix is
    /// missing (older message format or a different throw site).
    fileprivate func overflowingAttributeType(from description: String) -> UInt32? {
        guard let range = description.range(of: ", type 0x") else { return nil }
        let after = description[range.upperBound...]
        // Hex digits run until the first non-hex char (typically ')' or end).
        var hex = ""
        for ch in after {
            if ch.isHexDigit { hex.append(ch) } else { break }
        }
        return UInt32(hex, radix: 16)
    }

    /// v0.5 Fix B Step 3: migrate the file's `$INDEX_ALLOCATION:$I30`
    /// attribute out of the base MFT record into a freshly-allocated
    /// extension record and add a resident `$ATTRIBUTE_LIST` to the
    /// base. This unblocks the v0.4 ~350-file directory cap by giving
    /// `rewriteParentForLeafSplit` slack to grow the `$INDEX_ALLOCATION`
    /// runlist (and the `$BITMAP:$I30` body) in place.
    ///
    /// Compute-first transactional: build BOTH the new base and new
    /// extension bytes via `AttributeMigration.buildIndexAllocationMigration`
    /// BEFORE the first `writeRawRecord`. The extension record is committed
    /// FIRST so a crash leaves an orphan slot rather than a dangling
    /// `$ATTRIBUTE_LIST` pointer; on any throw between `allocateMFTRecord`
    /// and the final base commit, the extension slot is freed via
    /// `reclaimOrphanedMFTRecord` and the error rethrown.
    ///
    /// `overflowDescription` is the error text that triggered the
    /// migration; we parse its `, type 0xHEX` suffix to discriminate
    /// which attribute overflowed. Only `$INDEX_ALLOCATION` (0xA0) is
    /// supported in v0.5; other types throw `unsupportedFeature` so the
    /// v0.4 cap holds for those.
    internal func migrateIndexAllocationOnOverflow(
        baseRecordNumber: UInt64,
        overflowDescription: String
    ) async throws {
        let mft = self.mft()

        // 1. Read the current base record so we can scan its attributes
        //    and feed the migration builder. `record(at:)` returns the
        //    post-fix-up bytes the builder expects.
        let baseRecord = try await mft.record(at: baseRecordNumber)
        let baseRecordBytes = baseRecord.bytes
        let baseSeq = baseRecord.sequenceNumber

        // 2. Discriminate which attribute overflowed.
        //    Prefer the `, type 0xHEX` suffix the throw messages now
        //    carry; fall back to assuming $INDEX_ALLOCATION since Step B
        //    is the user-reported `cp -r` cap trigger.
        let overflowingType: UInt32 = overflowingAttributeType(from: overflowDescription)
            ?? AttributeType.indexAllocation.rawValue
        guard overflowingType == AttributeType.indexAllocation.rawValue else {
            throw NTFSError.unsupportedFeature(
                description: "Fix B Step 3 migrate-X not yet implemented; attribute type 0x\(String(overflowingType, radix: 16, uppercase: true))"
            )
        }

        // 3. Allocate a fresh extension MFT record. From here until the
        //    final base commit, any throw must free this slot.
        let extRN = try await allocateMFTRecord()

        // The extension's sequence number follows the same recycling
        // discipline as `createFile`: bump the existing slot's sequence,
        // never zero.
        var extSeq: UInt16 = 1
        if let existing = try? await mft.record(at: extRN) {
            extSeq = existing.sequenceNumber &+ 1
            if extSeq == 0 { extSeq = 1 }
        }

        // 4. Pure compute step. If this throws (e.g. $ATTRIBUTE_LIST
        //    won't fit resident in the base record's slack — the v0.5+
        //    non-resident-$ATTRIBUTE_LIST cap), the extension slot must
        //    be released.
        let result: AttributeMigration.Result
        do {
            result = try AttributeMigration.buildIndexAllocationMigration(
                baseRecordBytes: baseRecordBytes,
                baseRN: baseRecordNumber,
                baseSeq: baseSeq,
                extRN: extRN,
                extSeq: extSeq,
                recordSize: Int(mftRecordSizeBytes),
                sectorSize: Int(boot.bytesPerSector)
            )
        } catch {
            try? await reclaimOrphanedMFTRecord(at: extRN)
            throw error
        }

        // 5. Commit the extension record FIRST. A crash between this
        //    and the base commit leaves an orphan extension slot — the
        //    base record's existing $INDEX_ALLOCATION still points at
        //    the original (untouched) clusters, so on next mount the
        //    file is intact and `reclaim-orphans` can sweep the slot.
        do {
            try await mft.writeRawRecord(at: extRN, postFixupBytes: result.newExtBytes)
        } catch {
            try? await reclaimOrphanedMFTRecord(at: extRN)
            throw error
        }

        // 6. Commit the new base record. If THIS fails after the
        //    extension is on disk, free the extension slot — the base
        //    still describes the original layout, so the extension is a
        //    leak we can safely reclaim.
        do {
            try await mft.writeRawRecord(at: baseRecordNumber, postFixupBytes: result.newBaseBytes)
        } catch {
            try? await reclaimOrphanedMFTRecord(at: extRN)
            throw error
        }

        // Drop any cached parses of the migrated base so callers re-read.
        invalidateMFTCaches()
    }

    /// Roll back an MFT record allocation by flipping IN_USE off. Used both
    /// internally (createFile's error handler when $I30 insert fails) and
    /// externally (the `ntfsctl reclaim-orphans` subcommand which sweeps
    /// pre-existing orphans left behind by older buggy builds).
    ///
    /// Doesn't free non-resident clusters — for a fresh createFile orphan
    /// the record is empty resident $DATA only. For reclaim-orphans use, the
    /// caller should already have decided this slot is safe to reclaim (no
    /// reachable $I30 entry pointing at it, no non-resident data the user
    /// wants to keep). Use `deleteFile` instead if the file IS reachable
    /// and you want full cluster + $I30 cleanup.
    public func reclaimOrphanedMFTRecord(at recordNumber: UInt64) async throws {
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
        // Mirror the free state in the $MFT $BITMAP. Best-effort: if no
        // bitmap exists (degenerate fixture), the linear-scan fallback will
        // still find the slot via IN_USE=0 on the next allocate.
        try? await freeMFTRecord(recordNumber)
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
        // Mirror the free state in the $MFT $BITMAP.
        try? await freeMFTRecord(recordNumber)
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
        let extent = try bm.allocate(count, startingAt: _allocHint)
        try await persistBitmap(bm)
        bm.clearDirty()
        _bitmap = bm
        advanceAllocHint(after: extent, clusterCount: bm.clusterCount)
        return extent
    }

    /// Advance the next-fit hint to the cluster immediately after the last one
    /// in `extent`, wrapping modulo `clusterCount`. No-op for sparse extents
    /// or a zero-cluster volume.
    private func advanceAllocHint(after extent: Extent, clusterCount: UInt64) {
        guard clusterCount > 0, let startLCN = extent.startLCN else { return }
        _allocHint = (startLCN + extent.clusterCount) % clusterCount
    }

    /// Free a previously-allocated extent and persist the updated $Bitmap.
    /// Deliberately does NOT rewind `_allocHint` toward the freed range:
    /// freeing is rare on the cp -r path, and rewinding would send the next
    /// allocation back to refill the just-freed holes — re-introducing exactly
    /// the fragmentation the next-fit hint exists to avoid.
    public func freeClusters(_ extent: Extent) async throws {
        var bm = try await bitmap()
        try bm.free(extent)
        try await persistBitmap(bm)
        bm.clearDirty()
        _bitmap = bm
    }

    /// Test-only accessor for the next-fit allocator hint. Not part of the
    /// public API contract — exposed `internal` for `@testable` assertions in
    /// AllocatorTests.
    internal func _currentAllocHintForTesting() -> UInt64 {
        _allocHint
    }

    /// Persist the in-memory Bitmap back to the on-disk $Bitmap attribute.
    /// Walks $Bitmap's $DATA extents and writes the corresponding bitmap
    /// bytes via `BlockDevice.write`. For a resident $Bitmap (a degenerate
    /// case that doesn't happen on real volumes since $Bitmap is always
    /// non-resident), we'd need to rewrite the MFT record — out of scope
    /// for stage 2.
    private func persistBitmap(_ bm: Bitmap) async throws {
        // v0.4 perf: only write the dirty byte range. On a 4 TB drive
        // bm.bytes is ~128 MB; rewriting all of it per allocate/free was
        // the dominant cost in cp -r (~5 sec per file on USB). With
        // dirty-range tracking from Bitmap, a single contiguous allocate
        // typically dirties just a few bytes, so we write under a sector
        // per call. Sector-align the write range so we don't issue
        // sub-sector writes (some block devices reject them).
        guard let dirtyRange = bm.dirtyByteRange else {
            return  // nothing dirty, nothing to write
        }

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
        let sectorBytes = UInt64(boot.bytesPerSector)
        // Round the dirty range down to a sector boundary at the start
        // and up to a sector boundary at the end — block writes must be
        // sector-aligned on raw devices.
        let alignedStart = Int((UInt64(dirtyRange.lowerBound) / sectorBytes) * sectorBytes)
        let endByte = UInt64(dirtyRange.upperBound)
        let alignedEndU64 = ((endByte + sectorBytes - 1) / sectorBytes) * sectorBytes
        let alignedEnd = Int(min(alignedEndU64, UInt64(bm.bytes.count)))
        let alignedRange = alignedStart..<alignedEnd
        guard !alignedRange.isEmpty else { return }

        // Walk the $Bitmap's $DATA extents until we hit the byte range we
        // need to write, then write the dirty bytes (potentially spanning
        // multiple extents on a fragmented volume).
        var byteCursor = 0
        for extent in extents {
            guard let startLCN = extent.startLCN else { continue }  // sparse
            let extentByteLen = Int(min(extent.clusterCount * clusterBytes, UInt64(bm.bytes.count - byteCursor)))
            let extentByteEnd = byteCursor + extentByteLen
            // Compute the intersection of this extent's byte range with
            // the aligned dirty range.
            let overlapStart = max(byteCursor, alignedRange.lowerBound)
            let overlapEnd = min(extentByteEnd, alignedRange.upperBound)
            if overlapStart < overlapEnd {
                let inExtentOffset = UInt64(overlapStart - byteCursor)
                let writeBytes = bm.bytes.subdata(in: bm.bytes.startIndex.advanced(by: overlapStart)..<bm.bytes.startIndex.advanced(by: overlapEnd))
                try await device.write(
                    offset: startLCN * clusterBytes + inExtentOffset,
                    bytes: writeBytes
                )
            }
            byteCursor = extentByteEnd
            if byteCursor >= alignedRange.upperBound { break }
        }
    }

    /// Rename or move a file/directory. Removes its current $I30 entry, updates
    /// the $FILE_NAME body (and parent reference if moving), writes the
    /// modified MFT record, and inserts a new $I30 entry under the new parent
    /// with the new name. Works against both resident and LARGE_INDEX parents
    /// (the existing insert path covers both). Refuses if the destination
    /// already exists or the source is a reserved record.
    public func rename(
        at recordNumber: UInt64,
        toName newName: String,
        inDirectory newParentRN: UInt64? = nil
    ) async throws {
        guard recordNumber >= MFT.firstUserRecord else {
            throw NTFSError.unsupportedFeature(description: "rename: refusing to mutate reserved MFT record \(recordNumber)")
        }
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        guard record.isInUse else {
            throw NTFSError.corruptOnDisk(description: "rename: source record \(recordNumber) is not in use")
        }
        let attrs = try record.attributes()
        guard let fnAttr = attrs.first(where: { $0.type == .fileName }),
              case let .resident(fnBytes, _) = fnAttr.value,
              let fn = try? FileName.parse(fnBytes) else {
            throw NTFSError.corruptOnDisk(description: "rename: source record \(recordNumber) missing $FILE_NAME")
        }
        let oldParentRN = fn.parentRecordNumber
        let oldName = fn.name
        let targetParentRN = newParentRN ?? oldParentRN

        // Refuse if destination name already exists.
        let destEntries = try await enumerate(directory: targetParentRN)
        if destEntries.contains(where: { $0.name == newName && $0.fileName.namespace != .dos }) {
            throw NTFSError.unsupportedFeature(description: "rename: destination '\(newName)' already exists in parent \(targetParentRN)")
        }

        // 1. Remove from old parent.
        try await removeFromParentI30(parentRecordNumber: oldParentRN, childFileName: oldName)

        // 2. Update the file's $FILE_NAME body with the new name + parent reference.
        let parentRec = try await mft.record(at: targetParentRN)
        let newParentRef = (UInt64(parentRec.sequenceNumber) << 48) | (targetParentRN & 0x0000_FFFF_FFFF_FFFF)
        let newFileNameBody = buildRenamedFileNameBody(
            from: fn,
            newName: newName,
            newParentReference: newParentRef
        )
        let newFNAttrBytes = serializeFileNameAttribute(
            attrID: fnAttr.header.attributeID,
            flags: fnAttr.header.flags,
            body: newFileNameBody
        )
        let updatedRecordBytes = try rewriteEntireAttribute(
            in: record.bytes,
            firstAttributeOffset: Int(record.firstAttributeOffset),
            usedSize: Int(record.usedSize),
            recordSize: Int(record.allocatedSize),
            replacingType: AttributeType.fileName.rawValue,
            attributeName: "",
            replacementBytes: newFNAttrBytes
        )
        guard let mark = locateEndMarker(in: updatedRecordBytes, fromOffset: Int(record.firstAttributeOffset)) else {
            throw NTFSError.corruptOnDisk(description: "rename: rewritten record missing end marker")
        }
        var finalBytes = updatedRecordBytes
        MFTRecord.writeU32LE(into: &finalBytes, at: 24, value: UInt32(mark + 4))
        try await mft.writeRawRecord(at: recordNumber, postFixupBytes: finalBytes)

        // 3. Insert new $I30 entry under the target parent.
        try await insertIntoParentI30(
            parentRecordNumber: targetParentRN,
            childRecordNumber: recordNumber,
            childSequence: record.sequenceNumber,
            childFileName: newName,
            isDirectory: record.isDirectory,
            nowFiletime: MFTRecordBuilder.windowsFiletimeNow()
        )
    }

    /// Build a $FILE_NAME body with the same attributes as `from` but using
    /// `newName` and `newParentReference`. Time fields preserved (mtime
    /// is conceptually unchanged by a rename in NTFS semantics).
    private func buildRenamedFileNameBody(
        from fn: FileName,
        newName: String,
        newParentReference: UInt64
    ) -> Data {
        let nameUTF16 = Array(newName.utf16)
        let nameByteCount = nameUTF16.count * 2
        var data = Data(count: 66 + nameByteCount)
        MFTRecord.writeU64LE(into: &data, at: 0,  value: newParentReference)
        MFTRecord.writeU64LE(into: &data, at: 8,  value: filetimeFromDate(fn.creationTime))
        MFTRecord.writeU64LE(into: &data, at: 16, value: filetimeFromDate(fn.modificationTime))
        MFTRecord.writeU64LE(into: &data, at: 24, value: filetimeFromDate(fn.mftChangeTime))
        MFTRecord.writeU64LE(into: &data, at: 32, value: filetimeFromDate(fn.accessTime))
        MFTRecord.writeU64LE(into: &data, at: 40, value: fn.allocatedSize)
        MFTRecord.writeU64LE(into: &data, at: 48, value: fn.realSize)
        MFTRecord.writeU32LE(into: &data, at: 56, value: fn.fileAttributes)
        MFTRecord.writeU32LE(into: &data, at: 60, value: 0)
        data[64] = UInt8(nameUTF16.count)
        data[65] = 1   // Win32 namespace
        for (i, codeUnit) in nameUTF16.enumerated() {
            data[66 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[66 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        return data
    }

    /// Wrap a $FILE_NAME body in a resident attribute header.
    private func serializeFileNameAttribute(attrID: UInt16, flags: UInt16, body: Data) -> Data {
        serializeResidentAttribute(
            type: AttributeType.fileName.rawValue,
            attrID: attrID,
            flags: flags,
            attributeName: "",
            value: body
        )
    }

    /// Resolve a slash-separated path under the volume root to its MFT
    /// record number. Returns nil if any component is missing. Leading and
    /// trailing slashes are tolerated; "/" / "" / "." all resolve to root (5).
    ///
    /// Case-insensitive on ASCII (matches Windows NTFS semantics). DOS-namespace
    /// aliases are skipped so the Win32 long name is the canonical match.
    public func resolvePath(_ path: String) async throws -> UInt64? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "." { return 5 }
        var current: UInt64 = 5
        for component in trimmed.split(separator: "/") {
            let needle = String(component).lowercased()
            let entries = try await enumerate(directory: current)
            let match = entries.first {
                $0.fileName.namespace != .dos &&
                $0.name.lowercased() == needle
            }
            guard let m = match else { return nil }
            current = m.recordNumber
        }
        return current
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

        let attrs = try await allAttributesOf(recordNumber: recordNumber)
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
