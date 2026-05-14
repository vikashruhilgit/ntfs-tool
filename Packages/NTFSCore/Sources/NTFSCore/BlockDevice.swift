import Foundation

// A minimal async byte-range reader for a block device or disk image.
//
// Phase 1 only needs read access; write support lands in Phase 5. The actor
// boundary serializes concurrent reads against a single FileHandle so callers
// from any task can share one BlockDevice without manual locking.
public actor BlockDevice {
    public let path: String
    private let handle: FileHandle

    public init(openingFileAt path: String) throws {
        self.path = path
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw NTFSError.ioFailure(description: "cannot open \(path) for reading")
        }
        self.handle = handle
    }

    public init(handle: FileHandle, path: String = "<handle>") {
        self.path = path
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw NTFSError.ioFailure(description: "negative read length \(length)")
        }
        if length == 0 { return Data() }

        try handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: length)
        guard data.count == length else {
            throw NTFSError.shortRead(expected: length, got: data.count)
        }
        return data
    }
}
