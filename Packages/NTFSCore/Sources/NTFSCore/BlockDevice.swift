import Foundation

// A minimal async byte-range reader for a block device or disk image.
//
// NTFSCore consumes anything that can satisfy `read(offset:length:)` — the
// real disk goes through `FileHandleBlockDevice`, the FSKit extension wraps
// an `FSBlockDeviceResource` in its own adapter, and tests construct an
// `InMemoryBlockDevice` over a `Data` buffer.

public protocol BlockDevice: Sendable {
    func read(offset: UInt64, length: Int) async throws -> Data

    /// Write `bytes` to the device starting at `offset`. The caller is
    /// responsible for any sector/cluster alignment requirements; this API
    /// is byte-level. Implementations that wrap a read-only backing store
    /// (e.g. a `FSBlockDeviceResource` opened read-only by FSKit) should
    /// throw `NTFSError.readOnlyDevice` rather than silently dropping.
    ///
    /// Phase 5b additive: defaulted to throw so existing read-only
    /// implementations don't have to opt in until they're ready to support
    /// writes.
    func write(offset: UInt64, bytes: Data) async throws
}

public extension BlockDevice {
    func write(offset: UInt64, bytes: Data) async throws {
        throw NTFSError.readOnlyDevice
    }
}

// A BlockDevice backed by a Foundation FileHandle. Used for the CLI and for
// unit tests against committed `.img` fixtures.
//
// The actor boundary serializes concurrent reads against the underlying
// FileHandle so callers from any task can share one device without manual
// locking. Phase 5 will extend this with write support.
public actor FileHandleBlockDevice: BlockDevice {
    public let path: String
    private let handle: FileHandle
    private let isWritable: Bool

    /// Open `path` read-only. `write(...)` will throw `readOnlyDevice`.
    public init(openingFileAt path: String) throws {
        self.path = path
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw NTFSError.ioFailure(description: "cannot open \(path) for reading")
        }
        self.handle = handle
        self.isWritable = false
    }

    /// Open `path` read-write. The file must already exist; we don't create
    /// new NTFS volumes (that's `mkntfs`'s job). Used by mutable-fixture
    /// tests and (Phase 5+) by `ntfsctl` write operations against raw
    /// devices.
    public init(openingFileForUpdateAt path: String) throws {
        self.path = path
        guard let handle = FileHandle(forUpdatingAtPath: path) else {
            throw NTFSError.ioFailure(description: "cannot open \(path) for updating")
        }
        self.handle = handle
        self.isWritable = true
    }

    public init(handle: FileHandle, path: String = "<handle>", isWritable: Bool = false) {
        self.path = path
        self.handle = handle
        self.isWritable = isWritable
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

    public func write(offset: UInt64, bytes: Data) async throws {
        guard isWritable else { throw NTFSError.readOnlyDevice }
        if bytes.isEmpty { return }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            throw NTFSError.ioFailure(description: "seek to offset \(offset) for write failed: \(error)")
        }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            throw NTFSError.ioFailure(description: "write at offset \(offset) length \(bytes.count) failed: \(error)")
        }
    }
}

// Convenience initializer keeping source compatibility with prior call-sites
// that used `BlockDevice(openingFileAt:)` before the protocol-extraction
// refactor. New code should prefer `FileHandleBlockDevice` directly.
public extension BlockDevice where Self == FileHandleBlockDevice {
    static func openingFile(at path: String) throws -> FileHandleBlockDevice {
        try FileHandleBlockDevice(openingFileAt: path)
    }
}
