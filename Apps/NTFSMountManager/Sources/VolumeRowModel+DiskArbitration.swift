import Foundation
import NTFSUIKit

extension DiskArbitrationService.Volume {
    /// Build a design-system row model from the DiskArbitration-derived volume.
    /// `extensionActive` reflects the FSKit extension lifecycle; `freeFraction`
    /// is filled in later once `$Bitmap` has been read via NTFSCore.
    func rowModel(extensionActive: Bool, freeFraction: Double? = nil) -> VolumeRowModel {
        let subtitle: String
        if let mount = mountPoint {
            subtitle = "/dev/\(id) · \(mount)"
        } else {
            subtitle = "/dev/\(id) · not mounted"
        }
        return VolumeRowModel(
            id: id,
            title: displayName,
            subtitle: subtitle,
            isMounted: isMounted,
            // The mount is read-only in this read-only GUI block.
            isWritable: false,
            extensionActive: extensionActive,
            freeFraction: freeFraction,
            capacityDisplay: mediaSize.map { VolumeInfoFormatter.humanBytes($0) }
        )
    }

    /// BSD device path for raw NTFSCore reads.
    var devicePath: String { "/dev/\(id)" }
}
