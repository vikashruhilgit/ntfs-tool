import Foundation

// Bit-level wrapper for the $Bitmap attribute. One bit per cluster on the
// volume: 1 = allocated, 0 = free. Bit ordering matches the NTFS convention
// — byte k bit b represents cluster (k * 8 + b), with bit 0 = LSB.
//
// Phase 5a (this block): read-only access. allocate() / free() arrive in
// Phase 5b alongside MFT record mutation.
public struct Bitmap: Sendable, Equatable {
    /// Raw bitmap bytes. Length = ceil(clusterCount / 8). May be padded with
    /// trailing zero bytes if the on-disk attribute is cluster-aligned.
    public var bytes: Data

    /// Total clusters this bitmap describes — usually equal to
    /// `volume.boot.totalSectors / volume.boot.sectorsPerCluster`. Stored
    /// explicitly because the bitmap byte length is rounded up to the next
    /// cluster boundary, so we can't recover it from `bytes.count` alone.
    public let clusterCount: UInt64

    /// v0.4: dirty-range tracking for `persistBitmap`. On a 4 TB drive
    /// `bytes` is ~128 MB; writing all of it on every allocate/free was
    /// the dominant cost in cp -r (~5 sec per file on USB). Tracks the
    /// half-open `[first, last+1)` byte range of any mutation since the
    /// last `clearDirty()` call. `nil` = clean (nothing to persist).
    /// Multiple mutations expand the range to cover all of them — this
    /// can over-write a contiguous span that includes some unchanged
    /// bytes, but stays under a few hundred KiB in practice for cp -r
    /// (sequential cluster allocations hit adjacent bytes).
    public var dirtyByteRange: Range<Int>?

    public init(bytes: Data, clusterCount: UInt64) {
        self.bytes = bytes
        self.clusterCount = clusterCount
        self.dirtyByteRange = nil
    }

    /// Clear the dirty range after a successful persist. Volume.persistBitmap
    /// calls this on its in-memory copy after writing.
    public mutating func clearDirty() {
        dirtyByteRange = nil
    }

    /// Internal helper — expand `dirtyByteRange` to cover bytes [start, end).
    /// Called from mark/markFree on every bit-flip.
    fileprivate mutating func markDirtyBytes(start: Int, end: Int) {
        let newStart: Int
        let newEnd: Int
        if let current = dirtyByteRange {
            newStart = Swift.min(current.lowerBound, start)
            newEnd = Swift.max(current.upperBound, end)
        } else {
            newStart = start
            newEnd = end
        }
        dirtyByteRange = newStart..<newEnd
    }

    /// Is the given cluster allocated? Returns true for any cluster index >=
    /// clusterCount (a defensive choice — treats off-volume reads as "in use"
    /// so a buggy allocator can't accidentally hand out non-existent space).
    public func isAllocated(cluster: UInt64) -> Bool {
        guard cluster < clusterCount else { return true }
        let byteIndex = Int(cluster / 8)
        let bitIndex = Int(cluster % 8)
        guard byteIndex < bytes.count else { return true }
        return (bytes[bytes.startIndex + byteIndex] & (1 << bitIndex)) != 0
    }

    /// Number of free (0-bit) clusters on the volume. O(N) over the bitmap
    /// bytes — cache the result at the call site for large volumes (the
    /// answer doesn't change on a read-only mount).
    public var freeClusterCount: UInt64 {
        var free: UInt64 = 0
        let fullBytes = Int(clusterCount / 8)
        let tailBits = Int(clusterCount % 8)

        // Full bytes — count zero bits.
        if fullBytes > 0 {
            for byte in bytes.prefix(fullBytes) {
                free += UInt64(8 - byte.nonzeroBitCount)
            }
        }

        // Tail byte — only count the low `tailBits` bits (the rest is padding
        // that lies beyond the volume's true cluster count and we don't trust
        // its value).
        if tailBits > 0, fullBytes < bytes.count {
            let tail = bytes[bytes.startIndex + fullBytes]
            for b in 0..<tailBits where (tail & (1 << b)) == 0 {
                free += 1
            }
        }

        return free
    }

    public var allocatedClusterCount: UInt64 {
        clusterCount - freeClusterCount
    }

    /// Mark `count` clusters starting at `startLCN` as allocated. No-op for
    /// `count == 0`. Out-of-range clusters throw `corruptOnDisk` rather
    /// than silently scribbling past the bitmap.
    public mutating func markAllocated(startLCN: UInt64, count: UInt64) throws {
        guard count > 0 else { return }
        // Validate range first so we don't mutate on a partial failure.
        let endLCN = startLCN + count
        guard endLCN <= clusterCount else {
            throw NTFSError.corruptOnDisk(
                description: "markAllocated: cluster \(endLCN - 1) >= clusterCount \(clusterCount)"
            )
        }
        for offset in 0..<count {
            let cluster = startLCN + offset
            let byteIndex = Int(cluster / 8)
            let bitIndex = Int(cluster % 8)
            bytes[bytes.startIndex + byteIndex] |= (1 << bitIndex)
        }
        // Mark dirty: contiguous byte range covering all flipped bits.
        let firstByte = Int(startLCN / 8)
        let lastByte = Int((endLCN - 1) / 8)
        markDirtyBytes(start: firstByte, end: lastByte + 1)
    }

    /// Mark `count` clusters starting at `startLCN` as free. Same out-of-
    /// range behavior as `markAllocated`.
    public mutating func markFree(startLCN: UInt64, count: UInt64) throws {
        guard count > 0 else { return }
        let endLCN = startLCN + count
        guard endLCN <= clusterCount else {
            throw NTFSError.corruptOnDisk(
                description: "markFree: cluster \(endLCN - 1) >= clusterCount \(clusterCount)"
            )
        }
        for offset in 0..<count {
            let cluster = startLCN + offset
            let byteIndex = Int(cluster / 8)
            let bitIndex = Int(cluster % 8)
            bytes[bytes.startIndex + byteIndex] &= ~(UInt8(1) << bitIndex)
        }
        let firstByte = Int(startLCN / 8)
        let lastByte = Int((endLCN - 1) / 8)
        markDirtyBytes(start: firstByte, end: lastByte + 1)
    }

    /// Allocate a single contiguous run of `count` clusters. Returns the
    /// starting LCN. Throws `outOfSpace` if no such run is available.
    /// Mutates the bitmap to mark the run allocated.
    ///
    /// `startingAt` is the next-fit search hint: the search begins there and
    /// wraps around to cluster 0, so a stale/high hint never strands free
    /// space below it. Default 0 preserves first-fit-from-0 behavior for
    /// callers that don't track a hint.
    public mutating func allocate(_ count: UInt64, startingAt: UInt64 = 0) throws -> Extent {
        guard count > 0 else {
            throw NTFSError.ioFailure(description: "allocate: count must be > 0")
        }
        guard let startLCN = findFreeRun(count: count, startingAt: startingAt) else {
            throw NTFSError.outOfSpace(
                requestedClusters: count,
                freeClusters: freeClusterCount
            )
        }
        try markAllocated(startLCN: startLCN, count: count)
        return Extent(startLCN: startLCN, clusterCount: count)
    }

    /// Free a previously-allocated extent. Sparse extents (startLCN == nil)
    /// are no-ops since they don't occupy bitmap bits.
    public mutating func free(_ extent: Extent) throws {
        guard let startLCN = extent.startLCN else { return }
        try markFree(startLCN: startLCN, count: extent.clusterCount)
    }

    /// Find the first run of `count` consecutive free clusters, searching
    /// next-fit from `startingAt` with wrap-around: scan `[startingAt,
    /// clusterCount)` first, then `[0, startingAt)`. Returns nil if no such
    /// run exists anywhere on the volume. O(N) over the bitmap — efficient
    /// enough for v1; the rolling hint keeps sequential cp -r writes
    /// contiguous, and the wrap-around guarantees no free space below the
    /// hint is stranded.
    ///
    /// A run never spans the wrap boundary: each pass scans independently
    /// with its own accumulator, so a run that would start near the end and
    /// "continue" past clusterCount into low clusters is never returned —
    /// that would be a non-contiguous LCN range, which Extent can't express.
    /// When `startingAt == 0` (or `>= clusterCount`, a stale hint we clamp to
    /// 0) the second pass is empty, so behavior matches a single full scan.
    public func findFreeRun(count: UInt64, startingAt: UInt64 = 0) -> UInt64? {
        guard count > 0 else { return startingAt }
        // Clamp a stale hint so it can't break the search.
        let hint = startingAt < clusterCount ? startingAt : 0
        // Pass 1: [hint, clusterCount). Pass 2: [0, hint).
        if let found = findFreeRun(count: count, from: hint, to: clusterCount) {
            return found
        }
        if hint > 0, let found = findFreeRun(count: count, from: 0, to: hint) {
            return found
        }
        return nil
    }

    /// Single forward pass over `[from, to)` for a run of `count` free
    /// clusters. The run must lie wholly within the half-open range — the
    /// accumulator resets at `to`, never wrapping.
    private func findFreeRun(count: UInt64, from: UInt64, to: UInt64) -> UInt64? {
        var runStart: UInt64? = nil
        var runLength: UInt64 = 0

        var c = from
        while c < to {
            if !isAllocated(cluster: c) {
                if runStart == nil { runStart = c }
                runLength += 1
                if runLength == count { return runStart }
            } else {
                runStart = nil
                runLength = 0
            }
            c += 1
        }
        return nil
    }
}
