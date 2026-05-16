import Foundation

// Standard NTFS attribute type codes. Values are the on-disk u32 type field
// at offset 0 of each attribute. The end-of-attributes marker is 0xFFFFFFFF,
// which deliberately does not have a case in this enum — see Attribute.iterate.
//
// Reference: Linux-NTFS docs https://flatcap.github.io/linux-ntfs/ntfs/attributes/
public enum AttributeType: UInt32, Sendable, CaseIterable {
    case standardInformation  = 0x10
    case attributeList        = 0x20
    case fileName             = 0x30
    case objectID             = 0x40
    case securityDescriptor   = 0x50
    case volumeName           = 0x60
    case volumeInformation    = 0x70
    case data                 = 0x80
    case indexRoot            = 0x90
    case indexAllocation      = 0xA0
    case bitmap               = 0xB0
    case reparsePoint         = 0xC0
    case eaInformation        = 0xD0
    case ea                   = 0xE0
    case propertySet          = 0xF0
    case loggedUtilityStream  = 0x100

    public static let endMarker: UInt32 = 0xFFFF_FFFF
}
