import Foundation

// Parser + serializer for the $VOLUME_INFORMATION attribute (type 0x70), stored
// resident in MFT record 3 ($Volume). NTFS uses this attribute's `flags` field
// to track filesystem state across mount cycles:
//
//   bit 0x0001 — VOLUME_IS_DIRTY: chkdsk / ntfsfix should scan
//   bit 0x0002 — VOLUME_RESIZE_LOG_FILE
//   bit 0x0004 — VOLUME_UPGRADE_ON_MOUNT
//   bit 0x0008 — VOLUME_MOUNTED_ON_NT4
//   bit 0x0010 — VOLUME_DELETE_USN_UNDERWAY
//   bit 0x0020 — VOLUME_REPAIR_OBJECT_IDS
//   bit 0x8000 — VOLUME_MODIFIED_BY_CHKDSK
//
// On-disk layout (12 bytes):
//   0   u64  reserved (always 0)
//   8   u8   major version (typically 3)
//   9   u8   minor version (typically 1)
//   10  u16  flags
//
// Block G stage 5 only cares about VOLUME_IS_DIRTY: we clear it after a
// successful mutation to tell chkdsk / ntfsfix "no journal replay needed".
public struct VolumeInformation: Sendable, Equatable {

    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let isDirty               = Flags(rawValue: 0x0001)
        public static let resizeLogFile         = Flags(rawValue: 0x0002)
        public static let upgradeOnMount        = Flags(rawValue: 0x0004)
        public static let mountedOnNT4          = Flags(rawValue: 0x0008)
        public static let deleteUSNUnderway     = Flags(rawValue: 0x0010)
        public static let repairObjectIDs       = Flags(rawValue: 0x0020)
        public static let modifiedByChkdsk      = Flags(rawValue: 0x8000)
    }

    public let majorVersion: UInt8
    public let minorVersion: UInt8
    public let flags: Flags

    public static let onDiskSize = 12

    public static func parse(_ data: Data) throws -> VolumeInformation {
        guard data.count >= onDiskSize else {
            throw NTFSError.corruptOnDisk(
                description: "$VOLUME_INFORMATION too short: \(data.count) < \(onDiskSize)"
            )
        }
        return VolumeInformation(
            majorVersion: try data.readU8(at: 8),
            minorVersion: try data.readU8(at: 9),
            flags: Flags(rawValue: try data.readU16LE(at: 10))
        )
    }

    /// Serialize back to the 12-byte on-disk form.
    public func serialize() -> Data {
        var data = Data(count: Self.onDiskSize)
        MFTRecord.writeU64LE(into: &data, at: 0, value: 0)              // reserved
        data[8] = majorVersion
        data[9] = minorVersion
        MFTRecord.writeU16LE(into: &data, at: 10, value: flags.rawValue)
        return data
    }

    public func setting(_ flag: Flags, to value: Bool) -> VolumeInformation {
        var newFlags = flags
        if value { newFlags.insert(flag) } else { newFlags.remove(flag) }
        return VolumeInformation(
            majorVersion: majorVersion,
            minorVersion: minorVersion,
            flags: newFlags
        )
    }
}
