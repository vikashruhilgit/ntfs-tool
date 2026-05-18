import Foundation

// Reader for the Master File Table.
//
// Phase 1.6: contiguous-MFT assumption starting at boot.mftCluster.
// Phase 1.7 (this iteration): still contiguous for non-zero record numbers
// (lifted properly in Block D once we can resolve the $MFT $DATA runlist
// from a parsed attribute), but the USA fix-up now honors the volume's
// `bytesPerSector` instead of a hardcoded 512.
public final class MFT: Sendable {
    public let volume: Volume

    init(volume: Volume) {
        self.volume = volume
    }

    /// MFT records 0-15 are reserved for NTFS system files ($MFT, $MFTMirr,
    /// $LogFile, $Volume, $AttrDef, root dir at 5, $Bitmap, $Boot, $BadClus,
    /// $Secure, $UpCase, $Extend at 11). User files start at 16+.
    public static let firstUserRecord: UInt64 = 16

    /// Scan MFT slots starting at `firstUserRecord` for an IN_USE=0 record
    /// and return its number. Records that fail to parse (zeroed slots that
    /// don't even have the FILE magic) count as free.
    ///
    /// Phase 5c uses linear scan; phase 5e will switch to the proper
    /// $MFT $BITMAP attribute for O(1) lookup.
    public func findFreeRecordNumber(maxScan: UInt64 = 2048) async throws -> UInt64 {
        for n in Self.firstUserRecord..<(Self.firstUserRecord + maxScan) {
            do {
                let record = try await record(at: n)
                if !record.isInUse { return n }
            } catch {
                // Unparseable slot — treat as free.
                return n
            }
        }
        throw NTFSError.outOfSpace(
            requestedClusters: 1,
            freeClusters: 0
        )
    }

    /// Serialize and write `record` back to its MFT slot. The record's
    /// `allocatedSize` must match the volume's MFT record size; we don't
    /// resize records here. Also writes to $MFTMirr for records 0-3.
    public func writeRecord(at recordNumber: UInt64, _ record: MFTRecord) async throws {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        guard recordSize > 0 else {
            throw NTFSError.corruptOnDisk(description: "volume MFT record size is zero")
        }
        guard UInt32(recordSize) == record.allocatedSize else {
            throw NTFSError.corruptOnDisk(
                description: "writeRecord: record.allocatedSize \(record.allocatedSize) != volume MFT record size \(recordSize)"
            )
        }
        let bytes = try record.serialize(sectorSize: sectorSize)

        let primaryOffset = try await mftRecordByteOffset(recordNumber: recordNumber)
        try await volume.device.write(offset: primaryOffset, bytes: bytes)

        if recordNumber < Self.mirroredRecordCount {
            let mirrorBase = UInt64(volume.boot.mftMirrorCluster) * UInt64(volume.bytesPerCluster)
            let (offsetInMirror, overflow) = recordNumber.multipliedReportingOverflow(by: recordSize)
            guard !overflow else {
                throw NTFSError.corruptOnDisk(description: "writeRecord: mirror offset overflow")
            }
            try await volume.device.write(offset: mirrorBase + offsetInMirror, bytes: bytes)
        }
    }

    /// NTFS mirrors the first 4 MFT records ($MFT, $MFTMirr, $LogFile,
    /// $Volume) into $MFTMirr so a corrupted primary MFT can be recovered
    /// from the mirror. Every write to records 0-3 MUST also write the
    /// same bytes to the corresponding mirror slot or ntfs-3g / chkdsk
    /// will reject the volume with "$MFTMirr does not match $MFT".
    public static let mirroredRecordCount: UInt64 = 4

    /// Write raw pre-serialized record bytes to a specific slot. Used by
    /// `Volume.createFile` after MFTRecordBuilder.build() — the bytes are
    /// already in post-fix-up form and need USA-reversal before write.
    /// When `recordNumber < mirroredRecordCount`, also writes to $MFTMirr.
    public func writeRawRecord(at recordNumber: UInt64, postFixupBytes: Data) async throws {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        guard postFixupBytes.count == Int(recordSize) else {
            throw NTFSError.corruptOnDisk(
                description: "writeRawRecord: bytes \(postFixupBytes.count) != record size \(recordSize)"
            )
        }

        let usaOffset = try postFixupBytes.readU16LE(at: 4)
        let usaCount  = try postFixupBytes.readU16LE(at: 6)
        let onDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: postFixupBytes,
            usaOffset: Int(usaOffset),
            usaCount: Int(usaCount),
            blockSize: sectorSize
        )

        // Primary write into $MFT.
        let primaryOffset = try await mftRecordByteOffset(recordNumber: recordNumber)
        try await volume.device.write(offset: primaryOffset, bytes: onDisk)

        // Mirror write into $MFTMirr for records 0-3.
        if recordNumber < Self.mirroredRecordCount {
            let mirrorBase = UInt64(volume.boot.mftMirrorCluster) * UInt64(volume.bytesPerCluster)
            let (offsetInMirror, overflow) = recordNumber.multipliedReportingOverflow(by: recordSize)
            guard !overflow else {
                throw NTFSError.corruptOnDisk(description: "writeRawRecord: mirror offset overflow")
            }
            try await volume.device.write(offset: mirrorBase + offsetInMirror, bytes: onDisk)
        }
    }

    /// Resolve an MFT byte offset for a given record number. Walks the
    /// $MFT.$DATA runlist (cached by the Volume) so multi-extent $MFT
    /// layouts work — necessary because growMFTDataByClusters may add
    /// non-adjacent clusters when adjacency isn't available.
    ///
    /// MFT record 0 itself is a chicken-and-egg case: to walk the runlist
    /// we need to read record 0 first. The contiguous-from-mftCluster
    /// shortcut covers record 0 (it's always at the start of the first
    /// extent at boot.mftCluster).
    fileprivate func mftRecordByteOffset(recordNumber: UInt64) async throws -> UInt64 {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let (offsetProduct, mulOverflow) = recordNumber.multipliedReportingOverflow(by: recordSize)
        guard !mulOverflow else {
            throw NTFSError.corruptOnDisk(
                description: "mftRecordByteOffset: record number \(recordNumber) * size \(recordSize) overflows"
            )
        }
        // Fast path / bootstrap: record 0 is always at boot.mftCluster.
        // Same fast path for records that fit entirely within the FIRST
        // extent (which holds record 0). Avoids the recursive read of
        // record 0 to discover its own runlist.
        if recordNumber == 0 {
            return volume.mftByteOffset
        }
        // Try to walk the cached runlist. If unavailable (first call before
        // any $MFT parse has cached it), fall back to the contiguous
        // assumption — Volume warms the cache on init.
        if let extents = await volume.mftDataExtents() {
            let clusterBytes = UInt64(volume.bytesPerCluster)
            let recordsPerCluster = max(UInt64(1), clusterBytes / recordSize)
            // For typical layouts (cluster=4096, record=1024 → 4 records/cluster).
            var cumulativeClusters: UInt64 = 0
            for extent in extents {
                let endRecord = (cumulativeClusters + extent.clusterCount) * recordsPerCluster
                if recordNumber < endRecord {
                    guard let startLCN = extent.startLCN else {
                        throw NTFSError.corruptOnDisk(description: "mftRecordByteOffset: sparse $MFT extent")
                    }
                    let recordInExtent = recordNumber - cumulativeClusters * recordsPerCluster
                    return startLCN * clusterBytes + recordInExtent * recordSize
                }
                cumulativeClusters += extent.clusterCount
            }
            throw NTFSError.corruptOnDisk(
                description: "mftRecordByteOffset: record \(recordNumber) past $MFT runlist coverage (\(cumulativeClusters) clusters)"
            )
        }
        // Fallback: contiguous assumption (works if $MFT hasn't grown).
        let (byteOffset, addOverflow) = volume.mftByteOffset.addingReportingOverflow(offsetProduct)
        guard !addOverflow else {
            throw NTFSError.corruptOnDisk(description: "mftRecordByteOffset: byte offset overflows UInt64")
        }
        return byteOffset
    }

    /// Read and parse the MFT record at `recordNumber`.
    public func record(at recordNumber: UInt64) async throws -> MFTRecord {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        guard recordSize > 0 else {
            throw NTFSError.corruptOnDisk(description: "volume MFT record size is zero")
        }
        let byteOffset = try await mftRecordByteOffset(recordNumber: recordNumber)
        let raw = try await volume.device.read(offset: byteOffset, length: Int(recordSize))
        return try MFTRecord.parse(raw, expectedSize: Int(recordSize), sectorSize: sectorSize)
    }
}
