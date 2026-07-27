import Foundation

// Public-facing directory entry yielded by `Volume.enumerate`. Wraps the raw
// IndexEntry but skips the LAST sentinel and unwraps the FileName (always
// non-nil for real entries).
public struct DirectoryEntry: Sendable, Equatable {
    public let fileReference: UInt64
    public let recordNumber: UInt64
    public let sequenceNumber: UInt16
    public let fileName: FileName

    /// Public so a `DirectoryChildSource` can be implemented outside
    /// NTFSCore (the FSKit adapter, CLI tests, synthetic trees).
    public init(
        fileReference: UInt64,
        recordNumber: UInt64,
        sequenceNumber: UInt16,
        fileName: FileName
    ) {
        self.fileReference = fileReference
        self.recordNumber = recordNumber
        self.sequenceNumber = sequenceNumber
        self.fileName = fileName
    }

    public var name: String { fileName.name }
    public var isDirectory: Bool {
        // The NTFS-specific FILE_NAME_INDEX_PRESENT bit (0x10000000) of
        // $FILE_NAME.fileAttributes is set when the entry refers to a
        // directory. Note: this is NOT the Win32 FILE_ATTRIBUTE_DIRECTORY
        // constant (0x00000010) — the NTFS-internal high-bit flag is what
        // the on-disk $FILE_NAME records use. See ntfs-3g's FILE_NAME_ATTR
        // layout.
        (fileName.fileAttributes & 0x1000_0000) != 0
    }
}
