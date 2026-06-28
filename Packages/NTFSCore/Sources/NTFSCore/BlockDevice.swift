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

    /// Release any advisory (`flock`) lock held on the underlying file WITHOUT
    /// closing it. Lets a writer deterministically hand the device off to a
    /// fresh handle (e.g. a caller that re-opens the volume right after
    /// `formatNTFS`) instead of waiting on non-deterministic actor/ARC deinit
    /// to drop the lock. Default no-op for backings that take no lock.
    func releaseAdvisoryLock() async
}

public extension BlockDevice {
    func write(offset: UInt64, bytes: Data) async throws {
        throw NTFSError.readOnlyDevice
    }

    func synchronize() async throws {
        // No-op default for read-only / in-memory backings.
    }

    func releaseAdvisoryLock() async {
        // No-op default — only file-backed devices take an flock.
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

    /// Drop the exclusive `flock` taken in `openingFileForUpdateAt` without
    /// closing the handle. Safe to call when this writer is done mutating the
    /// device but the object may still be retained briefly (e.g. by a Volume
    /// actor awaiting deinit).
    public func releaseAdvisoryLock() {
        if isWritable { _ = flock(handle.fileDescriptor, LOCK_UN) }
    }

    /// Chunk size for raw-device reads. Like writes, a single `read(2)` to a
    /// raw character device (`/dev/rdiskN`) is capped at MAXPHYS (~1 MiB on
    /// stock macOS); a larger read returns EINVAL ("Invalid argument") rather
    /// than a short read. The volume `$Bitmap` on a 4 TB drive is ~122 MB, so
    /// any reader that pulls it in one call (the allocator, `verify --deep`,
    /// `dump`) failed on real hardware until this was chunked. Regular `.img`
    /// files are fine with larger reads, but chunking is harmless there.
    static let readChunkSize: Int = 1 * 1024 * 1024   // 1 MiB

    /// Raw-device block size for read alignment, resolved lazily and cached.
    /// `nil` = not yet probed; `.some(nil)` = a regular file (no alignment
    /// needed); `.some(.some(bs))` = a raw device that requires `bs`-aligned
    /// read offsets AND lengths. Raw character devices reject a `read(2)` whose
    /// offset or length isn't a multiple of the block size with EINVAL.
    private var _rawBlockSize: UInt32?? = nil

    private func rawBlockSize() -> UInt32? {
        if let cached = _rawBlockSize { return cached }
        let fd = handle.fileDescriptor
        var st = stat()
        var result: UInt32? = nil
        if fstat(fd, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            // Block/character device — probe its block size (mirror size()).
            let DKIOCGETBLOCKSIZE: UInt = 0x40046418
            var bs: UInt32 = 0
            if ioctl(fd, DKIOCGETBLOCKSIZE, &bs) == 0, bs > 0 {
                result = bs
            } else {
                result = 512   // safe default for a raw device we couldn't probe
            }
        }
        _rawBlockSize = .some(result)
        return result
    }

    /// Test-only seam: force the raw-device block size so the block-alignment
    /// read path and the sub-block read-modify-write path can be exercised
    /// against a regular temp file (which `fstat` would otherwise classify as
    /// needing no alignment). Pass `nil` to restore "regular file" behaviour.
    /// Not used by production code.
    internal func _forceBlockSizeForTesting(_ bs: UInt32?) {
        _rawBlockSize = .some(bs)
    }

    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard length >= 0 else {
            throw NTFSError.ioFailure(description: "negative read length \(length)")
        }
        if length == 0 { return Data() }

        // Regular files: chunked read of exactly the requested window — no
        // alignment constraints. Raw devices: reads must be block-aligned in
        // BOTH offset and length, so widen the window to block boundaries, read
        // it (chunked under MAXPHYS), then slice out the requested bytes.
        guard let blockSize = rawBlockSize() else {
            return try readRange(offset: offset, length: length)
        }
        let bs = UInt64(blockSize)
        let alignedStart = (offset / bs) * bs
        let alignedEnd = ((offset + UInt64(length) + bs - 1) / bs) * bs
        let alignedLen = Int(alignedEnd - alignedStart)
        let raw = try readRange(offset: alignedStart, length: alignedLen)
        let lead = Int(offset - alignedStart)
        return raw.subdata(in: raw.startIndex.advanced(by: lead)
                              ..< raw.startIndex.advanced(by: lead + length))
    }

    /// Seek to `offset` and read exactly `length` bytes, splitting each
    /// `read(2)` to `readChunkSize` so a raw-device transfer never exceeds
    /// MAXPHYS. Caller guarantees `offset`/`length` satisfy any device
    /// alignment requirement.
    private func readRange(offset: UInt64, length: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
        } catch {
            throw NTFSError.ioFailure(description: "seek to offset \(offset) failed: \(error)")
        }
        var result = Data()
        result.reserveCapacity(length)
        var remaining = length
        while remaining > 0 {
            let thisChunk = min(Self.readChunkSize, remaining)
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: thisChunk)
            } catch {
                throw NTFSError.ioFailure(
                    description: "read at offset \(offset + UInt64(length - remaining)) length \(thisChunk) failed: \(error)"
                )
            }
            guard let chunk, !chunk.isEmpty else {
                throw NTFSError.shortRead(expected: length, got: length - remaining)
            }
            result.append(chunk)
            remaining -= chunk.count
        }
        return result
    }

    /// Chunk size for raw-device writes. macOS's BSD block layer caps a
    /// single `write(2)` to `MAXPHYS` (~1 MiB on stock macOS); larger
    /// `write()` calls to `/dev/diskN` return `EINVAL`. The mkntfs path
    /// (v0.6) builds large initial regions (e.g. a multi-GiB `$MFT` zone
    /// on 4 TB volumes) as one `Data` and writes them via this function,
    /// so we chunk every write through a safe-for-macOS-raw-device
    /// granularity. Regular files (`.img` fixtures) handle larger writes
    /// fine, but chunking is harmless there — uniform behaviour, one
    /// place to keep correct.
    static let writeChunkSize: Int = 1 * 1024 * 1024   // 1 MiB

    public func write(offset: UInt64, bytes: Data) async throws {
        guard isWritable else { throw NTFSError.readOnlyDevice }
        if bytes.isEmpty { return }

        // Regular files: write the bytes directly (chunked only for MAXPHYS).
        // Raw devices: a write(2) must be block-aligned in BOTH offset AND
        // length, or it returns EINVAL ("Invalid argument") — e.g. an 8-byte
        // $MFT $BITMAP update at a cluster offset. For an already-aligned
        // window, write straight through; otherwise read-modify-write the
        // surrounding block(s) so only the requested bytes change.
        guard let blockSize = rawBlockSize() else {
            try writeRangeChunked(offset: offset, bytes: bytes)
            return
        }
        let bs = UInt64(blockSize)
        let end = offset + UInt64(bytes.count)
        if offset % bs == 0, end % bs == 0 {
            try writeRangeChunked(offset: offset, bytes: bytes)
            return
        }
        // Sub-block write: widen to block boundaries, patch, write back.
        let alignedStart = (offset / bs) * bs
        let alignedEnd = ((end + bs - 1) / bs) * bs
        let alignedLen = Int(alignedEnd - alignedStart)
        var window = try readRange(offset: alignedStart, length: alignedLen)
        let lead = Int(offset - alignedStart)
        window.replaceSubrange(
            window.startIndex.advanced(by: lead)..<window.startIndex.advanced(by: lead + bytes.count),
            with: bytes
        )
        try writeRangeChunked(offset: alignedStart, bytes: window)
    }

    /// Seek to `offset` and write `bytes`, splitting each `write(2)` to
    /// `writeChunkSize` so a raw-device transfer never exceeds MAXPHYS. Caller
    /// guarantees `offset`/`bytes.count` satisfy any device alignment.
    private func writeRangeChunked(offset: UInt64, bytes: Data) throws {
        do {
            try handle.seek(toOffset: offset)
        } catch {
            throw NTFSError.ioFailure(description: "seek to offset \(offset) for write failed: \(error)")
        }
        let total = bytes.count
        var written = 0
        while written < total {
            let thisChunk = min(Self.writeChunkSize, total - written)
            let lo = bytes.index(bytes.startIndex, offsetBy: written)
            let hi = bytes.index(lo, offsetBy: thisChunk)
            // Data(...) copy ensures the slice is contiguous; FileHandle's
            // write(contentsOf:) accepts any DataProtocol but a fresh Data
            // sidesteps any slice-backing-store quirks across Swift versions.
            let slice = Data(bytes[lo..<hi])
            do {
                try handle.write(contentsOf: slice)
            } catch {
                throw NTFSError.ioFailure(
                    description: "write at offset \(offset + UInt64(written)) length \(thisChunk) failed (chunk \(written)/\(total)): \(error)"
                )
            }
            written += thisChunk
        }
    }

    /// Discover the usable byte size of the device or .img file. For
    /// regular files (.img fixtures) uses fstat; for raw block devices
    /// (/dev/diskN, /dev/rdiskN) uses ioctl(DKIOCGETBLOCKSIZE) +
    /// ioctl(DKIOCGETBLOCKCOUNT). Sized for the v0.6 mkntfs path which
    /// needs to know the device size before laying out system files.
    public func size() async throws -> UInt64 {
        let fd = handle.fileDescriptor
        var st = stat()
        if fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
            return UInt64(st.st_size)
        }
        // Raw block device — ioctl path. macOS ioctl numbers from <sys/disk.h>:
        //   DKIOCGETBLOCKSIZE  = _IOR('d', 24, uint32_t) = 0x40046418
        //   DKIOCGETBLOCKCOUNT = _IOR('d', 25, uint64_t) = 0x40086419
        let DKIOCGETBLOCKSIZE: UInt = 0x40046418
        let DKIOCGETBLOCKCOUNT: UInt = 0x40086419
        var blockSize: UInt32 = 0
        var blockCount: UInt64 = 0
        if ioctl(fd, DKIOCGETBLOCKSIZE, &blockSize) != 0 {
            throw NTFSError.ioFailure(description: "size(): DKIOCGETBLOCKSIZE failed errno=\(errno)")
        }
        if ioctl(fd, DKIOCGETBLOCKCOUNT, &blockCount) != 0 {
            throw NTFSError.ioFailure(description: "size(): DKIOCGETBLOCKCOUNT failed errno=\(errno)")
        }
        return blockCount * UInt64(blockSize)
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
