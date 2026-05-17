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

    public init(bytes: Data, clusterCount: UInt64) {
        self.bytes = bytes
        self.clusterCount = clusterCount
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
        for offset in 0..<count {
            let cluster = startLCN + offset
            guard cluster < clusterCount else {
                throw NTFSError.corruptOnDisk(
                    description: "markAllocated: cluster \(cluster) >= clusterCount \(clusterCount)"
                )
            }
            let byteIndex = Int(cluster / 8)
            let bitIndex = Int(cluster % 8)
            bytes[bytes.startIndex + byteIndex] |= (1 << bitIndex)
        }
    }

    /// Mark `count` clusters starting at `startLCN` as free. Same out-of-
    /// range behavior as `markAllocated`.
    public mutating func markFree(startLCN: UInt64, count: UInt64) throws {
        for offset in 0..<count {
            let cluster = startLCN + offset
            guard cluster < clusterCount else {
                throw NTFSError.corruptOnDisk(
                    description: "markFree: cluster \(cluster) >= clusterCount \(clusterCount)"
                )
            }
            let byteIndex = Int(cluster / 8)
            let bitIndex = Int(cluster % 8)
            bytes[bytes.startIndex + byteIndex] &= ~(UInt8(1) << bitIndex)
        }
    }

    /// Allocate a single contiguous run of `count` clusters. Returns the
    /// starting LCN. Throws `outOfSpace` if no such run is available.
    /// Mutates the bitmap to mark the run allocated.
    public mutating func allocate(_ count: UInt64) throws -> Extent {
        guard count > 0 else {
            throw NTFSError.ioFailure(description: "allocate: count must be > 0")
        }
        guard let startLCN = findFreeRun(count: count) else {
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

    /// Find the first run of `count` consecutive free clusters at or after
    /// `startingAt`. Returns nil if no such run exists. O(N) over the
    /// bitmap — efficient enough for v1 reads; Phase 5b's allocator will add
    /// a free-list cache for write hot paths.
    public func findFreeRun(count: UInt64, startingAt: UInt64 = 0) -> UInt64? {
        guard count > 0 else { return startingAt }
        var runStart: UInt64? = nil
        var runLength: UInt64 = 0

        var c = startingAt
        while c < clusterCount {
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
