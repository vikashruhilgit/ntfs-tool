import Foundation

public enum NTFSError: Error, Equatable, Sendable {
    case invalidBootSector(reason: String)
    case shortRead(expected: Int, got: Int)
    case ioFailure(description: String)
    case unsupportedAttribute(typeCode: UInt32)
    case unsupportedFeature(description: String)
    case corruptOnDisk(description: String)

    /// Thrown by `BlockDevice.write` when the backing device cannot accept
    /// writes (e.g. an `FSBlockDeviceResource` opened read-only by FSKit,
    /// or the default protocol witness for legacy read-only adapters).
    case readOnlyDevice

    /// Thrown by `Bitmap.allocate` / `Volume.allocateClusters` when there
    /// isn't a free run of the requested length anywhere on the volume.
    case outOfSpace(requestedClusters: UInt64, freeClusters: UInt64)
}
