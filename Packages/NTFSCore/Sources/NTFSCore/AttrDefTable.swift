// AttrDefTable.swift
//
// The canonical NTFS 3.1 $AttrDef table: 16 entries × 160 bytes = 2,560 bytes
// total. Each entry describes one attribute type's name, type code, collation
// rule, flags, and resident-size bounds.
//
// On-disk layout (per entry, all multi-byte fields little-endian):
//   0x00  WCHAR  name[64]    — UTF-16 name, null-padded to 128 bytes
//   0x80  u32    type        — attribute type code (0x10..0x100)
//   0x84  u32    displayRule
//   0x88  u32    collationRule
//   0x8C  u32    flags       — bit 1: indexable; bit 6: resident; bit 7: never-non-resident
//   0x90  u64    minSize     — minimum attribute value size
//   0x98  u64    maxSize     — maximum attribute value size (0xFFFF_FFFF_FFFF_FFFF = unlimited)
//
// Source of truth: the NTFS 3.1 on-disk specification as documented by the
// Linux-NTFS project (https://flatcap.github.io/linux-ntfs/ntfs/concepts/attribute_definitions.html)
// and the Microsoft NTFS file system reference. The exact byte sequence
// below matches what `mkntfs -Q` produces and what Windows ships on a
// freshly formatted NTFS 3.1 volume.
//
// CLEAN-ROOM: this table was derived from the public NTFS spec, NOT copied
// from any GPL source (`ntfsprogs`/`ntfs-3g`/Linux kernel `fs/ntfs3`).
// The constants below are the NTFS spec-mandated values.

import Foundation

public enum AttrDefTable {
    /// The full 2,560-byte $AttrDef table, ready to be written to disk.
    public static let data: Data = {
        var d = Data(count: 2560)
        for (i, entry) in entries.enumerated() {
            let base = i * 160
            // Name (UTF-16LE, null-padded to 128 bytes).
            let nameUTF16 = Array(entry.name.utf16)
            for (j, codeUnit) in nameUTF16.enumerated() where j < 64 {
                d[base + 2 * j]     = UInt8(codeUnit & 0xFF)
                d[base + 2 * j + 1] = UInt8((codeUnit >> 8) & 0xFF)
            }
            // u32 type at +128
            writeU32LE(into: &d, at: base + 128, entry.type)
            // u32 displayRule at +132
            writeU32LE(into: &d, at: base + 132, entry.displayRule)
            // u32 collationRule at +136
            writeU32LE(into: &d, at: base + 136, entry.collationRule)
            // u32 flags at +140
            writeU32LE(into: &d, at: base + 140, entry.flags)
            // u64 minSize at +144
            writeU64LE(into: &d, at: base + 144, entry.minSize)
            // u64 maxSize at +152
            writeU64LE(into: &d, at: base + 152, entry.maxSize)
        }
        return d
    }()

    /// One row of the $AttrDef table.
    public struct Entry: Sendable {
        public let name: String
        public let type: UInt32
        public let displayRule: UInt32
        public let collationRule: UInt32
        public let flags: UInt32
        public let minSize: UInt64
        public let maxSize: UInt64
    }

    /// NTFS 3.1 canonical 16-entry table. Order matters — the table is
    /// implicitly indexed by row in the spec.
    public static let entries: [Entry] = [
        // 1. $STANDARD_INFORMATION
        .init(name: "$STANDARD_INFORMATION", type: 0x10, displayRule: 0, collationRule: 0,
              flags: 0x40, minSize: 48, maxSize: 72),
        // 2. $ATTRIBUTE_LIST
        .init(name: "$ATTRIBUTE_LIST", type: 0x20, displayRule: 0, collationRule: 0,
              flags: 0x06, minSize: 0, maxSize: 0xFFFF_FFFF_FFFF_FFFF),
        // 3. $FILE_NAME
        .init(name: "$FILE_NAME", type: 0x30, displayRule: 0, collationRule: 1,
              flags: 0x42, minSize: 68, maxSize: 578),
        // 4. $OBJECT_ID  (NTFS 3.0+)
        .init(name: "$OBJECT_ID", type: 0x40, displayRule: 0, collationRule: 0,
              flags: 0x40, minSize: 0, maxSize: 256),
        // 5. $SECURITY_DESCRIPTOR
        .init(name: "$SECURITY_DESCRIPTOR", type: 0x50, displayRule: 0, collationRule: 0,
              flags: 0x42, minSize: 0, maxSize: 0xFFFF_FFFF_FFFF_FFFF),
        // 6. $VOLUME_NAME
        .init(name: "$VOLUME_NAME", type: 0x60, displayRule: 0, collationRule: 0,
              flags: 0x02, minSize: 2, maxSize: 256),
        // 7. $VOLUME_INFORMATION
        .init(name: "$VOLUME_INFORMATION", type: 0x70, displayRule: 0, collationRule: 0,
              flags: 0x42, minSize: 12, maxSize: 12),
        // 8. $DATA
        .init(name: "$DATA", type: 0x80, displayRule: 0, collationRule: 0,
              flags: 0, minSize: 0, maxSize: 0xFFFF_FFFF_FFFF_FFFF),
        // 9. $INDEX_ROOT
        .init(name: "$INDEX_ROOT", type: 0x90, displayRule: 0, collationRule: 0,
              flags: 0x42, minSize: 0, maxSize: 0xFFFF_FFFF_FFFF_FFFF),
        // 10. $INDEX_ALLOCATION
        .init(name: "$INDEX_ALLOCATION", type: 0xA0, displayRule: 0, collationRule: 0,
              flags: 0x42, minSize: 0, maxSize: 0xFFFF_FFFF_FFFF_FFFF),
        // 11. $BITMAP
        .init(name: "$BITMAP", type: 0xB0, displayRule: 0, collationRule: 0,
              flags: 0x42, minSize: 0, maxSize: 0xFFFF_FFFF_FFFF_FFFF),
        // 12. $REPARSE_POINT (NTFS 3.0+)
        .init(name: "$REPARSE_POINT", type: 0xC0, displayRule: 0, collationRule: 0,
              flags: 0x40, minSize: 0, maxSize: 16384),
        // 13. $EA_INFORMATION
        .init(name: "$EA_INFORMATION", type: 0xD0, displayRule: 0, collationRule: 0,
              flags: 0x42, minSize: 8, maxSize: 8),
        // 14. $EA
        .init(name: "$EA", type: 0xE0, displayRule: 0, collationRule: 0,
              flags: 0, minSize: 0, maxSize: 65536),
        // 15. $PROPERTY_SET (obsolete in 3.1 but present for layout compat)
        .init(name: "$PROPERTY_SET", type: 0xF0, displayRule: 0, collationRule: 0,
              flags: 0, minSize: 0, maxSize: 0xFFFF_FFFF_FFFF_FFFF),
        // 16. $LOGGED_UTILITY_STREAM (NTFS 3.0+ — used by EFS, $TXF_DATA, etc.)
        .init(name: "$LOGGED_UTILITY_STREAM", type: 0x100, displayRule: 0, collationRule: 0,
              flags: 0x42, minSize: 0, maxSize: 65536),
    ]

    private static func writeU32LE(into d: inout Data, at offset: Int, _ value: UInt32) {
        for i in 0..<4 { d[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }
    private static func writeU64LE(into d: inout Data, at offset: Int, _ value: UInt64) {
        for i in 0..<8 { d[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }
}
