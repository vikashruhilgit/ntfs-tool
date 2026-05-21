import XCTest
import NTFSCore
@testable import ntfsctl

/// End-to-end test of `cp -r -T` (merge-into-existing) through the REAL CLI
/// code path. This actually parses + runs `Cp` against a writable copy of the
/// `small.img` fixture and asserts the on-disk result — nothing is mocked.
///
/// Scenario: an existing volume directory `/gallery/Android` already holds an
/// `existing.txt`. A host source `src/Android/{new.txt,existing.txt}` is copied
/// with `-r -T`, which must MERGE source's contents into the existing dir:
///   - `src/Android` lands AS `/gallery/Android` (not `/gallery/src/Android`,
///     not `/gallery/Android/Android`).
///   - `new.txt` is created.
///   - `existing.txt` is REPLACED under the default conflict policy.
/// A second method covers the `-n` (skip) policy on the same merge path.
final class CpMergeIntegrationTests: XCTestCase {

    // MARK: - Fixture plumbing (reimplemented locally; can't import test helper)

    /// Path to the committed read-only `small.img` fixture. The repo root is 4
    /// directories up from this file
    /// (Tools/ntfsctl/Tests/ntfsctlTests/ThisFile.swift), then
    /// Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img.
    private func fixturePath(_ file: String = #filePath) -> String {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // ntfsctlTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ntfsctl
            .deletingLastPathComponent()  // Tools
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img")
            .path
    }

    /// Copy the read-only fixture into a writable tmp file and register
    /// teardown to delete it. Skips the test if the fixture is missing.
    private func mutableFixtureCopy() throws -> String {
        let source = fixturePath()
        guard FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("fixture missing at \(source); run scripts/make_test_images.sh")
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsctl-merge-\(UUID().uuidString)-small.img")
        try FileManager.default.copyItem(atPath: source, toPath: copy.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy.path
    }

    /// Build a host source tree under a fresh tmp dir, with teardown.
    /// Returns the path to `<tmp>/src`. `existingContents` controls what the
    /// merge will collide with on `existing.txt`.
    private func makeHostSourceTree(existingContents: String) throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ntfsctl-src-\(UUID().uuidString)")
        let androidDir = root.appendingPathComponent("src/Android")
        try fm.createDirectory(at: androidDir, withIntermediateDirectories: true)
        try Data("NEW".utf8).write(to: androidDir.appendingPathComponent("new.txt"))
        try Data(existingContents.utf8).write(to: androidDir.appendingPathComponent("existing.txt"))
        try Data("TOP".utf8).write(to: root.appendingPathComponent("src/top.txt"))
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root.appendingPathComponent("src").path
    }

    // MARK: - Volume seeding / readback helpers

    private func childRecnum(_ volume: Volume, parent: UInt64, name: String) async throws -> UInt64? {
        let entries = try await volume.enumerate(directory: parent)
        let needle = name.lowercased()
        return entries.first {
            $0.fileName.namespace != .dos && $0.name.lowercased() == needle
        }?.recordNumber
    }

    /// Seed `/gallery/Android/existing.txt` (bytes = `existingContents`) on a
    /// freshly-opened volume, wrapped in a write session like Cp does.
    /// Opens its own device and lets it deinit before returning so the CLI run
    /// can re-open the image cleanly.
    private func seedExistingTree(imagePath: String, existingContents: String) async throws {
        // lockExclusive:false: the actor-held FileHandle's deinit (which
        // releases the flock) isn't deterministic, so taking the exclusive
        // lock here would race the CLI's own exclusive open in Cp.run().
        // Seeding a private tmp image needs no concurrency guard.
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let volume = try await Volume(device: device)
        try await volume.beginWriteSession()
        // gallery/ under root (recnum 5). Root is LARGE_INDEX in the fixture;
        // createFile descends $INDEX_ALLOCATION and inserts correctly.
        let galleryRN: UInt64
        if let existing = try await childRecnum(volume, parent: 5, name: "gallery") {
            galleryRN = existing
        } else {
            galleryRN = try await volume.createFile(named: "gallery", inDirectory: 5, isDirectory: true)
        }
        let androidRN: UInt64
        if let existing = try await childRecnum(volume, parent: galleryRN, name: "Android") {
            androidRN = existing
        } else {
            androidRN = try await volume.createFile(named: "Android", inDirectory: galleryRN, isDirectory: true)
        }
        // existing.txt (replace any prior copy so re-seeding for the skip test
        // gives a clean "OLD").
        if let prior = try await childRecnum(volume, parent: androidRN, name: "existing.txt") {
            try await volume.deleteFile(at: prior)
        }
        let fileRN = try await volume.createFile(named: "existing.txt", inDirectory: androidRN, isDirectory: false)
        try await volume.write(at: fileRN, offset: 0, bytes: Data(existingContents.utf8))
        try await volume.endWriteSession()
    }

    /// Read the full bytes of a file at `path` on the image as a String.
    private func readFileString(imagePath: String, path: String) async throws -> String? {
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let volume = try await Volume(device: device)
        guard let rn = try await volume.resolvePath(path) else { return nil }
        var out = Data()
        var offset: UInt64 = 0
        let chunk = 1 << 16
        while true {
            let slice = try await volume.readFileSlice(at: rn, offset: offset, length: chunk)
            if slice.isEmpty { break }
            out.append(slice)
            offset += UInt64(slice.count)
            if slice.count < chunk { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Names of child entries under a directory path (DOS-namespace filtered).
    private func childNames(imagePath: String, dirPath: String) async throws -> [String] {
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let volume = try await Volume(device: device)
        guard let rn = try await volume.resolvePath(dirPath) else { return [] }
        let entries = try await volume.enumerate(directory: rn)
        return entries.filter { $0.fileName.namespace != .dos }.map { $0.name }
    }

    // MARK: - Tests

    /// Default conflict policy = REPLACE. Merge `src/Android` into the existing
    /// `/gallery/Android`: new.txt created, existing.txt replaced FRESH, and
    /// exactly ONE Android entry under /gallery (no nesting/dup).
    func testMergeReplacesExistingAndAddsNew() async throws {
        let imagePath = try mutableFixtureCopy()
        try await seedExistingTree(imagePath: imagePath, existingContents: "OLD")
        let hostSrc = try makeHostSourceTree(existingContents: "FRESH")

        // REAL command path: parse + run the host→volume merge.
        let cmd = try Cp.parse([hostSrc, imagePath, "/gallery", "-r", "-T", "--no-free-check"])
        try await cmd.run()

        // /gallery/Android exists (merged into the existing dir).
        let galleryNames = try await childNames(imagePath: imagePath, dirPath: "/gallery")
        XCTAssertEqual(
            galleryNames.filter { $0.lowercased() == "android" }.count, 1,
            "expected exactly ONE 'Android' under /gallery (no nesting/duplication); got \(galleryNames)"
        )
        XCTAssertFalse(galleryNames.contains("src"),
                       "merge must NOT create /gallery/src; got \(galleryNames)")

        // No /gallery/Android/Android (would indicate double-nesting).
        let androidNames = try await childNames(imagePath: imagePath, dirPath: "/gallery/Android")
        XCTAssertFalse(androidNames.contains(where: { $0.lowercased() == "android" }),
                       "merge must NOT nest Android under Android; got \(androidNames)")

        // new.txt created with "NEW".
        let newBytes = try await readFileString(imagePath: imagePath, path: "/gallery/Android/new.txt")
        XCTAssertEqual(newBytes, "NEW", "new.txt should be created with its host bytes")

        // existing.txt REPLACED → "FRESH" (default policy = replace).
        let existingBytes = try await readFileString(imagePath: imagePath, path: "/gallery/Android/existing.txt")
        XCTAssertEqual(existingBytes, "FRESH", "default conflict policy must REPLACE existing.txt")
    }

    /// Skip policy (`-n`): re-seed existing.txt="OLD", merge with `-r -T -n`.
    /// existing.txt must stay "OLD" (skipped) while new.txt is still created.
    func testMergeWithNoClobberSkipsExistingButAddsNew() async throws {
        let imagePath = try mutableFixtureCopy()
        try await seedExistingTree(imagePath: imagePath, existingContents: "OLD")
        let hostSrc = try makeHostSourceTree(existingContents: "FRESH")

        let cmd = try Cp.parse([hostSrc, imagePath, "/gallery", "-r", "-T", "-n", "--no-free-check"])
        try await cmd.run()

        // existing.txt left untouched.
        let existingBytes = try await readFileString(imagePath: imagePath, path: "/gallery/Android/existing.txt")
        XCTAssertEqual(existingBytes, "OLD", "--no-clobber must SKIP existing.txt, leaving it 'OLD'")

        // new.txt still created.
        let newBytes = try await readFileString(imagePath: imagePath, path: "/gallery/Android/new.txt")
        XCTAssertEqual(newBytes, "NEW", "--no-clobber must still create new files")

        // Still exactly one Android, no src/ leakage.
        let galleryNames = try await childNames(imagePath: imagePath, dirPath: "/gallery")
        XCTAssertEqual(galleryNames.filter { $0.lowercased() == "android" }.count, 1)
        XCTAssertFalse(galleryNames.contains("src"))
    }
}
