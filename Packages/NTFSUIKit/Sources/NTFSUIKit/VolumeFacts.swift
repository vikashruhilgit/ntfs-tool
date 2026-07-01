import Foundation
import NTFSCore

/// Raw, source-of-truth numbers read from `NTFSCore.Volume` for a single volume.
/// This is a plain `Sendable` value type — it carries no SwiftUI dependency, so
/// the mapping into display strings (`VolumeInfoFormatter`) is purely testable.
public struct VolumeFacts: Equatable, Sendable {
    /// Human-facing label (from DiskArbitration; NTFSCore exposes no $Volume name).
    public var label: String
    /// BSD device path, e.g. `/dev/disk6s1`.
    public var devicePath: String
    /// `boot.totalSectors * bytesPerSector`.
    public var totalBytes: UInt64
    /// Free bytes from `$Bitmap` (`AllocationStats.freeBytes`).
    public var freeBytes: UInt64
    /// Allocated bytes from `$Bitmap` (`AllocationStats.allocatedBytes`).
    public var usedBytes: UInt64
    /// `volume.bytesPerCluster`.
    public var bytesPerCluster: UInt32
    /// `volume.mftByteOffset` — byte offset of `$MFT` from the volume start.
    /// `nil` when the NTFS-internal facts weren't read from the device (e.g. the
    /// volume is mounted and only `statfs` numbers are available).
    public var mftByteOffset: UInt64?
    /// First `$MFT` cluster (`boot.mftCluster`). `nil` when not read from device.
    public var mftCluster: UInt64?
    /// `$Volume` dirty flag. `nil` when not read from device.
    public var isDirty: Bool?
    /// NTFS major version (typically 3). `nil` when not read from device.
    public var ntfsMajorVersion: UInt8?
    /// NTFS minor version (typically 1). `nil` when not read from device.
    public var ntfsMinorVersion: UInt8?
    /// Whether the mount is writable. Read-only path today.
    public var isWritable: Bool

    /// True when the NTFS-internal facts (MFT location, version, dirty flag) were
    /// actually read off the device. False when only the non-privileged `statfs`
    /// numbers are available (volume mounted, raw device not readable).
    public var ntfsDetailsAvailable: Bool { isDirty != nil }

    public init(
        label: String,
        devicePath: String,
        totalBytes: UInt64,
        freeBytes: UInt64,
        usedBytes: UInt64,
        bytesPerCluster: UInt32,
        mftByteOffset: UInt64? = nil,
        mftCluster: UInt64? = nil,
        isDirty: Bool? = nil,
        ntfsMajorVersion: UInt8? = nil,
        ntfsMinorVersion: UInt8? = nil,
        isWritable: Bool
    ) {
        self.label = label
        self.devicePath = devicePath
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.bytesPerCluster = bytesPerCluster
        self.mftByteOffset = mftByteOffset
        self.mftCluster = mftCluster
        self.isDirty = isDirty
        self.ntfsMajorVersion = ntfsMajorVersion
        self.ntfsMinorVersion = ntfsMinorVersion
        self.isWritable = isWritable
    }
}
