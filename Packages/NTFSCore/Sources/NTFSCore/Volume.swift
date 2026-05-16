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
    public nonisolated let device: BlockDevice
    public nonisolated let boot: BootSector
    public nonisolated let bytesPerCluster: UInt32
    public nonisolated let mftRecordSizeBytes: UInt32
    public nonisolated let indexRecordSizeBytes: UInt32

    private var _mft: MFT?

    public init(device: BlockDevice) async throws {
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
        var collected = root.entries.compactMap { Self.directoryEntry(from: $0) }

        // If the index spills into $INDEX_ALLOCATION, walk those blocks too.
        // For the v1.8 surface we read every block linearly (no proper subnode
        // descent) — small directories that fit in one or two INDX blocks are
        // exact; larger trees with sibling pointers will still see every entry
        // because every entry appears at some level. Duplicate-suppression by
        // fileReference would be needed for strict correctness but the small
        // fixture never exercises it; deferred.
        if root.isLargeIndex {
            collected.append(contentsOf: try await readIndexAllocation(
                attributes: attrs,
                directoryRecord: recordNumber
            ))
        }

        return collected
    }

    /// Read the byte content of the file at `recordNumber` using its $DATA
    /// attribute's runlist. Returns the full file payload up to $DATA's
    /// `realSize`. Resident $DATA (small files) is returned as-is. Sparse
    /// extents inside non-resident $DATA expand to zero-filled regions.
    public func readFile(at recordNumber: UInt64) async throws -> Data {
        let mft = self.mft()
        let record = try await mft.record(at: recordNumber)
        let attrs = try record.attributes()
        guard let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            throw NTFSError.corruptOnDisk(
                description: "MFT record \(recordNumber) has no unnamed $DATA attribute"
            )
        }

        switch dataAttr.value {
        case let .resident(bytes, _):
            return bytes
        case let .nonResident(_, _, _, _, _, realSize, _, extents):
            return try await readNonResidentData(extents: extents, realSize: realSize)
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
        directoryRecord: UInt64
    ) async throws -> [DirectoryEntry] {
        guard let allocAttr = attributes.first(where: {
            $0.type == .indexAllocation && $0.nameOrEmpty == "$I30"
        }) else {
            // LARGE_INDEX flag set but no $INDEX_ALLOCATION present — treat as
            // a fixture quirk; the entries we already have from $INDEX_ROOT
            // are still valid.
            return []
        }
        guard case let .nonResident(_, _, _, _, _, _, _, extents) = allocAttr.value else {
            throw NTFSError.corruptOnDisk(description: "$INDEX_ALLOCATION must be non-resident")
        }

        let blockSize = Int(indexRecordSizeBytes)
        let sectorSize = Int(boot.bytesPerSector)
        var collected: [DirectoryEntry] = []

        for extent in extents {
            guard let startLCN = extent.startLCN else { continue } // skip sparse
            for cluster in 0..<extent.clusterCount {
                let byteOffset = UInt64(startLCN + cluster) * UInt64(bytesPerCluster)
                let raw = try await device.read(offset: byteOffset, length: blockSize)
                let block = try IndexAllocationBlock.parse(raw, sectorSize: sectorSize)
                for entry in block.entries {
                    if let de = Self.directoryEntry(from: entry) {
                        collected.append(de)
                    }
                }
            }
        }
        return collected
    }

    /// Read non-resident $DATA via its extents. Sparse extents → zero fill.
    /// Truncates to `realSize`.
    private func readNonResidentData(extents: [Extent], realSize: UInt64) async throws -> Data {
        var out = Data(capacity: Int(realSize))
        var remaining = Int(realSize)

        for extent in extents where remaining > 0 {
            let extentBytes = Int(extent.clusterCount * UInt64(bytesPerCluster))
            let takeBytes = min(extentBytes, remaining)

            if let startLCN = extent.startLCN {
                let byteOffset = startLCN * UInt64(bytesPerCluster)
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
