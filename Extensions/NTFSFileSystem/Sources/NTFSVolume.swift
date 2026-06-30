import FSKit
import Foundation
import NTFSCore
import os.log

// FSVolume adapter that bridges FSKit's read-side operations onto an
// `NTFSCore.Volume`. Read-only (v1): every mutating operation returns
// EROFS via the standard POSIX-error idiom FSKit recognizes. Write
// support arrives in Phase 5 (Block G of the multi-iteration plan).
@available(macOS 15.4, *)
final class NTFSVolume: FSVolume,
                       FSVolume.Operations,
                       FSVolume.PathConfOperations,
                       FSVolume.ReadWriteOperations,
                       FSVolume.OpenCloseOperations {

    private let log = Logger(subsystem: "com.ntfs-tool.fskit", category: "NTFSVolume")

    /// Internal-visible so NTFSItem can read live MFT records when building
    /// fresh attributes (see NTFSItem.makeFreshAttributes(volume:)).
    let coreVolume: NTFSCore.Volume
    private let isReadOnly: Bool

    /// Cache items by MFT record number so repeated lookups don't allocate.
    /// FSKit hands the same FSItem back through callbacks, so we map by
    /// recordNumber to keep memory bounded.
    private var itemCache: [UInt64: NTFSItem] = [:]
    private let cacheQueue = DispatchQueue(label: "com.ntfs-tool.fskit.NTFSVolume.cache")

    init(coreVolume: NTFSCore.Volume, volumeName: FSFileName, isReadOnly: Bool) {
        self.coreVolume = coreVolume
        self.isReadOnly = isReadOnly
        super.init(
            volumeID: FSVolume.Identifier(uuid: UUID()),
            volumeName: volumeName
        )
    }

    // MARK: - FSVolume.PathConfOperations

    var maximumLinkCount: Int { 1024 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 65_536 }
    var maximumXattrSizeInBits: Int { 16 }
    var maximumFileSize: UInt64 { UInt64.max / 2 }
    var maximumFileSizeInBits: Int { 63 }

    // MARK: - FSVolume.Operations

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = false
        caps.supportsPersistentObjectIDs = true
        caps.supportsHiddenFiles = true
        caps.supportsSparseFiles = true
        caps.supports64BitObjectIDs = true
        caps.supports2TBFiles = true
        return caps
    }

    /// Cached AllocationStats so volumeStatistics is cheap after first call.
    /// FSKit's volumeStatistics is a sync property, so we can't call the
    /// async bitmap() reader here directly — `loadResource` primes the
    /// cache before returning the volume to FSKit.
    nonisolated(unsafe) var cachedAllocationStats: NTFSCore.Volume.AllocationStats?

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "ntfs")
        stats.blockSize = Int(coreVolume.bytesPerCluster)
        stats.ioSize = Int(coreVolume.bytesPerCluster)

        if let alloc = cachedAllocationStats {
            stats.totalBytes = alloc.totalBytes
            stats.freeBytes = alloc.freeBytes
            stats.availableBytes = alloc.freeBytes
            stats.usedBytes = alloc.allocatedBytes
        } else {
            let totalSectors = coreVolume.boot.totalSectors
            let bytesPerSector = UInt64(coreVolume.boot.bytesPerSector)
            let totalBytes = totalSectors * bytesPerSector
            stats.totalBytes = totalBytes
            // Bitmap cache not yet primed — report total as the placeholder
            // and 0 used so Finder shows the volume as "empty" rather than
            // refusing copies. Real numbers land as soon as loadResource's
            // priming completes.
            stats.usedBytes = 0
            stats.freeBytes = totalBytes
            stats.availableBytes = totalBytes
        }
        stats.totalFiles = 0
        stats.freeFiles = 0
        return stats
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (Error?) -> Void) {
        log.info("NTFSVolume.mount: read-only=\(self.isReadOnly, privacy: .public)")
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        log.info("NTFSVolume.unmount")
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable (Error?) -> Void) {
        // Persist all pending metadata + data. endWriteSession flushes the
        // device, clears the dirty bit, and flushes again so a power loss or
        // fast unplug after this point leaves a consistent volume. On a
        // read-only mount there's nothing to flush — succeed immediately.
        if isReadOnly {
            reply(nil)
            return
        }
        Task {
            do {
                try await self.coreVolume.endWriteSession()
                reply(nil)
            } catch {
                self.log.error("synchronize: flush failed: \(error.localizedDescription, privacy: .public)")
                reply(error)
            }
        }
    }

    func activate(
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable (FSItem?, Error?) -> Void
    ) {
        Task {
            let root = NTFSItem.root()
            self.cache(root)
            log.info("NTFSVolume.activate: returning root item (MFT record 5)")
            reply(root, nil)
        }
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping @Sendable (Error?) -> Void) {
        log.info("NTFSVolume.deactivate")
        cacheQueue.sync { itemCache.removeAll() }
        reply(nil)
    }

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let ntfsItem = item as? NTFSItem else {
            reply(nil, posixError(EBADF))
            return
        }

        // If the caller wants any size or time attribute, do a fresh read off
        // the live MFT record so we don't hand back stale $FILE_NAME values
        // (NTFS-by-design quirk: $FILE_NAME sizes/times are written at
        // create/rename and never updated thereafter). For caller requests
        // that only want IDs / type / mode, the cheap snapshot is enough.
        let needsFresh = desiredAttributes.isAttributeWanted(.size)
            || desiredAttributes.isAttributeWanted(.allocSize)
            || desiredAttributes.isAttributeWanted(.modifyTime)
            || desiredAttributes.isAttributeWanted(.changeTime)
            || desiredAttributes.isAttributeWanted(.accessTime)
            || desiredAttributes.isAttributeWanted(.birthTime)
            || desiredAttributes.isAttributeWanted(.flags)
            || desiredAttributes.isAttributeWanted(.linkCount)

        if needsFresh {
            Task {
                do {
                    let fresh = try await ntfsItem.makeFreshAttributes(volume: self)
                    reply(fresh, nil)
                } catch {
                    // Fresh-read failed (record corrupt, IO error, etc) — fall back
                    // to the stale snapshot rather than failing the getattr outright.
                    self.log.warning("getAttributes: fresh read failed for record \(ntfsItem.recordNumber): \(error.localizedDescription, privacy: .public). Returning stale snapshot.")
                    reply(ntfsItem.makeAttributes(volume: self), nil)
                }
            }
        } else {
            reply(ntfsItem.makeAttributes(volume: self), nil)
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let ntfsItem = item as? NTFSItem else {
            reply(nil, posixError(EBADF))
            return
        }

        // Block G stage 5 supports only the size attribute (truncate). Other
        // mutations (uid/gid/mode/timestamps) come later — return EPERM so
        // the kernel knows we acknowledged but won't honor the change.
        let wantsSize = newAttributes.consumedAttributes.contains(.size)

        Task {
            do {
                if wantsSize {
                    try await self.coreVolume.truncate(
                        at: ntfsItem.recordNumber,
                        newSize: newAttributes.size
                    )
                    try? await self.coreVolume.setDirty(false)
                }
                // Return refreshed attributes so the kernel sees the new size.
                let fresh = try await ntfsItem.makeFreshAttributes(volume: self)
                reply(fresh, nil)
            } catch NTFSError.unsupportedFeature {
                reply(nil, self.posixError(ENOTSUP))
            } catch {
                reply(nil, error)
            }
        }
    }

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let parent = directory as? NTFSItem, parent.isDirectory else {
            reply(nil, nil, posixError(ENOTDIR))
            return
        }
        let needle = name.string ?? ""

        Task {
            do {
                let entries = try await self.coreVolume.enumerate(directory: parent.recordNumber)
                if let match = entries.first(where: { $0.name == needle && $0.fileName.namespace != .dos }) {
                    let item = NTFSItem.from(match)
                    self.cache(item)
                    reply(item, FSFileName(string: match.name), nil)
                } else {
                    reply(nil, nil, self.posixError(ENOENT))
                }
            } catch {
                reply(nil, nil, error)
            }
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable (Error?) -> Void) {
        if let ntfsItem = item as? NTFSItem {
            cacheQueue.sync { _ = itemCache.removeValue(forKey: ntfsItem.recordNumber) }
        }
        reply(nil)
    }

    func readSymbolicLink(
        _ item: FSItem,
        replyHandler reply: @escaping @Sendable (FSFileName?, Error?) -> Void
    ) {
        reply(nil, posixError(EINVAL))   // v1 doesn't expose reparse points
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, Error?) -> Void
    ) {
        // Block G stage 5: wire FSKit createItem onto NTFSCore.createFile.
        // Only file + directory item types — symlinks come later.
        guard type == .file || type == .directory else {
            reply(nil, nil, posixError(EINVAL))
            return
        }
        guard let parent = directory as? NTFSItem, parent.isDirectory else {
            reply(nil, nil, posixError(ENOTDIR))
            return
        }
        guard let nameString = name.string else {
            reply(nil, nil, posixError(EINVAL))
            return
        }

        Task {
            do {
                let recordNumber = try await self.coreVolume.createFile(
                    named: nameString,
                    inDirectory: parent.recordNumber,
                    isDirectory: type == .directory
                )
                // Clear the dirty bit after a successful mutation.
                try? await self.coreVolume.setDirty(false)
                // Refresh the parent's child list, find our new entry, build
                // an NTFSItem from the parsed DirectoryEntry.
                let entries = try await self.coreVolume.enumerate(directory: parent.recordNumber)
                guard let entry = entries.first(where: { $0.recordNumber == recordNumber }) else {
                    reply(nil, nil, self.posixError(EIO))
                    return
                }
                let item = NTFSItem.from(entry)
                self.cache(item)
                reply(item, FSFileName(string: nameString), nil)
            } catch NTFSError.unsupportedFeature {
                // LARGE_INDEX parent or other unsupported configuration —
                // surface as POSIX ENOTSUP so the kernel knows it's a
                // missing feature not a permanent error.
                reply(nil, nil, self.posixError(ENOTSUP))
            } catch {
                reply(nil, nil, error)
            }
        }
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, Error?) -> Void
    ) {
        reply(nil, nil, posixError(EROFS))
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSFileName?, Error?) -> Void
    ) {
        reply(nil, posixError(EROFS))
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (Error?) -> Void
    ) {
        guard let ntfsItem = item as? NTFSItem else {
            reply(posixError(EBADF))
            return
        }
        Task {
            do {
                try await self.coreVolume.deleteFile(at: ntfsItem.recordNumber)
                try? await self.coreVolume.setDirty(false)
                self.cacheQueue.sync { _ = self.itemCache.removeValue(forKey: ntfsItem.recordNumber) }
                reply(nil)
            } catch NTFSError.unsupportedFeature {
                reply(self.posixError(ENOTSUP))
            } catch {
                reply(error)
            }
        }
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping @Sendable (FSFileName?, Error?) -> Void
    ) {
        reply(nil, posixError(EROFS))
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, Error?) -> Void
    ) {
        guard let dir = directory as? NTFSItem, dir.isDirectory else {
            reply(verifier, posixError(ENOTDIR))
            return
        }

        Task {
            do {
                let entries = try await self.coreVolume.enumerate(directory: dir.recordNumber)
                // FSKit asks us to skip already-yielded entries via `cookie`. Use
                // the entry index as cookie (stable within one enumerate response;
                // proper cookie-based pagination across calls is future work).
                let startIdx = Int(cookie.rawValue)
                for (i, entry) in entries.enumerated() where i >= startIdx {
                    // Skip DOS-namespace aliases; we present only the Win32 / POSIX
                    // canonical name so Finder doesn't see "HELLO~1.TXT" twice.
                    guard entry.fileName.namespace != .dos else { continue }
                    let item = NTFSItem.from(entry)
                    self.cache(item)
                    let cookieValue = FSDirectoryCookie(rawValue: UInt64(i + 1))
                    let entryItemType: FSItem.ItemType = entry.isDirectory ? .directory : .file
                    // Honor FSKit's reserved IDs — root is .rootDirectory.
                    let itemID = NTFSItem.fskitFileID(forRecordNumber: entry.recordNumber)
                    let kept = packer.packEntry(
                        name: FSFileName(string: entry.name),
                        itemType: entryItemType,
                        itemID: itemID,
                        nextCookie: cookieValue,
                        attributes: item.makeAttributes(volume: self)
                    )
                    if !kept { break }
                }
                reply(verifier, nil)
            } catch {
                reply(verifier, error)
            }
        }
    }

    // MARK: - FSVolume.ReadWriteOperations

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping @Sendable (Int, Error?) -> Void
    ) {
        guard let ntfsItem = item as? NTFSItem, !ntfsItem.isDirectory else {
            reply(0, posixError(EISDIR))
            return
        }
        // POSIX: negative offset is EINVAL. Reject before any UInt cast trap.
        if offset < 0 {
            reply(0, posixError(EINVAL))
            return
        }
        if length <= 0 {
            reply(0, nil)
            return
        }

        Task {
            do {
                // Slice the file by offset+length instead of re-reading the
                // whole file on every kernel callback. Earlier versions did
                // a full readFile per call — quadratic IO that stalled even
                // moderate-size Finder opens. NTFSCore.Volume.readFileSlice
                // walks only the extents that overlap the requested window.
                let slice = try await self.coreVolume.readFileSlice(
                    at: ntfsItem.recordNumber,
                    offset: UInt64(offset),
                    length: length
                )
                if slice.isEmpty {
                    reply(0, nil)
                    return
                }
                // Use copyBytes's actual return value so reported count is
                // provably consistent with what was written, even if a
                // future FSKit bumps buffer-size contract semantics.
                let actuallyCopied = buffer.withUnsafeMutableBytes { dest -> Int in
                    slice.copyBytes(to: dest.bindMemory(to: UInt8.self))
                }
                reply(actuallyCopied, nil)
            } catch {
                reply(0, error)
            }
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping @Sendable (Int, Error?) -> Void
    ) {
        guard let ntfsItem = item as? NTFSItem, !ntfsItem.isDirectory else {
            reply(0, posixError(EISDIR))
            return
        }
        if offset < 0 {
            reply(0, posixError(EINVAL))
            return
        }
        Task {
            do {
                try await self.coreVolume.write(
                    at: ntfsItem.recordNumber,
                    offset: UInt64(offset),
                    bytes: contents
                )
                try? await self.coreVolume.setDirty(false)
                reply(contents.count, nil)
            } catch NTFSError.unsupportedFeature {
                reply(0, self.posixError(ENOTSUP))
            } catch {
                reply(0, error)
            }
        }
    }

    // MARK: - FSVolume.OpenCloseOperations

    func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping @Sendable (Error?) -> Void
    ) {
        // Block G stage 5: writes are wired up at the volume level. Accept
        // any open mode; individual mutating callbacks still gate on item
        // type + reserved-record checks via NTFSCore. If the volume was
        // explicitly opened read-only by FSKit, reject writes here.
        if modes.contains(.write) && self.isReadOnly {
            reply(posixError(EROFS))
            return
        }
        reply(nil)
    }

    func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping @Sendable (Error?) -> Void
    ) {
        reply(nil)
    }

    // MARK: - Helpers

    private func cache(_ item: NTFSItem) {
        cacheQueue.sync { itemCache[item.recordNumber] = item }
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }
}
