import Foundation

// Reader for the Master File Table. Phase 1.6 surface: read one record at a
// given record number, assuming the MFT is contiguous starting at the cluster
// recorded in the boot sector. This holds for freshly-formatted volumes (our
// test fixture) and small volumes where the MFT hasn't been fragmented yet.
//
// Phase 1.7 / Block C will lift the contiguous-MFT assumption by reading
// $MFT's own $DATA attribute and decoding its runlist via DataRun, replacing
// the linear `byteOffset` math below with a real virtual-to-physical mapping.
public final class MFT: Sendable {
    public let volume: Volume

    init(volume: Volume) {
        self.volume = volume
    }

    /// Read and parse the MFT record at `recordNumber`.
    public func record(at recordNumber: UInt64) async throws -> MFTRecord {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let byteOffset = volume.mftByteOffset + recordNumber * recordSize
        let raw = try await volume.device.read(offset: byteOffset, length: Int(recordSize))
        return try MFTRecord.parse(raw, expectedSize: Int(recordSize))
    }
}
