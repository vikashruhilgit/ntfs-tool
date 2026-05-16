import Foundation

// Parsed $FILE_NAME attribute (type 0x30). Embedded in MFT records as a
// resident attribute; also appears inside $I30 directory indexes.
//
// On-disk layout (Linux-NTFS docs):
//   0   u64 parent directory MFT reference (low 48 bits = record number,
//                                          high 16 bits = sequence number)
//   8   FILETIME creationTime
//   16  FILETIME modificationTime
//   24  FILETIME mftChangeTime
//   32  FILETIME accessTime
//   40  u64 allocatedSize
//   48  u64 realSize
//   56  u32 fileAttributes (FILE_ATTRIBUTE_* flags)
//   60  u32 EA / reparse-point union
//   64  u8  fileNameLength (UTF-16 chars, not bytes)
//   65  u8  fileNameNamespace
//   66  ... UTF-16 LE name
//
// FILETIME is a 64-bit count of 100-ns intervals since 1601-01-01 UTC.
public struct FileName: Sendable, Equatable {
    public enum Namespace: UInt8, Sendable, Equatable {
        case posix     = 0   // case-sensitive POSIX
        case win32     = 1   // case-insensitive Win32 (default)
        case dos       = 2   // 8.3 short name
        case win32AndDos = 3 // Win32 and DOS-compatible (treated as both)
    }

    public let parentDirectoryReference: UInt64
    public let parentRecordNumber: UInt64
    public let parentSequenceNumber: UInt16
    public let creationTime: Date?
    public let modificationTime: Date?
    public let mftChangeTime: Date?
    public let accessTime: Date?
    public let allocatedSize: UInt64
    public let realSize: UInt64
    public let fileAttributes: UInt32
    public let namespace: Namespace
    public let name: String

    public static let minimumSize = 66  // header before the name bytes

    public static func parse(_ data: Data) throws -> FileName {
        guard data.count >= minimumSize else {
            throw NTFSError.corruptOnDisk(
                description: "$FILE_NAME attribute too short: \(data.count) < \(minimumSize)"
            )
        }

        let parentRef = try data.readU64LE(at: 0)
        let recordNumber = parentRef & 0x0000_FFFF_FFFF_FFFF
        let sequenceNumber = UInt16(truncatingIfNeeded: (parentRef >> 48) & 0xFFFF)

        let nameLengthChars = try data.readU8(at: 64)
        let namespaceByte = try data.readU8(at: 65)
        let namespace = Namespace(rawValue: namespaceByte) ?? .posix

        let nameBytes = Int(nameLengthChars) * 2
        guard 66 + nameBytes <= data.count else {
            throw NTFSError.corruptOnDisk(
                description: "$FILE_NAME name length \(nameLengthChars) chars (\(nameBytes) bytes) exceeds attribute size \(data.count)"
            )
        }
        let nameSlice = data[(data.startIndex + 66)..<(data.startIndex + 66 + nameBytes)]
        guard let name = decodeUTF16LE(nameSlice) else {
            throw NTFSError.corruptOnDisk(description: "$FILE_NAME name decode failed")
        }

        return FileName(
            parentDirectoryReference: parentRef,
            parentRecordNumber: recordNumber,
            parentSequenceNumber: sequenceNumber,
            creationTime:     filetime(try data.readU64LE(at: 8)),
            modificationTime: filetime(try data.readU64LE(at: 16)),
            mftChangeTime:    filetime(try data.readU64LE(at: 24)),
            accessTime:       filetime(try data.readU64LE(at: 32)),
            allocatedSize:    try data.readU64LE(at: 40),
            realSize:         try data.readU64LE(at: 48),
            fileAttributes:   try data.readU32LE(at: 56),
            namespace:        namespace,
            name:             name
        )
    }

    /// Convert a Windows FILETIME (100-ns intervals since 1601-01-01 UTC) to a Date.
    /// Returns nil for the sentinel zero value.
    private static func filetime(_ raw: UInt64) -> Date? {
        if raw == 0 { return nil }
        // Seconds between 1601-01-01 and Unix epoch (1970-01-01)
        let secondsBetweenEpochs: TimeInterval = 11_644_473_600
        let seconds = TimeInterval(raw) / 10_000_000 - secondsBetweenEpochs
        return Date(timeIntervalSince1970: seconds)
    }

    private static func decodeUTF16LE<S: Sequence>(_ bytes: S) -> String? where S.Element == UInt8 {
        var codeUnits: [UInt16] = []
        var i = 0
        var pair: UInt8 = 0
        for byte in bytes {
            if i % 2 == 0 {
                pair = byte
            } else {
                codeUnits.append(UInt16(pair) | (UInt16(byte) << 8))
            }
            i += 1
        }
        var decoder = UTF16()
        var iterator = codeUnits.makeIterator()
        var scalars: [Unicode.Scalar] = []
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let s): scalars.append(s)
            case .emptyInput: return String(String.UnicodeScalarView(scalars))
            case .error: return nil
            }
        }
    }
}
