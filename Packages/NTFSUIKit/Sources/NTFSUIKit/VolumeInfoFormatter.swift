import Foundation
import NTFSCore

/// Pure, SwiftUI-free mapper turning the raw `VolumeFacts` (and the underlying
/// `AllocationStats` + boot-derived numbers) into the display fields the
/// dashboard / Volume Info view renders. Everything here is deterministic and
/// unit-tested without any UI.
public struct VolumeInfoFormatter: Sendable {

    public init() {}

    /// Format a byte count using base-1000 ("GB") units to match `ntfsctl info`
    /// and Finder's reporting, with one fractional digit for GB/TB.
    public static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1000 && idx < units.count - 1 {
            value /= 1000
            idx += 1
        }
        if idx == 0 {
            return "\(bytes) B"
        }
        // No fractional part below MB; one decimal for MB and up.
        let formatted = String(format: idx >= 2 ? "%.1f" : "%.0f", value)
        return "\(formatted) \(units[idx])"
    }

    /// Cluster size rendered like the mock ("4 KB").
    public static func clusterSize(_ bytesPerCluster: UInt32) -> String {
        humanBytes(UInt64(bytesPerCluster))
    }

    /// Percent of capacity used, clamped to `0...1`. Derived from used/total so
    /// it tracks the `$Bitmap` allocation, not a hardcoded value.
    public static func percentUsed(used: UInt64, total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        let ratio = Double(used) / Double(total)
        return min(max(ratio, 0), 1)
    }

    /// Percent-used as an integer-ish display string ("61.6%").
    public static func percentUsedLabel(used: UInt64, total: UInt64) -> String {
        let pct = percentUsed(used: used, total: total) * 100
        return String(format: "%.1f%%", pct)
    }

    /// `$MFT` location as a cluster-and-offset description for the Info view.
    public static func mftLocation(cluster: UInt64, byteOffset: UInt64) -> String {
        "cluster \(cluster) (offset \(humanBytes(byteOffset)))"
    }

    /// NTFS version string ("NTFS 3.1").
    public static func versionLabel(major: UInt8, minor: UInt8) -> String {
        "NTFS \(major).\(minor)"
    }

    /// Health/clean status text.
    public static func healthStatus(isDirty: Bool) -> String {
        isDirty ? "Dirty" : "Clean"
    }

    /// Permission text from the mount writability.
    public static func permissionLabel(isWritable: Bool) -> String {
        isWritable ? "Read/Write" : "Read-only"
    }
}
