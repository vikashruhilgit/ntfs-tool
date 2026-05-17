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
struct IndexAllocationWriter {

    enum InsertOutcome {
        case inserted
        case leafFull(usedSize: Int, allocatedSize: Int, needed: Int)
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
        newEntryBody: Data
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
                newEntryBody: newEntryBody
            )
        }
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
        newEntryBody: Data
    ) async throws -> InsertOutcome {
        let entriesStart = 24 + entriesOffsetWithinHeader
        let entriesEnd = 24 + usedSizeWithinHeader
        let leafEntries = try parseEntries(in: fixed, start: entriesStart, limit: entriesEnd)

        // Build the merged list (existing leaf entries + new entry), sorted.
        var merged: [(UInt64, Data, String)] = []
        for e in leafEntries where !e.isLast {
            merged.append((e.fileReference, e.keyBytes, e.keyName ?? ""))
        }
        merged.append((newEntryFileRef, newEntryBody, newSortKey))
        merged.sort { IndexBuilder.collationFilenameSortsBefore($0.2, $1.2) }

        // Compute needed bytes.
        let entryBytes = merged.reduce(0) { acc, e in
            let rawLen = 16 + e.1.count
            return acc + ((rawLen + 7) / 8) * 8
        } + 16 // LAST sentinel
        let neededUsedSize = entriesOffsetWithinHeader + entryBytes
        if neededUsedSize > allocatedSizeWithinHeader {
            return .leafFull(
                usedSize: usedSizeWithinHeader,
                allocatedSize: allocatedSizeWithinHeader,
                needed: neededUsedSize
            )
        }

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
        let byteOffset = try vcnToByteOffset(vcn: blockVCN, extents: allocationExtents, clusterBytes: clusterBytes)
        try await device.write(offset: byteOffset, bytes: onDisk)
        return .inserted
    }

    /// Construct a fresh INDX block (post-USA, ready to feed reverseFixup).
    /// Preserves the source block's magic, USA layout, LSN, VCN and INDEX_HEADER
    /// metadata (incl. allocatedSize); replaces the entries list and updates
    /// usedSize.
    private static func buildLeafIndexBlock(
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
