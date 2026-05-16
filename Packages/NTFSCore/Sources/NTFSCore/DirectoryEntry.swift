import Foundation

// Public-facing directory entry yielded by `Volume.enumerate`. Wraps the raw
// IndexEntry but skips the LAST sentinel and unwraps the FileName (always
// non-nil for real entries).
public struct DirectoryEntry: Sendable, Equatable {
    public let fileReference: UInt64
    public let recordNumber: UInt64
    public let sequenceNumber: UInt16
    public let fileName: FileName

    public var name: String { fileName.name }
    public var isDirectory: Bool {
        // The DIRECTORY bit (0x10000000) of $FILE_NAME.fileAttributes signals
        // a directory entry. Useful for callers that don't want to chase the
        // MFT record's flags themselves.
        (fileName.fileAttributes & 0x1000_0000) != 0
    }
}
