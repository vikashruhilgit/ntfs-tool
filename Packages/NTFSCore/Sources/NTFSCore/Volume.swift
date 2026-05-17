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
