import Foundation

// Parser for the $STANDARD_INFORMATION attribute body (type 0x10).
//
// $STANDARD_INFORMATION holds the file's "real" times + DOS file attributes,
// kept current on every metadata change. (Compare to $FILE_NAME, whose
// timestamps and sizes are only updated at create/rename and are otherwise
// stale.)
//
// Two on-disk layouts exist:
//   v1.2 (NTFS 1.2 / Windows NT 4): 48 bytes (just times + DOS flags + version
//                                   counters)
//   v3.0 (NTFS 3.0+ / Windows 2000+): 72 bytes (adds ownerID, securityID,
//                                     quotaCharged, USN)
//
// We parse the first 48 bytes (always present) and expose the optional v3
// tail when the attribute is long enough. NTFS volumes formatted by every
// modern Windows / mkntfs are v3.
public struct StandardInformation: Sendable, Equatable {
    public let creationTime: Date?
    public let modificationTime: Date?
    public let mftChangeTime: Date?
    public let accessTime: Date?

    /// DOS-style file-attribute flags: READ_ONLY=0x01, HIDDEN=0x02,
    /// SYSTEM=0x04, ARCHIVE=0x20, etc. NTFS also overloads high bits, but
    /// for the FSKit bridge we only need to know about the standard set
    /// (Block G will surface ARCHIVE / READ_ONLY mapping into POSIX modes).
    public let fileAttributes: UInt32

    /// v3.0-only fields (nil on v1.2 volumes).
    public let ownerID: UInt32?
    public let securityID: UInt32?
    public let quotaCharged: UInt64?
    public let updateSequenceNumber: UInt64?

    public static let v12Size = 48
    public static let v30Size = 72

    public static func parse(_ data: Data) throws -> StandardInformation {
        guard data.count >= v12Size else {
            throw NTFSError.corruptOnDisk(
                description: "$STANDARD_INFORMATION too short: \(data.count) < \(v12Size)"
            )
        }

        let v3 = data.count >= v30Size
        return StandardInformation(
            creationTime:     filetime(try data.readU64LE(at: 0)),
            modificationTime: filetime(try data.readU64LE(at: 8)),
            mftChangeTime:    filetime(try data.readU64LE(at: 16)),
            accessTime:       filetime(try data.readU64LE(at: 24)),
            fileAttributes:   try data.readU32LE(at: 32),
            ownerID:              v3 ? try data.readU32LE(at: 48) : nil,
            securityID:           v3 ? try data.readU32LE(at: 52) : nil,
            quotaCharged:         v3 ? try data.readU64LE(at: 56) : nil,
            updateSequenceNumber: v3 ? try data.readU64LE(at: 64) : nil
        )
    }

    /// Convert a Windows FILETIME (100-ns intervals since 1601-01-01 UTC) to
    /// a Date. Returns nil for the sentinel zero value. Same logic as
    /// FileName's helper — Block G will collapse these into one place.
    private static func filetime(_ raw: UInt64) -> Date? {
        if raw == 0 { return nil }
        let secondsBetweenEpochs: TimeInterval = 11_644_473_600
        let seconds = TimeInterval(raw) / 10_000_000 - secondsBetweenEpochs
        return Date(timeIntervalSince1970: seconds)
    }
}
