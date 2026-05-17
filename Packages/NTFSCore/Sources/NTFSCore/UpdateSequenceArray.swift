import Foundation

// Update Sequence Array (USA) — NTFS's per-record corruption-detection scheme.
//
// Every multi-sector record (MFT records, INDEX_ALLOCATION blocks) ends each
// 512-byte block with a "sentinel" — the last 2 bytes of every block are
// supposed to match USA[0]. When NTFS writes the record, it (a) writes a
// freshly-incremented sentinel into USA[0], (b) saves the original last-2-bytes
// of each block into USA[1..N], and (c) overwrites the last 2 bytes of each
// block with the sentinel. On read, NTFS verifies the sentinel is intact in
// every block (catches torn writes / hardware failures) and then restores the
// original bytes from USA[1..N].
//
// References:
// - Linux-NTFS docs: https://flatcap.github.io/linux-ntfs/ntfs/concepts/fixup.html
// - NTFS-3G libntfs-3g/lcnalloc.c, mft.c
enum UpdateSequenceArray {

    /// Apply USA fix-up to a multi-sector record and return the restored bytes.
    ///
    /// - parameter recordBytes: the raw on-disk record (with sentinels in each block's last 2 bytes).
    /// - parameter usaOffset: byte offset (from record start) of the USA.
    /// - parameter usaCount: number of u16 entries in the USA (1 sentinel + N fix-ups).
    /// - parameter blockSize: the multi-sector unit, typically 512 bytes for MFT/INDX records.
    /// - returns: a fresh Data with the original bytes restored.
    /// - throws: `NTFSError.corruptOnDisk` if the USA is malformed or any sentinel mismatches.
    static func applyFixup(
        recordBytes raw: Data,
        usaOffset: Int,
        usaCount: Int,
        blockSize: Int
    ) throws -> Data {
        guard usaCount >= 1 else {
            throw NTFSError.corruptOnDisk(description: "USA count must be >= 1 (got \(usaCount))")
        }
        guard blockSize > 2, blockSize.nonzeroBitCount == 1 else {
            throw NTFSError.corruptOnDisk(description: "USA block size must be a power of two > 2 (got \(blockSize))")
        }

        // USA = 1 sentinel + N fix-ups; N == record_size / block_size.
        let expectedFixups = raw.count / blockSize
        let actualFixups = usaCount - 1
        guard actualFixups == expectedFixups else {
            throw NTFSError.corruptOnDisk(
                description: "USA fix-up count mismatch: header says \(actualFixups), record size implies \(expectedFixups)"
            )
        }
        guard usaOffset >= 0,
              usaOffset + (usaCount * 2) <= raw.count else {
            throw NTFSError.corruptOnDisk(
                description: "USA range (offset \(usaOffset), count \(usaCount)) exceeds record size \(raw.count)"
            )
        }

        // USA[0] is the sentinel that every block's tail must currently equal.
        let sentinel = try raw.readU16LE(at: usaOffset)

        var fixed = raw

        for i in 0..<expectedFixups {
            let blockTail = (i + 1) * blockSize - 2
            let onDiskSentinel = try fixed.readU16LE(at: blockTail)
            guard onDiskSentinel == sentinel else {
                throw NTFSError.corruptOnDisk(
                    description: "USA sentinel mismatch in block \(i): expected 0x\(String(format: "%04X", sentinel)), got 0x\(String(format: "%04X", onDiskSentinel)) at offset \(blockTail)"
                )
            }

            let fixupBytePosition = usaOffset + 2 * (i + 1)
            let restoreLow  = try fixed.readU8(at: fixupBytePosition)
            let restoreHigh = try fixed.readU8(at: fixupBytePosition + 1)

            // Replace the sentinel in place with the original 2 bytes from USA[i+1].
            // `Data` indexing through subscript uses .startIndex-relative offsets, so we
            // must add fixed.startIndex when slicing into the underlying storage.
            fixed[fixed.startIndex + blockTail]     = restoreLow
            fixed[fixed.startIndex + blockTail + 1] = restoreHigh
        }

        return fixed
    }

    /// Apply USA on the WRITE path — inverse of `applyFixup`.
    ///
    /// Caller supplies the post-fix-up record bytes (the form attribute
    /// parsers see). This function (a) increments the sequence number in
    /// USA[0] by 1, (b) copies the original last-2-bytes of every block
    /// into USA[1..N], and (c) overwrites those block tails with the new
    /// sentinel value. The returned Data is ready to write to disk.
    ///
    /// - parameter recordBytes: the post-fix-up record (with original
    ///   block tails intact).
    /// - parameter usaOffset: byte offset (from record start) of the USA.
    /// - parameter usaCount: total u16 entries in USA (1 sentinel + N
    ///   fix-ups).
    /// - parameter blockSize: multi-sector unit, typically 512.
    /// - returns: bytes ready to write to disk.
    static func reverseFixup(
        recordBytes raw: Data,
        usaOffset: Int,
        usaCount: Int,
        blockSize: Int
    ) throws -> Data {
        guard usaCount >= 1 else {
            throw NTFSError.corruptOnDisk(description: "USA count must be >= 1 (got \(usaCount))")
        }
        guard blockSize > 2, blockSize.nonzeroBitCount == 1 else {
            throw NTFSError.corruptOnDisk(description: "USA block size must be a power of two > 2 (got \(blockSize))")
        }
        let expectedFixups = raw.count / blockSize
        let actualFixups = usaCount - 1
        guard actualFixups == expectedFixups else {
            throw NTFSError.corruptOnDisk(
                description: "USA fix-up count mismatch on write: header says \(actualFixups), record size implies \(expectedFixups)"
            )
        }
        guard usaOffset >= 0,
              usaOffset + (usaCount * 2) <= raw.count else {
            throw NTFSError.corruptOnDisk(
                description: "USA range (offset \(usaOffset), count \(usaCount)) exceeds record size \(raw.count)"
            )
        }

        var out = raw

        // Bump the sentinel. NTFS wraps from 0xFFFF back to 1 (0 is reserved
        // as the freshly-formatted sentinel).
        let oldSentinel = try out.readU16LE(at: usaOffset)
        var newSentinel = oldSentinel &+ 1
        if newSentinel == 0 { newSentinel = 1 }

        // Write the new sentinel into USA[0].
        out[out.startIndex + usaOffset]     = UInt8(newSentinel & 0xFF)
        out[out.startIndex + usaOffset + 1] = UInt8((newSentinel >> 8) & 0xFF)

        for i in 0..<expectedFixups {
            let blockTail = (i + 1) * blockSize - 2

            // Save the original block-tail bytes into USA[i+1].
            let originalLow  = try out.readU8(at: blockTail)
            let originalHigh = try out.readU8(at: blockTail + 1)
            let fixupBytePosition = usaOffset + 2 * (i + 1)
            out[out.startIndex + fixupBytePosition]     = originalLow
            out[out.startIndex + fixupBytePosition + 1] = originalHigh

            // Overwrite the block tail with the new sentinel.
            out[out.startIndex + blockTail]     = UInt8(newSentinel & 0xFF)
            out[out.startIndex + blockTail + 1] = UInt8((newSentinel >> 8) & 0xFF)
        }

        return out
    }
}
