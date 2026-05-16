import Foundation

public enum NTFSError: Error, Equatable, Sendable {
    case invalidBootSector(reason: String)
    case shortRead(expected: Int, got: Int)
    case ioFailure(description: String)
    case unsupportedAttribute(typeCode: UInt32)
    case unsupportedFeature(description: String)
    case corruptOnDisk(description: String)
}
