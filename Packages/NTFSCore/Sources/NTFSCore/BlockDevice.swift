import Foundation

// A minimal async byte-range reader for a block device or disk image.
//
// Phase 1.5: signature is `async throws -> Data` (per the brief). The actor
// boundary serializes concurrent reads against a single FileHandle so callers
// from any task can share one BlockDevice without manual locking. Phase 5
// will extend this with write support.
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

    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard length >= 0 else {
            throw NTFSError.ioFailure(description: "negative read length \(length)")
        }
        if length == 0 { return Data() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            throw NTFSError.ioFailure(description: "seek to offset \(offset) failed: \(error)")
        }

        let data: Data?
        do {
            data = try handle.read(upToCount: length)
        } catch {
            throw NTFSError.ioFailure(description: "read at offset \(offset) length \(length) failed: \(error)")
        }
        guard let data, data.count == length else {
            throw NTFSError.shortRead(expected: length, got: data?.count ?? 0)
        }
        return data
    }
}
