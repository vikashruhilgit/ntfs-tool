import FSKit
import Foundation
import NTFSCore

// One filesystem item exposed through FSKit. Identity is the underlying MFT
// record number (it survives volume restarts and is unique within the
// volume). We hold a snapshot of the parsed $FILE_NAME so attribute lookups
// don't require re-reading the MFT record on every getAttributes() call.
@available(macOS 15.4, *)
final class NTFSItem: FSItem {
    /// MFT record number — the durable identity NTFS gives every file/dir.
    let recordNumber: UInt64

    /// Parent directory MFT record number (5 for root's children).
    let parentRecordNumber: UInt64

    /// FSKit needs an item name on lookup/enumerate replies. We keep the
    /// original $FILE_NAME (UTF-16-decoded) here for cheap reuse.
    let displayName: String

    /// Cached attributes from when we parsed this item. Refreshed on
    /// getAttributes() callbacks if the caller wants more than these basics.
    let isDirectory: Bool
    let realSize: UInt64
    let allocatedSize: UInt64
    let creationTime: Date?
    let modificationTime: Date?
    let accessTime: Date?
    let mftChangeTime: Date?

    init(
        recordNumber: UInt64,
        parentRecordNumber: UInt64,
        displayName: String,
        isDirectory: Bool,
        realSize: UInt64,
        allocatedSize: UInt64,
        creationTime: Date?,
        modificationTime: Date?,
        accessTime: Date?,
        mftChangeTime: Date?
    ) {
        self.recordNumber = recordNumber
        self.parentRecordNumber = parentRecordNumber
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.realSize = realSize
        self.allocatedSize = allocatedSize
        self.creationTime = creationTime
        self.modificationTime = modificationTime
        self.accessTime = accessTime
        self.mftChangeTime = mftChangeTime
        super.init()
    }

    /// Build an NTFSItem from a parsed directory entry coming out of
    /// `Volume.enumerate(directory:)`.
    static func from(_ entry: DirectoryEntry) -> NTFSItem {
        NTFSItem(
            recordNumber: entry.recordNumber,
            parentRecordNumber: entry.fileName.parentRecordNumber,
            displayName: entry.name,
            isDirectory: entry.isDirectory,
            realSize: entry.fileName.realSize,
            allocatedSize: entry.fileName.allocatedSize,
            creationTime: entry.fileName.creationTime,
            modificationTime: entry.fileName.modificationTime,
            accessTime: entry.fileName.accessTime,
            mftChangeTime: entry.fileName.mftChangeTime
        )
    }

    /// Build a synthetic root NTFSItem (MFT record 5 is the NTFS root directory).
    static func root() -> NTFSItem {
        NTFSItem(
            recordNumber: 5,
            parentRecordNumber: 5,         // root is its own parent in NTFS
            displayName: "/",
            isDirectory: true,
            realSize: 0,
            allocatedSize: 0,
            creationTime: nil,
            modificationTime: nil,
            accessTime: nil,
            mftChangeTime: nil
        )
    }

    /// Convert this item's metadata into an FSItem.Attributes wrapper for FSKit.
    func makeAttributes(volume: NTFSVolume) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.fileID = FSItem.Identifier(rawValue: recordNumber) ?? .invalid
        attrs.parentID = FSItem.Identifier(rawValue: parentRecordNumber) ?? .invalid
        attrs.type = isDirectory ? .directory : .file
        attrs.linkCount = 1
        // Read-only mount: every file is read-execute for everyone, every
        // directory adds traverse. Real POSIX-from-NT-ACL mapping is a v2
        // problem (CLAUDE.md non-goal for v1).
        attrs.mode = isDirectory ? 0o555 : 0o444
        attrs.uid = 0
        attrs.gid = 0
        attrs.flags = 0
        attrs.size = realSize
        attrs.allocSize = allocatedSize
        attrs.modifyTime = timespecOrZero(modificationTime)
        attrs.changeTime = timespecOrZero(mftChangeTime)
        attrs.accessTime = timespecOrZero(accessTime)
        attrs.birthTime = timespecOrZero(creationTime)
        attrs.addedTime = timespecOrZero(creationTime)
        attrs.backupTime = timespec(tv_sec: 0, tv_nsec: 0)
        _ = volume  // currently unused; kept for future per-volume metadata enrichment
        return attrs
    }

    private func timespecOrZero(_ date: Date?) -> timespec {
        guard let date = date else { return timespec(tv_sec: 0, tv_nsec: 0) }
        let interval = date.timeIntervalSince1970
        let seconds = Int(interval)
        let nanos = Int((interval - Double(seconds)) * 1_000_000_000)
        return timespec(tv_sec: seconds, tv_nsec: nanos)
    }
}
