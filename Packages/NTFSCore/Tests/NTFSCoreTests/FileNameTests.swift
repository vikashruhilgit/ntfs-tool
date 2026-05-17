import XCTest
@testable import NTFSCore

final class FileNameTests: XCTestCase {

    /// Build a synthetic 66 + N-byte $FILE_NAME body with the supplied
    /// fields. Lets tests exercise FileName.parse without depending on
    /// the live fixture or on attribute iteration.
    private static func makeFileNameBody(
        parentReference: UInt64 = (1 << 48) | 5,   // sequence=1, recordNumber=5
        creationFileTime: UInt64 = 0,
        modificationFileTime: UInt64 = 0,
        mftChangeFileTime: UInt64 = 0,
        accessFileTime: UInt64 = 0,
        allocatedSize: UInt64 = 0,
        realSize: UInt64 = 0,
        fileAttributes: UInt32 = 0,
        namespaceByte: UInt8 = 1,                  // Win32
        name: String = "test.txt"
    ) -> Data {
        let nameUTF16 = Array(name.utf16)
        var data = Data(count: 66 + nameUTF16.count * 2)

        func writeU64(at o: Int, _ v: UInt64) {
            for i in 0..<8 { data[o + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        func writeU32(at o: Int, _ v: UInt32) {
            for i in 0..<4 { data[o + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }

        writeU64(at: 0,  parentReference)
        writeU64(at: 8,  creationFileTime)
        writeU64(at: 16, modificationFileTime)
        writeU64(at: 24, mftChangeFileTime)
        writeU64(at: 32, accessFileTime)
        writeU64(at: 40, allocatedSize)
        writeU64(at: 48, realSize)
        writeU32(at: 56, fileAttributes)
        writeU32(at: 60, 0)                       // EA/reparse union
        data[64] = UInt8(nameUTF16.count)
        data[65] = namespaceByte

        for (i, codeUnit) in nameUTF16.enumerated() {
            data[66 + 2 * i]     = UInt8(codeUnit & 0xFF)
            data[66 + 2 * i + 1] = UInt8((codeUnit >> 8) & 0xFF)
        }
        return data
    }

    func testHappyPathParse() throws {
        // FILETIME for 2026-01-01 00:00:00 UTC (sanity-check the epoch math).
        // (2026-01-01 - 1601-01-01) seconds × 10_000_000 = 13_410_576_000_000_000
        // 13_410_576_000 seconds * 10_000_000 = 134_105_760_000_000_000
        let jan2026: UInt64 = 134_105_760_000_000_000
        let body = Self.makeFileNameBody(
            parentReference: (UInt64(3) << 48) | UInt64(7),  // sequence=3, recordNumber=7
            creationFileTime: jan2026,
            modificationFileTime: jan2026,
            mftChangeFileTime: jan2026,
            accessFileTime: jan2026,
            allocatedSize: 4096,
            realSize: 2560,
            fileAttributes: 0x20,                            // ARCHIVE
            namespaceByte: 1,                                // Win32
            name: "Hello.txt"
        )
        let fn = try FileName.parse(body)

        XCTAssertEqual(fn.parentRecordNumber, 7)
        XCTAssertEqual(fn.parentSequenceNumber, 3)
        XCTAssertEqual(fn.allocatedSize, 4096)
        XCTAssertEqual(fn.realSize, 2560)
        XCTAssertEqual(fn.fileAttributes, 0x20)
        XCTAssertEqual(fn.namespace, .win32)
        XCTAssertEqual(fn.name, "Hello.txt")
        XCTAssertNotNil(fn.creationTime)
    }

    func testFILETIMEZeroIsNil() throws {
        let body = Self.makeFileNameBody(
            creationFileTime: 0,
            modificationFileTime: 0,
            mftChangeFileTime: 0,
            accessFileTime: 0
        )
        let fn = try FileName.parse(body)
        XCTAssertNil(fn.creationTime,     "FILETIME 0 → nil sentinel")
        XCTAssertNil(fn.modificationTime, "FILETIME 0 → nil sentinel")
        XCTAssertNil(fn.mftChangeTime,    "FILETIME 0 → nil sentinel")
        XCTAssertNil(fn.accessTime,       "FILETIME 0 → nil sentinel")
    }

    func testNamespacePOSIX() throws {
        let body = Self.makeFileNameBody(namespaceByte: 0)
        XCTAssertEqual(try FileName.parse(body).namespace, .posix)
    }

    func testNamespaceWin32() throws {
        let body = Self.makeFileNameBody(namespaceByte: 1)
        XCTAssertEqual(try FileName.parse(body).namespace, .win32)
    }

    func testNamespaceDOS() throws {
        let body = Self.makeFileNameBody(namespaceByte: 2, name: "HELLO~1.TXT")
        let fn = try FileName.parse(body)
        XCTAssertEqual(fn.namespace, .dos)
        XCTAssertEqual(fn.name, "HELLO~1.TXT")
    }

    func testNamespaceWin32AndDos() throws {
        let body = Self.makeFileNameBody(namespaceByte: 3)
        XCTAssertEqual(try FileName.parse(body).namespace, .win32AndDos)
    }

    func testUnknownNamespaceFallsBackToPOSIX() throws {
        // Bytes outside [0, 3] are reserved; FileName.parse maps them to .posix
        // rather than throwing. Document the behavior so consumers know what
        // to expect on a forward-compat NTFS variant.
        let body = Self.makeFileNameBody(namespaceByte: 99)
        XCTAssertEqual(try FileName.parse(body).namespace, .posix)
    }

    func testOversizedNameLengthRejected() throws {
        // Hand-build a body that claims nameLengthChars = 100 (200 bytes)
        // but only contains 66 + 8 bytes total.
        var data = Self.makeFileNameBody(name: "ab")  // 4 name bytes
        data[64] = 100                                 // lie about name length
        XCTAssertThrowsError(try FileName.parse(data)) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }

    func testTooShortBodyRejected() throws {
        // Body smaller than the 66-byte header is invalid.
        let short = Data(repeating: 0, count: 40)
        XCTAssertThrowsError(try FileName.parse(short)) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }

    func testParentReferenceSplit() throws {
        // 64-bit packed reference splits into low 48 bits = recordNumber,
        // high 16 bits = sequenceNumber. Verify both halves.
        let packed: UInt64 = (UInt64(0xABCD) << 48) | UInt64(0x123456789ABC)
        let body = Self.makeFileNameBody(parentReference: packed)
        let fn = try FileName.parse(body)
        XCTAssertEqual(fn.parentRecordNumber, 0x123456789ABC)
        XCTAssertEqual(fn.parentSequenceNumber, 0xABCD)
        XCTAssertEqual(fn.parentDirectoryReference, packed)
    }

    func testNameUTF16Decode() throws {
        // Verify a non-ASCII name (with a non-BMP character) round-trips
        // correctly through the UTF-16 decoder.
        let body = Self.makeFileNameBody(name: "résumé.txt")
        XCTAssertEqual(try FileName.parse(body).name, "résumé.txt")
    }
}
