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

    /// Force all kernel-buffered writes to physical media. Equivalent to
    /// fcntl(F_FULLFSYNC) on macOS — stronger than `fsync()` because it
    /// also flushes the drive's own cache. CRITICAL before clearing the
    /// volume's dirty bit: a power loss or fast unplug after dirty=0 hits
    /// the disk but before the actual data does corrupts the volume silently
    /// (Windows trusts dirty=0 and skips chkdsk on the next mount).
    ///
    /// Default impl is a no-op so existing in-memory test backings don't
    /// need to opt in — only real block-device backings need it.
    func synchronize() async throws
}

public extension BlockDevice {
    func write(offset: UInt64, bytes: Data) async throws {
        throw NTFSError.readOnlyDevice
    }

    func synchronize() async throws {
        // No-op default for read-only / in-memory backings.
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
            // The two common causes on macOS: file doesn't exist (typo), or
            // Apple's auto-mount has claimed the raw device. Suggest the
            // unmount-first dance — that fixes the majority of cases.
            throw NTFSError.ioFailure(
                description: "cannot open \(path) for reading (hint: if this is a mounted NTFS volume, run `diskutil unmount \(path)` first to release Apple's read-only mount, then retry)"
            )
        }
        self.handle = handle
        self.isWritable = false
    }

    /// Open `path` read-write. The file must already exist; we don't create
    /// new NTFS volumes (that's `mkntfs`'s job). Used by mutable-fixture
    /// tests and by `ntfsctl` write operations against raw devices.
    ///
    /// Takes an exclusive advisory lock (`flock(LOCK_EX | LOCK_NB)`) on the
    /// file descriptor so a second concurrent writer can't race on bitmap
    /// allocation. Throws `ioFailure(description: "device in use ...")` if
    /// another process already holds the lock — caller should suggest
    /// killing the other process or checking for stray `ntfsctl` invocations.
    ///
    /// `lockExclusive: false` disables the flock — only used by tests that
    /// open the same fixture twice in one process for verify-reads. Don't
    /// pass false from CLI code.
    public init(openingFileForUpdateAt path: String, lockExclusive: Bool = true) throws {
        self.path = path
        guard let handle = FileHandle(forUpdatingAtPath: path) else {
            throw NTFSError.ioFailure(description: "cannot open \(path) for updating (hint: file may not exist, or you may need sudo for /dev/disk* devices)")
        }
        if lockExclusive {
            // Non-blocking exclusive flock to detect concurrent writers.
            let lockResult = flock(handle.fileDescriptor, LOCK_EX | LOCK_NB)
            if lockResult != 0 {
                let err = errno
                try? handle.close()
                throw NTFSError.ioFailure(
                    description: "device \(path) is already locked by another process (flock errno=\(err)) — close any other ntfsctl invocations on this device and retry"
                )
            }
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

    public func synchronize() async throws {
        guard isWritable else { return }
        // F_FULLFSYNC is stronger than fsync(): it also asks the drive itself
        // to flush its own cache to media. Costs latency but is the only
        // safe way to commit metadata-then-clear-dirty-bit ordering.
        let r = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        if r == -1 {
            // Fall back to plain fsync if F_FULLFSYNC isn't supported (rare
            // on macOS; happens on some network mounts). Still much better
            // than nothing.
            if fsync(handle.fileDescriptor) != 0 {
                let err = errno
                throw NTFSError.ioFailure(description: "synchronize failed (fcntl F_FULLFSYNC + fsync both errored, errno=\(err))")
            }
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
