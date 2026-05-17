import XCTest
import CryptoKit
@testable import NTFSCore

final class DirectoryTests: XCTestCase {

    private func fixturePath(_ name: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    /// D3: enumerate(directory: 5) returns the three files we put into the
    /// fixture (hello.txt, medium.txt, sub).
    func testEnumerateRootDirectory() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)

        let entries = try await volume.enumerate(directory: 5)
        let names = Set(entries.map { $0.name })

        // mkntfs may also surface the DOS short-name pair (namespace == .dos)
        // for entries like "medium.txt" / "MEDIUM~1.TXT". Test asserts the
        // Win32 names we wrote are present; doesn't pin the exact entry count.
        XCTAssertTrue(names.contains("hello.txt"),  "expected hello.txt in root (got \(names))")
        XCTAssertTrue(names.contains("medium.txt"), "expected medium.txt in root (got \(names))")
        XCTAssertTrue(names.contains("sub"),        "expected sub in root (got \(names))")
    }

    /// D4 + D5: round-trip — find hello.txt in the root index, read its
    /// bytes via $DATA, assert SHA-256 matches the known content.
    func testReadFileRoundTripSHA() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)

        let entries = try await volume.enumerate(directory: 5)

        // Prefer the Win32 namespace entry for hello.txt — DOS-namespace alias
        // (when present) shares a record but the canonical pair is the Win32
        // form. For "hello.txt" there's no 8.3 alias since the name already
        // fits, but the guard is cheap and future-proofs the test.
        guard let helloEntry = entries.first(where: {
            $0.name == "hello.txt" && $0.fileName.namespace != .dos
        }) else {
            return XCTFail("hello.txt not in root directory enumeration (got \(entries.map { $0.name }))")
        }

        let content = try await volume.readFile(at: helloEntry.recordNumber)
        XCTAssertEqual(
            content, Data("Hello, NTFS.\n".utf8),
            "hello.txt content mismatch — got \(content.count) bytes: \(String(decoding: content, as: UTF8.self))"
        )

        // SHA-256 of "Hello, NTFS.\n" (13 bytes) pinned as a hex literal so
        // the test validates against an EXTERNAL oracle rather than just
        // CryptoKit's own output. (A `SHA256(read) == SHA256(literal)` check
        // is mathematically equivalent to the bytes-equality assertion two
        // lines up — both would silently pass if CryptoKit's SHA were broken.)
        // The hex was computed via `printf 'Hello, NTFS.\n' | shasum -a 256`.
        let actualHash = SHA256.hash(data: content).compactMap { String(format: "%02x", $0) }.joined()
        let pinnedHash = "74c1373a760d25dd7168b74976da2ba20e167a119439ece11fbc6d4d5c1e7fbe"
        XCTAssertEqual(actualHash, pinnedHash, "SHA-256 of hello.txt should match the pinned literal")
    }

    /// medium.txt is 2560 bytes ("abcdefghij" repeated 256 times = 2560 chars).
    /// It is larger than the typical resident-attribute limit (~700 bytes for a
    /// 1024-byte MFT record), so it should be non-resident. This exercises the
    /// nonResident → DataRun → BlockDevice read chain end-to-end.
    func testReadNonResidentFile() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let entries = try await volume.enumerate(directory: 5)

        guard let mediumEntry = entries.first(where: {
            $0.name == "medium.txt" && $0.fileName.namespace != .dos
        }) else {
            return XCTFail("medium.txt not in root enumeration")
        }

        let content = try await volume.readFile(at: mediumEntry.recordNumber)
        XCTAssertEqual(content.count, 2560, "medium.txt should be 2560 bytes")

        // Spot-check: first 10 bytes are "abcdefghij", last 10 are "abcdefghij".
        XCTAssertEqual(String(decoding: content.prefix(10), as: UTF8.self), "abcdefghij")
        XCTAssertEqual(String(decoding: content.suffix(10), as: UTF8.self), "abcdefghij")
    }

    /// `sub` is a directory; enumerating it should yield `nested.txt`.
    func testEnumerateNestedDirectory() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let rootEntries = try await volume.enumerate(directory: 5)

        guard let subEntry = rootEntries.first(where: {
            $0.name == "sub" && $0.fileName.namespace != .dos
        }) else {
            return XCTFail("'sub' directory not in root enumeration")
        }

        let subContents = try await volume.enumerate(directory: subEntry.recordNumber)
        let names = Set(subContents.map { $0.name })
        XCTAssertTrue(
            names.contains("nested.txt"),
            "expected nested.txt inside sub/ (got \(names))"
        )
    }

    /// readFileSlice on a non-resident file returns only the requested window
    /// without materializing the whole file. medium.txt is 2560 bytes of
    /// "abcdefghij" repeated 256 times.
    func testReadFileSliceWindows() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let entries = try await volume.enumerate(directory: 5)
        guard let medium = entries.first(where: { $0.name == "medium.txt" && $0.fileName.namespace != .dos }) else {
            return XCTFail("medium.txt not in root enumeration")
        }

        // First 10 bytes — should be "abcdefghij".
        let head = try await volume.readFileSlice(at: medium.recordNumber, offset: 0, length: 10)
        XCTAssertEqual(String(decoding: head, as: UTF8.self), "abcdefghij")

        // Middle slice (offset 100, length 20).
        let middle = try await volume.readFileSlice(at: medium.recordNumber, offset: 100, length: 20)
        XCTAssertEqual(middle.count, 20)
        XCTAssertEqual(String(decoding: middle, as: UTF8.self), "abcdefghijabcdefghij")

        // Last 10 bytes (offset 2550).
        let tail = try await volume.readFileSlice(at: medium.recordNumber, offset: 2550, length: 10)
        XCTAssertEqual(String(decoding: tail, as: UTF8.self), "abcdefghij")

        // Request past EOF returns empty.
        let past = try await volume.readFileSlice(at: medium.recordNumber, offset: 5000, length: 10)
        XCTAssertEqual(past.count, 0)

        // Request straddling EOF gets truncated to realSize - offset.
        let straddle = try await volume.readFileSlice(at: medium.recordNumber, offset: 2555, length: 100)
        XCTAssertEqual(straddle.count, 5)
    }

    /// Rejects: enumerating an MFT record that isn't a directory should throw.
    func testEnumerateNonDirectoryThrows() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)

        let rootEntries = try await volume.enumerate(directory: 5)
        guard let fileEntry = rootEntries.first(where: { $0.name == "hello.txt" && $0.fileName.namespace != .dos }) else {
            return XCTFail("hello.txt not found")
        }

        do {
            _ = try await volume.enumerate(directory: fileEntry.recordNumber)
            XCTFail("expected enumerate on a file MFT record to throw")
        } catch is NTFSError {
            // expected
        }
    }
}
