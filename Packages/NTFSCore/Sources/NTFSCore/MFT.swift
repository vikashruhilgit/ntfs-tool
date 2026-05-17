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
    /// resize records here.
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
        let (offsetProduct, mulOverflow) = recordNumber.multipliedReportingOverflow(by: recordSize)
        guard !mulOverflow else {
            throw NTFSError.corruptOnDisk(
                description: "writeRecord: record number \(recordNumber) * size \(recordSize) overflows"
            )
        }
        let (byteOffset, addOverflow) = volume.mftByteOffset.addingReportingOverflow(offsetProduct)
        guard !addOverflow else {
            throw NTFSError.corruptOnDisk(description: "writeRecord: byte offset overflows UInt64")
        }
        let bytes = try record.serialize(sectorSize: sectorSize)
        try await volume.device.write(offset: byteOffset, bytes: bytes)
    }

    /// Write raw pre-serialized record bytes to a specific slot. Used by
    /// `Volume.createFile` after MFTRecordBuilder.build() — the bytes are
    /// already in post-fix-up form and need USA-reversal before write.
    public func writeRawRecord(at recordNumber: UInt64, postFixupBytes: Data) async throws {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        guard postFixupBytes.count == Int(recordSize) else {
            throw NTFSError.corruptOnDisk(
                description: "writeRawRecord: bytes \(postFixupBytes.count) != record size \(recordSize)"
            )
        }
        let (offsetProduct, mulOverflow) = recordNumber.multipliedReportingOverflow(by: recordSize)
        guard !mulOverflow else {
            throw NTFSError.corruptOnDisk(description: "writeRawRecord: overflow")
        }
        let (byteOffset, addOverflow) = volume.mftByteOffset.addingReportingOverflow(offsetProduct)
        guard !addOverflow else {
            throw NTFSError.corruptOnDisk(description: "writeRawRecord: byte offset overflows")
        }

        // Need usaOffset + usaCount to drive the reversal. Read them from
        // the in-memory bytes (header always contains them).
        let usaOffset = try postFixupBytes.readU16LE(at: 4)
        let usaCount  = try postFixupBytes.readU16LE(at: 6)

        let onDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: postFixupBytes,
            usaOffset: Int(usaOffset),
            usaCount: Int(usaCount),
            blockSize: sectorSize
        )
        try await volume.device.write(offset: byteOffset, bytes: onDisk)
    }

    /// Read and parse the MFT record at `recordNumber`.
    public func record(at recordNumber: UInt64) async throws -> MFTRecord {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        guard recordSize > 0 else {
            throw NTFSError.corruptOnDisk(description: "volume MFT record size is zero")
        }
        let (offsetProduct, mulOverflow) = recordNumber.multipliedReportingOverflow(by: recordSize)
        guard !mulOverflow else {
            throw NTFSError.corruptOnDisk(
                description: "MFT record number \(recordNumber) overflows when multiplied by record size \(recordSize)"
            )
        }
        let (byteOffset, addOverflow) = volume.mftByteOffset.addingReportingOverflow(offsetProduct)
        guard !addOverflow else {
            throw NTFSError.corruptOnDisk(
                description: "MFT byte offset overflows UInt64 at record \(recordNumber)"
            )
        }
        let raw = try await volume.device.read(offset: byteOffset, length: Int(recordSize))
        return try MFTRecord.parse(raw, expectedSize: Int(recordSize), sectorSize: sectorSize)
    }
}
