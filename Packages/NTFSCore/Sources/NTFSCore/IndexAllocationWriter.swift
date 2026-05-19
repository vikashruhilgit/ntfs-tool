import Foundation

// Insert / remove entries inside an existing $INDEX_ALLOCATION leaf (LARGE_INDEX
// directories). Strict B-tree descent: walk from $INDEX_ROOT down via subnode
// pointers, find the leaf where the new key belongs, and rewrite that leaf
// in place if it has room.
//
// Scope (v1):
//  - Insert into a leaf that already has enough slack for the new entry.
//  - Remove from a leaf when an entry matching `name` is found.
//
// Out of scope (rejected with `unsupportedFeature`):
//  - Leaf splits when the target leaf is full. A real implementation needs to
//    propagate the median key up the tree, possibly growing $INDEX_ROOT.
//  - Interior-node rewrites (no insert into an interior node — those carry
//    only subnode pointers + median keys that mirror the leaves below).
//
// All B-tree descent here works directly on raw bytes (not via IndexEntry)
// because the parsed IndexEntry struct drops the LAST sentinel, and the LAST
// sentinel's subnode VCN is the rightmost-subtree pointer we need.
/// v0.4 Phase 2: in-memory leaf cache for bulk-insert mode.
///
/// During `cp -r`, dozens of consecutive `insert` calls land in the same
/// INDX leaf — without caching, each one reads + parses + rewrites the
/// 4 KiB leaf to disk. The cache holds parsed leaf state across calls;
/// disk writes are deferred until `flushAll` runs at the end of the
/// bulk-insert window. ~Nx fewer disk writes per leaf.
///
/// Owned by `Volume` actor; reference-typed so it can be passed by value
/// into the non-isolated `IndexAllocationWriter.insert` static while
/// preserving in-place mutation semantics. Actor isolation guarantees
/// single-task access — `@unchecked Sendable` is appropriate because
/// the cache is only ever touched from within the owning Volume's actor
/// context (any concurrent bulk insert would violate `beginBulkInsert`'s
/// nesting guard before ever reaching the cache).
final class BulkLeafCache: @unchecked Sendable {
    struct LeafState {
        /// Non-LAST entries currently in this leaf (in memory, post-merge).
        var entries: [(fileRef: UInt64, body: Data, sortKey: String)]
        /// Where the leaf lives on disk.
        let byteOffset: UInt64
        /// USA-applied source bytes of the leaf as we first read it.
        /// `buildLeafIndexBlock` needs this to preserve headers + USA layout.
        let sourceBlockBytes: Data
        let blockSize: Int
        let sectorSize: Int
        let entriesOffsetWithinHeader: Int
        let allocatedSizeWithinHeader: Int
        var dirty: Bool
    }

    private var leaves: [UInt64: LeafState] = [:]

    /// Number of dirty leaves flushed across `flushAll` calls in this session.
    /// Diagnostic counter for tests.
    private(set) var totalDirtyLeavesFlushed: Int = 0
    /// Number of times a cache lookup served an insert without a disk read.
    /// Diagnostic counter for tests.
    private(set) var cacheHits: Int = 0

    func lookup(vcn: UInt64) -> LeafState? {
        if leaves[vcn] != nil { cacheHits += 1 }
        return leaves[vcn]
    }

    func record(vcn: UInt64, state: LeafState) {
        leaves[vcn] = state
    }

    /// Write a single leaf to disk and drop it from the cache. Called
    /// immediately before a split fires so the split path can read the
    /// up-to-date pre-split state from disk.
    func flushOne(vcn: UInt64, device: any BlockDevice) async throws {
        guard let state = leaves.removeValue(forKey: vcn) else { return }
        if !state.dirty { return }
        try await writeState(state, device: device)
        totalDirtyLeavesFlushed += 1
    }

    /// Write all dirty leaves to disk and clear the cache. Called from
    /// `Volume.endBulkInsert`.
    @discardableResult
    func flushAll(device: any BlockDevice) async throws -> Int {
        var written = 0
        for (_, state) in leaves where state.dirty {
            try await writeState(state, device: device)
            written += 1
        }
        leaves.removeAll(keepingCapacity: false)
        totalDirtyLeavesFlushed += written
        return written
    }

    private func writeState(_ state: LeafState, device: any BlockDevice) async throws {
        let newBlock = try IndexAllocationWriter.buildLeafIndexBlock(
            sourceBlockBytes: state.sourceBlockBytes,
            sortedEntries: state.entries.map { ($0.fileRef, $0.body, $0.sortKey) },
            blockSize: state.blockSize
        )
        let usaOffset = try newBlock.readU16LE(at: 4)
        let usaCount = try newBlock.readU16LE(at: 6)
        let onDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: newBlock,
            usaOffset: Int(usaOffset),
            usaCount: Int(usaCount),
            blockSize: state.sectorSize
        )
        try await device.write(offset: state.byteOffset, bytes: onDisk)
    }

    /// Test/diagnostic: number of leaves currently cached.
    var cachedLeafCount: Int { leaves.count }
}

struct IndexAllocationWriter {

    enum InsertOutcome {
        case inserted
        /// Leaf has no slack — caller decides whether to split. Carries
        /// everything the caller needs to perform a split:
        /// - `leafVCN` / `leafByteOffset`: where the existing leaf lives
        /// - `mergedSortedEntries`: original leaf entries + new entry, sorted
        /// - `usedSize`/`allocatedSize`/`needed`: for diagnostic reporting
        case leafFull(
            leafVCN: UInt64,
            leafByteOffset: UInt64,
            usedSize: Int,
            allocatedSize: Int,
            needed: Int,
            mergedSortedEntries: [(fileRef: UInt64, body: Data, sortKey: String)]
        )
    }

    /// One parsed entry inside an index node, INCLUDING the LAST sentinel.
    private struct RawEntry {
        let fileReference: UInt64
        let entryLength: Int
        let keyLength: Int
        let flags: UInt16  // bit 0 = HAS_SUBNODE, bit 1 = LAST
        let keyBytes: Data  // empty for LAST sentinel
        let keyName: String?  // parsed file name for non-LAST entries
        let subnodeVCN: UInt64?  // present when (flags & 0x01) != 0

        var isLast: Bool { (flags & 0x02) != 0 }
        var hasSubnode: Bool { (flags & 0x01) != 0 }
    }

    /// Walk all entries (including LAST) in a node starting at `cursor` in
    /// `data`, stopping at the LAST sentinel or `limit`.
    private static func parseEntries(in data: Data, start: Int, limit: Int) throws -> [RawEntry] {
        var entries: [RawEntry] = []
        var pos = start
        let end = min(limit, data.count)

        while pos + 16 <= end {
            let fileRef = try data.readU64LE(at: pos + 0)
            let entryLength = Int(try data.readU16LE(at: pos + 8))
            let keyLength = Int(try data.readU16LE(at: pos + 10))
            let flags = try data.readU16LE(at: pos + 12)
            guard entryLength >= 16, pos + entryLength <= end else {
                throw NTFSError.corruptOnDisk(description: "INDEX_ENTRY at \(pos) malformed (len \(entryLength))")
            }

            let isLast = (flags & 0x02) != 0
            let hasSubnode = (flags & 0x01) != 0

            var keyBytes = Data()
            var keyName: String?
            if !isLast && keyLength > 0 {
                let keyStart = pos + 16
                let keyEnd = keyStart + keyLength
                keyBytes = Data(data[(data.startIndex + keyStart)..<(data.startIndex + keyEnd)])
                if let fn = try? FileName.parse(keyBytes) {
                    keyName = fn.name
                }
            }

            var subnodeVCN: UInt64?
            if hasSubnode {
                let vcnOffset = pos + entryLength - 8
                guard vcnOffset >= pos + 16 else {
                    throw NTFSError.corruptOnDisk(description: "INDEX_ENTRY subnode VCN at \(vcnOffset) overlaps header")
                }
                subnodeVCN = try data.readU64LE(at: vcnOffset)
            }

            entries.append(RawEntry(
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

    /// Locate the leaf INDX block where `newSortKey` would land, and try to
    /// insert the new entry there. On success, writes the modified INDX block
    /// back to the device with USA reverse-fix-up.
    static func insert(
        rootBody: Data,
        allocationExtents: [Extent],
        indexRecordSizeBytes: UInt32,
        bytesPerCluster: UInt32,
        sectorSize: Int,
        device: any BlockDevice,
        newSortKey: String,
        newEntryFileRef: UInt64,
        newEntryBody: Data,
        leafCache: BulkLeafCache? = nil
    ) async throws -> InsertOutcome {
        // Walk $INDEX_ROOT first.
        let rootHeader = try IndexRoot.parse(rootBody)
        guard rootHeader.isLargeIndex else {
            throw NTFSError.corruptOnDisk(description: "insert called on non-LARGE_INDEX root")
        }
        // Entries inside $INDEX_ROOT start at offset 16 (header preamble)
        // + 16 (INDEX_HEADER) + entriesOffset, where entriesOffset is
        // relative to INDEX_HEADER start (offset 16).
        let rootEntriesStart = 16 + Int(rootHeader.header.entriesOffset)
        let rootEntriesEnd = 16 + Int(rootHeader.header.usedSize)
        let rootEntries = try parseEntries(in: rootBody, start: rootEntriesStart, limit: rootEntriesEnd)

        // From $INDEX_ROOT, descend via the first entry whose key sorts
        // >= newSortKey (or LAST sentinel's subnode for greater-than-all).
        let subnodeVCN: UInt64? = pickSubnode(from: rootEntries, for: newSortKey)
        guard let firstSubnode = subnodeVCN else {
            throw NTFSError.unsupportedFeature(
                description: "LARGE_INDEX root has no subnode pointers — degenerate tree shape, refusing to insert"
            )
        }

        // Descend: at each level read the INDX block, decide whether it's a
        // leaf or interior, and either insert or descend.
        var currentVCN = firstSubnode
        let blockSize = Int(indexRecordSizeBytes)
        let clusterBytes = UInt64(bytesPerCluster)

        while true {
            let byteOffset = try vcnToByteOffset(vcn: currentVCN, extents: allocationExtents, clusterBytes: clusterBytes)
            let rawBlock = try await device.read(offset: byteOffset, length: blockSize)
            // Apply USA fix-up so we can read the entries.
            let usaOffset = try rawBlock.readU16LE(at: 4)
            let usaCount = try rawBlock.readU16LE(at: 6)
            let fixed = try UpdateSequenceArray.applyFixup(
                recordBytes: rawBlock,
                usaOffset: Int(usaOffset),
                usaCount: Int(usaCount),
                blockSize: sectorSize
            )
            // INDEX_HEADER starts at offset 24 in the block. Its fields:
            //   entriesOffset (relative to INDEX_HEADER start)
            //   usedSize      (relative to INDEX_HEADER start)
            //   allocatedSize (relative to INDEX_HEADER start)
            let entriesOffsetWithinHeader = try fixed.readU32LE(at: 24)
            let usedSizeWithinHeader = try fixed.readU32LE(at: 28)
            let allocatedSizeWithinHeader = try fixed.readU32LE(at: 32)
            let entriesStart = 24 + Int(entriesOffsetWithinHeader)
            let entriesEnd = 24 + Int(usedSizeWithinHeader)
            let blockEntries = try parseEntries(in: fixed, start: entriesStart, limit: entriesEnd)

            // Interior if any entry has HAS_SUBNODE (this includes the LAST
            // sentinel in the entries list).
            let isInterior = blockEntries.contains(where: { $0.hasSubnode })
            if isInterior {
                guard let next = pickSubnode(from: blockEntries, for: newSortKey) else {
                    throw NTFSError.corruptOnDisk(description: "interior INDX block at VCN \(currentVCN) has HAS_SUBNODE entries but pickSubnode returned nil")
                }
                currentVCN = next
                continue
            }

            // Leaf — try to insert here.
            return try await insertIntoLeaf(
                blockVCN: currentVCN,
                blockBytesFixedUp: fixed,
                blockSize: blockSize,
                sectorSize: sectorSize,
                entriesOffsetWithinHeader: Int(entriesOffsetWithinHeader),
                allocatedSizeWithinHeader: Int(allocatedSizeWithinHeader),
                usedSizeWithinHeader: Int(usedSizeWithinHeader),
                allocationExtents: allocationExtents,
                clusterBytes: clusterBytes,
                device: device,
                newSortKey: newSortKey,
                newEntryFileRef: newEntryFileRef,
                newEntryBody: newEntryBody,
                leafCache: leafCache
            )
        }
    }

    /// Update the keyBytes of an entry matching `targetName` in whichever
    /// leaf it lives. Used by `Volume.refreshParentI30Size` to patch stale
    /// `$FILE_NAME` size hints after a write. The new keyBytes must have
    /// the same length as the old (caller's responsibility — for size-hint
    /// updates this is naturally true since name + namespace are unchanged).
    /// Returns true if updated, false if not found.
    static func updateEntry(
        rootBody: Data,
        allocationExtents: [Extent],
        indexRecordSizeBytes: UInt32,
        bytesPerCluster: UInt32,
        sectorSize: Int,
        device: any BlockDevice,
        targetName: String,
        newKeyBytes: Data
    ) async throws -> Bool {
        let root = try IndexRoot.parse(rootBody)
        guard root.isLargeIndex else {
            throw NTFSError.corruptOnDisk(description: "updateEntry called on non-LARGE_INDEX root")
        }
        let clusterBytes = UInt64(bytesPerCluster)
        let blockSize = Int(indexRecordSizeBytes)
        let clustersPerBlock = max(UInt64(1), UInt64(blockSize) / clusterBytes)

        for extent in allocationExtents {
            guard let startLCN = extent.startLCN else { continue }
            var cluster: UInt64 = 0
            while cluster < extent.clusterCount {
                let lcn = startLCN + cluster
                let byteOffset = lcn * clusterBytes
                let raw = try await device.read(offset: byteOffset, length: blockSize)
                let usaOffset = try raw.readU16LE(at: 4)
                let usaCount = try raw.readU16LE(at: 6)
                let fixed = try UpdateSequenceArray.applyFixup(
                    recordBytes: raw,
                    usaOffset: Int(usaOffset),
                    usaCount: Int(usaCount),
                    blockSize: sectorSize
                )
                let entriesOffsetWithinHeader = try fixed.readU32LE(at: 24)
                let usedSizeWithinHeader = try fixed.readU32LE(at: 28)
                let entriesStart = 24 + Int(entriesOffsetWithinHeader)
                let entriesEnd = 24 + Int(usedSizeWithinHeader)
                let entries = try parseEntries(in: fixed, start: entriesStart, limit: entriesEnd)
                // Only rewrite leaf nodes — interior entries replicate the
                // key from a leaf below; touching the interior copy without
                // the leaf would unbalance the tree's representation.
                let isInterior = entries.contains(where: { $0.hasSubnode })
                if !isInterior, let match = entries.first(where: { $0.keyName == targetName }) {
                    guard match.keyBytes.count == newKeyBytes.count else {
                        // Different length means the entry's size on disk
                        // changes, which can shift everything after it.
                        // For the size-hint refresh use case lengths are
                        // identical; reject any mismatch as a safety guard.
                        throw NTFSError.unsupportedFeature(
                            description: "updateEntry: new keyBytes length \(newKeyBytes.count) != existing \(match.keyBytes.count) — variable-length updates not supported"
                        )
                    }
                    // Rebuild this leaf with the patched entry.
                    var kept: [(UInt64, Data, String)] = []
                    for e in entries where !e.isLast {
                        if e.keyName == targetName {
                            kept.append((e.fileReference, newKeyBytes, e.keyName ?? ""))
                        } else {
                            kept.append((e.fileReference, e.keyBytes, e.keyName ?? ""))
                        }
                    }
                    let newBlock = try buildLeafIndexBlock(
                        sourceBlockBytes: fixed,
                        sortedEntries: kept,
                        blockSize: blockSize
                    )
                    let outUsaOffset = try newBlock.readU16LE(at: 4)
                    let outUsaCount = try newBlock.readU16LE(at: 6)
                    let onDisk = try UpdateSequenceArray.reverseFixup(
                        recordBytes: newBlock,
                        usaOffset: Int(outUsaOffset),
                        usaCount: Int(outUsaCount),
                        blockSize: sectorSize
                    )
                    try await device.write(offset: byteOffset, bytes: onDisk)
                    return true
                }
                cluster += clustersPerBlock
            }
        }
        return false
    }

    /// Remove an entry matching `targetName` from wherever it lives. Returns
    /// true if removed, false if not found. Walks every INDX block linearly
    /// (matches the read path) — only mutates leaf blocks (interior copies
    /// of the key would unbalance the tree if removed).
    static func remove(
        rootBody: Data,
        allocationExtents: [Extent],
        indexRecordSizeBytes: UInt32,
        bytesPerCluster: UInt32,
        sectorSize: Int,
        device: any BlockDevice,
        targetName: String
    ) async throws -> Bool {
        let root = try IndexRoot.parse(rootBody)
        guard root.isLargeIndex else {
            throw NTFSError.corruptOnDisk(description: "remove called on non-LARGE_INDEX root")
        }
        let clusterBytes = UInt64(bytesPerCluster)
        let blockSize = Int(indexRecordSizeBytes)
        let clustersPerBlock = max(UInt64(1), UInt64(blockSize) / clusterBytes)

        for extent in allocationExtents {
            guard let startLCN = extent.startLCN else { continue }
            var cluster: UInt64 = 0
            while cluster < extent.clusterCount {
                let lcn = startLCN + cluster
                let byteOffset = lcn * clusterBytes
                let raw = try await device.read(offset: byteOffset, length: blockSize)
                let usaOffset = try raw.readU16LE(at: 4)
                let usaCount = try raw.readU16LE(at: 6)
                let fixed = try UpdateSequenceArray.applyFixup(
                    recordBytes: raw,
                    usaOffset: Int(usaOffset),
                    usaCount: Int(usaCount),
                    blockSize: sectorSize
                )
                let entriesOffsetWithinHeader = try fixed.readU32LE(at: 24)
                let usedSizeWithinHeader = try fixed.readU32LE(at: 28)
                let entriesStart = 24 + Int(entriesOffsetWithinHeader)
                let entriesEnd = 24 + Int(usedSizeWithinHeader)
                let entries = try parseEntries(in: fixed, start: entriesStart, limit: entriesEnd)
                let isInterior = entries.contains(where: { $0.hasSubnode })
                if !isInterior, entries.contains(where: { $0.keyName == targetName }) {
                    // Rebuild without the target.
                    var kept: [(UInt64, Data, String)] = []
                    for e in entries where !e.isLast {
                        if e.keyName == targetName { continue }
                        kept.append((e.fileReference, e.keyBytes, e.keyName ?? ""))
                    }
                    let newBlock = try buildLeafIndexBlock(
                        sourceBlockBytes: fixed,
                        sortedEntries: kept,
                        blockSize: blockSize
                    )
                    let outUsaOffset = try newBlock.readU16LE(at: 4)
                    let outUsaCount = try newBlock.readU16LE(at: 6)
                    let onDisk = try UpdateSequenceArray.reverseFixup(
                        recordBytes: newBlock,
                        usaOffset: Int(outUsaOffset),
                        usaCount: Int(outUsaCount),
                        blockSize: sectorSize
                    )
                    try await device.write(offset: byteOffset, bytes: onDisk)
                    return true
                }
                cluster += clustersPerBlock
            }
        }
        return false
    }

    /// Pick the subnode to descend into. For each entry in order: if the key
    /// sorts AFTER newSortKey, descend that entry's subnode (left subtree of
    /// that key). Reaching the LAST sentinel without finding one means newSortKey
    /// is greater than every key — descend the LAST sentinel's subnode (rightmost).
    private static func pickSubnode(from entries: [RawEntry], for newSortKey: String) -> UInt64? {
        for entry in entries {
            if entry.isLast {
                return entry.subnodeVCN  // rightmost subtree (or nil if leaf)
            }
            // entry.keyName sorts BEFORE newSortKey means newSortKey is to the right of this key.
            // Look for first entry whose key sorts AT-OR-AFTER newSortKey.
            if let kn = entry.keyName,
               !IndexBuilder.collationFilenameSortsBefore(kn, newSortKey) {
                return entry.subnodeVCN  // descend left of this key
            }
        }
        return nil
    }

    /// Map a VCN (cluster units) to an absolute byte offset using the
    /// $INDEX_ALLOCATION runlist.
    private static func vcnToByteOffset(vcn: UInt64, extents: [Extent], clusterBytes: UInt64) throws -> UInt64 {
        var cumulative: UInt64 = 0
        for extent in extents {
            if vcn < cumulative + extent.clusterCount {
                let clusterInExtent = vcn - cumulative
                guard let startLCN = extent.startLCN else {
                    throw NTFSError.corruptOnDisk(description: "vcnToByteOffset: sparse extent at VCN \(vcn)")
                }
                return (startLCN + clusterInExtent) * clusterBytes
            }
            cumulative += extent.clusterCount
        }
        throw NTFSError.corruptOnDisk(description: "vcnToByteOffset: VCN \(vcn) past end of allocation (\(cumulative) clusters)")
    }

    private static func insertIntoLeaf(
        blockVCN: UInt64,
        blockBytesFixedUp fixed: Data,
        blockSize: Int,
        sectorSize: Int,
        entriesOffsetWithinHeader: Int,
        allocatedSizeWithinHeader: Int,
        usedSizeWithinHeader: Int,
        allocationExtents: [Extent],
        clusterBytes: UInt64,
        device: any BlockDevice,
        newSortKey: String,
        newEntryFileRef: UInt64,
        newEntryBody: Data,
        leafCache: BulkLeafCache?
    ) async throws -> InsertOutcome {
        // v0.4 Phase 2: when a leaf cache is active, prefer the cached
        // entry list over re-parsing from disk bytes — prior inserts in
        // this bulk window have already mutated the in-memory state but
        // not yet flushed it to disk. The first insert against a leaf
        // still parses from `fixed` (the disk read that descent just did)
        // and SEEDS the cache for subsequent inserts.
        var merged: [(UInt64, Data, String)] = []
        let cachedState: BulkLeafCache.LeafState? = leafCache?.lookup(vcn: blockVCN)
        if let cached = cachedState {
            for e in cached.entries {
                merged.append((e.fileRef, e.body, e.sortKey))
            }
        } else {
            let entriesStart = 24 + entriesOffsetWithinHeader
            let entriesEnd = 24 + usedSizeWithinHeader
            let leafEntries = try parseEntries(in: fixed, start: entriesStart, limit: entriesEnd)
            for e in leafEntries where !e.isLast {
                merged.append((e.fileReference, e.keyBytes, e.keyName ?? ""))
            }
        }
        merged.append((newEntryFileRef, newEntryBody, newSortKey))
        merged.sort { IndexBuilder.collationFilenameSortsBefore($0.2, $1.2) }

        // Compute needed bytes.
        let entryBytes = merged.reduce(0) { acc, e in
            let rawLen = 16 + e.1.count
            return acc + ((rawLen + 7) / 8) * 8
        } + 16 // LAST sentinel
        let neededUsedSize = entriesOffsetWithinHeader + entryBytes
        let byteOffset = try vcnToByteOffset(vcn: blockVCN, extents: allocationExtents, clusterBytes: clusterBytes)
        if neededUsedSize > allocatedSizeWithinHeader {
            // Leaf full — caller will split. Flush cached state for this
            // VCN (if any) so the split path reads up-to-date pre-split
            // entries from disk. After flush, drop the cache entry — the
            // split is going to rewrite this leaf to its left-half anyway.
            if let cache = leafCache, cachedState != nil {
                try await cache.flushOne(vcn: blockVCN, device: device)
            }
            return .leafFull(
                leafVCN: blockVCN,
                leafByteOffset: byteOffset,
                usedSize: usedSizeWithinHeader,
                allocatedSize: allocatedSizeWithinHeader,
                needed: neededUsedSize,
                mergedSortedEntries: merged.map { (fileRef: $0.0, body: $0.1, sortKey: $0.2) }
            )
        }

        if let cache = leafCache {
            // Cache path: update in-memory entries, mark dirty, defer write.
            // First-touch seeds the cache with `fixed` (the USA-applied source
            // bytes) so `flushAll` can reproduce headers + USA layout via
            // buildLeafIndexBlock. Subsequent updates keep the same
            // sourceBlockBytes since headers don't change on simple inserts.
            let sourceBytes = cachedState?.sourceBlockBytes ?? fixed
            let newState = BulkLeafCache.LeafState(
                entries: merged.map { (fileRef: $0.0, body: $0.1, sortKey: $0.2) },
                byteOffset: byteOffset,
                sourceBlockBytes: sourceBytes,
                blockSize: blockSize,
                sectorSize: sectorSize,
                entriesOffsetWithinHeader: entriesOffsetWithinHeader,
                allocatedSizeWithinHeader: allocatedSizeWithinHeader,
                dirty: true
            )
            cache.record(vcn: blockVCN, state: newState)
            return .inserted
        }

        // No cache — original path: build and write to disk immediately.
        let newBlock = try buildLeafIndexBlock(
            sourceBlockBytes: fixed,
            sortedEntries: merged,
            blockSize: blockSize
        )
        let outUsaOffset = try newBlock.readU16LE(at: 4)
        let outUsaCount = try newBlock.readU16LE(at: 6)
        let onDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: newBlock,
            usaOffset: Int(outUsaOffset),
            usaCount: Int(outUsaCount),
            blockSize: sectorSize
        )
        try await device.write(offset: byteOffset, bytes: onDisk)
        return .inserted
    }

    /// Construct a fresh INDX block (post-USA, ready to feed reverseFixup).
    /// Preserves the source block's magic, USA layout, LSN, VCN and INDEX_HEADER
    /// metadata (incl. allocatedSize); replaces the entries list and updates
    /// usedSize.
    static func buildLeafIndexBlock(
        sourceBlockBytes raw: Data,
        sortedEntries: [(UInt64, Data, String)],
        blockSize: Int
    ) throws -> Data {
        var out = Data(count: blockSize)
        // Copy first 40 bytes (magic, USA offset/count, LSN, VCN, INDEX_HEADER preamble).
        for i in 0..<min(40, raw.count) {
            out[out.startIndex + i] = raw[raw.startIndex + i]
        }
        // Copy USA region verbatim (sentinel + fix-up slots). reverseFixup will
        // freshen sentinel + fix-ups on the write path.
        let usaOffset = Int(try raw.readU16LE(at: 4))
        let usaCount = Int(try raw.readU16LE(at: 6))
        for i in 0..<(usaCount * 2) {
            out[out.startIndex + usaOffset + i] = raw[raw.startIndex + usaOffset + i]
        }

        // Serialize entries followed by LAST sentinel.
        var entriesBytes = Data()
        for entry in sortedEntries {
            entriesBytes.append(IndexBuilder.serializeEntry(fileReference: entry.0, fileNameBody: entry.1))
        }
        entriesBytes.append(IndexBuilder.serializeLastSentinel())

        let entriesOffsetWithinHeader = Int(try raw.readU32LE(at: 24))
        let entriesStart = 24 + entriesOffsetWithinHeader
        guard entriesStart + entriesBytes.count <= blockSize else {
            throw NTFSError.corruptOnDisk(
                description: "buildLeafIndexBlock: \(entriesBytes.count) entry bytes overflow block (start \(entriesStart), block \(blockSize))"
            )
        }
        for (i, byte) in entriesBytes.enumerated() {
            out[out.startIndex + entriesStart + i] = byte
        }
        // Update INDEX_HEADER.usedSize (offset 28). Keep allocatedSize (32) as-is.
        let newUsedSize = UInt32(entriesOffsetWithinHeader + entriesBytes.count)
        MFTRecord.writeU32LE(into: &out, at: 28, value: newUsedSize)
        // Slack between entries end and (24 + allocatedSize) is zero from
        // Data(count: blockSize) — no need to clear.
        return out
    }
}
