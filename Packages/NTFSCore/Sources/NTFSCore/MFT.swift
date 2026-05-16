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
