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
    ///
    /// FSKit reserves three `FSItem.Identifier` rawValues:
    ///   0 = .invalid
    ///   1 = .parentOfRoot
    ///   2 = .rootDirectory
    /// Our root (NTFS MFT record 5) must be presented as `.rootDirectory` so
    /// vfs/Finder can recognize it; its parent must be `.parentOfRoot`; and
    /// any child whose NTFS parentRecordNumber is 5 must report
    /// `.rootDirectory` as its parent (NOT raw 5). Without this mapping FSKit
    /// can't identify the root for mount/traversal, producing the
    /// "Finder shows the volume but won't browse it" failure mode.
    func makeAttributes(volume: NTFSVolume) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.fileID = Self.fskitFileID(forRecordNumber: recordNumber)
        attrs.parentID = Self.fskitParentID(forRecordNumber: parentRecordNumber, selfRecordNumber: recordNumber)
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

    /// Produce attributes refreshed from the live MFT record — read
    /// `$STANDARD_INFORMATION` for canonical timestamps and the unnamed
    /// `$DATA` attribute for the real file size. The cheap `makeAttributes`
    /// path uses `$FILE_NAME` values which are populated at create/rename
    /// and never updated after, so a file written after creation shows
    /// `size: 0` and stale timestamps. Use this path from any getAttributes
    /// callback that wants the truth.
    ///
    /// Per-call cost is one MFT record read + an attribute walk. For bulk
    /// directory listings that doesn't want this overhead, the cheap path
    /// remains available.
    func makeFreshAttributes(volume: NTFSVolume) async throws -> FSItem.Attributes {
        let coreVolume = volume.coreVolume
        let mft = await coreVolume.mft()
        let record = try await mft.record(at: recordNumber)
        let attrs = try record.attributes()

        // Start from the cheap snapshot, then overwrite the fields that the
        // live record gives us better values for.
        let result = makeAttributes(volume: volume)

        if let siAttr = attrs.first(where: { $0.type == .standardInformation }),
           case let .resident(siBytes, _) = siAttr.value,
           let si = try? StandardInformation.parse(siBytes) {
            result.modifyTime = Self.makeTimespec(from: si.modificationTime)
            result.changeTime = Self.makeTimespec(from: si.mftChangeTime)
            result.accessTime = Self.makeTimespec(from: si.accessTime)
            result.birthTime  = Self.makeTimespec(from: si.creationTime)
            result.addedTime  = Self.makeTimespec(from: si.creationTime)
            result.flags      = si.fileAttributes
        }

        // The unnamed $DATA can migrate out of the base record into an
        // extension record (base then carries an $ATTRIBUTE_LIST). Read it via
        // the $ATTRIBUTE_LIST-aware union so a migrated file's size/allocSize
        // reflect the real $DATA rather than falling back to a stale
        // $FILE_NAME value (typically 0). $STANDARD_INFORMATION and
        // hardLinkCount stay in the base record and are read above/below.
        let allAttrs = try await coreVolume.allAttributesOf(recordNumber: recordNumber)
        if let dataAttr = allAttrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) {
            switch dataAttr.value {
            case let .resident(bytes, _):
                result.size = UInt64(bytes.count)
                result.allocSize = UInt64(bytes.count)
            case let .nonResident(_, _, _, _, allocatedSize, realSize, _, _):
                result.size = realSize
                result.allocSize = allocatedSize
            }
        }

        result.linkCount = UInt32(record.hardLinkCount)
        result.type = record.isDirectory ? .directory : .file

        return result
    }

    private static func makeTimespec(from date: Date?) -> Darwin.timespec {
        guard let date = date else { return Darwin.timespec(tv_sec: 0, tv_nsec: 0) }
        let interval = date.timeIntervalSince1970
        let seconds = Int(interval)
        let nanos = Int((interval - Double(seconds)) * 1_000_000_000)
        return Darwin.timespec(tv_sec: seconds, tv_nsec: nanos)
    }

    /// MFT record number of NTFS's root directory. Static for use from
    /// `enumerateDirectory` where we don't have an NTFSItem instance yet.
    static let rootRecordNumber: UInt64 = 5

    /// Map an NTFS MFT record number to an FSItem.Identifier honoring the
    /// FSKit reserved values (.rootDirectory for record 5).
    static func fskitFileID(forRecordNumber recordNumber: UInt64) -> FSItem.Identifier {
        if recordNumber == rootRecordNumber { return .rootDirectory }
        return FSItem.Identifier(rawValue: recordNumber) ?? .invalid
    }

    /// Map a parent's NTFS MFT record number to an FSItem.Identifier. The
    /// root's parent is `.parentOfRoot`; root's children report `.rootDirectory`
    /// for their parent.
    static func fskitParentID(
        forRecordNumber parentRecordNumber: UInt64,
        selfRecordNumber: UInt64
    ) -> FSItem.Identifier {
        if selfRecordNumber == rootRecordNumber { return .parentOfRoot }
        if parentRecordNumber == rootRecordNumber { return .rootDirectory }
        return FSItem.Identifier(rawValue: parentRecordNumber) ?? .invalid
    }

    private func timespecOrZero(_ date: Date?) -> timespec {
        guard let date = date else { return timespec(tv_sec: 0, tv_nsec: 0) }
        let interval = date.timeIntervalSince1970
        let seconds = Int(interval)
        let nanos = Int((interval - Double(seconds)) * 1_000_000_000)
        return timespec(tv_sec: seconds, tv_nsec: nanos)
    }
}
