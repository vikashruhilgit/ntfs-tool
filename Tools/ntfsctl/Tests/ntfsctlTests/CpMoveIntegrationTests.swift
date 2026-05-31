import XCTest
import NTFSCore
@testable import ntfsctl

/// End-to-end tests for `cp --move` (cross-device cut) through the REAL `Cp`
/// command path. Each test parses + runs `Cp` against a writable copy of the
/// `small.img` fixture and asserts the on-disk state on BOTH ends (host source
/// + NTFS volume) — nothing is mocked.
///
/// The dominant invariant under test (AC-2): a source is deleted ONLY when its
/// copy actually happened. Skips (`-n` collisions, non-regular files) and
/// failures must leave the source intact, and a directory that still holds a
/// not-moved child must NOT be removed.
final class CpMoveIntegrationTests: XCTestCase {

    // MARK: - Fixture plumbing (mirrors CpMergeIntegrationTests)

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

    private func mutableFixtureCopy() throws -> String {
        let source = fixturePath()
        guard FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("fixture missing at \(source); run scripts/make_test_images.sh")
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsctl-move-\(UUID().uuidString)-small.img")
        try FileManager.default.copyItem(atPath: source, toPath: copy.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy.path
    }

    /// A fresh empty host tmp dir (with teardown). Used both as a scratch source
    /// root and as a host destination for the --from-volume pull test.
    private func freshHostDir() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ntfsctl-move-host-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    // MARK: - Volume seeding / readback helpers (mirrors CpMergeIntegrationTests)

    private func childRecnum(_ volume: Volume, parent: UInt64, name: String) async throws -> UInt64? {
        let entries = try await volume.enumerate(directory: parent)
        let needle = name.lowercased()
        return entries.first {
            $0.fileName.namespace != .dos && $0.name.lowercased() == needle
        }?.recordNumber
    }

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

    private func childNames(imagePath: String, dirPath: String) async throws -> [String] {
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let volume = try await Volume(device: device)
        guard let rn = try await volume.resolvePath(dirPath) else { return [] }
        let entries = try await volume.enumerate(directory: rn)
        return entries.filter { $0.fileName.namespace != .dos }.map { $0.name }
    }

    /// Seed `/gallery/srcfile.txt` with bytes on the volume so the --from-volume
    /// move test has a known source to pull + delete.
    private func seedVolumeFile(imagePath: String, dir: String, name: String, contents: String) async throws -> UInt64 {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let volume = try await Volume(device: device)
        try await volume.beginWriteSession()
        let dirRN: UInt64
        if let existing = try await childRecnum(volume, parent: 5, name: dir) {
            dirRN = existing
        } else {
            dirRN = try await volume.createFile(named: dir, inDirectory: 5, isDirectory: true)
        }
        if let prior = try await childRecnum(volume, parent: dirRN, name: name) {
            try await volume.deleteFile(at: prior)
        }
        let fileRN = try await volume.createFile(named: name, inDirectory: dirRN, isDirectory: false)
        try await volume.write(at: fileRN, offset: 0, bytes: Data(contents.utf8))
        try await volume.endWriteSession()
        return fileRN
    }

    /// Seed `/tree/sub/b.txt = "OLD"` (tree already exists from a prior seed).
    /// `lockExclusive: false` so the seed handle doesn't race the CLI's own
    /// exclusive open in `Cp.run()`.
    private func seedTreeSubB(imagePath: String) async throws {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let volume = try await Volume(device: device)
        try await volume.beginWriteSession()
        let treeRN = try await childRecnum(volume, parent: 5, name: "tree")!
        let subRN = try await volume.createFile(named: "sub", inDirectory: treeRN, isDirectory: true)
        let bRN = try await volume.createFile(named: "b.txt", inDirectory: subRN, isDirectory: false)
        try await volume.write(at: bRN, offset: 0, bytes: Data("OLD".utf8))
        try await volume.endWriteSession()
    }

    /// BFS from root (recnum 5). Returns the set of every in-tree record number
    /// reachable through $I30 entries. Used to assert a deleted record is no
    /// longer reachable (orphan / dangling check) after `--move`.
    private func reachableRecnums(imagePath: String) async throws -> Set<UInt64> {
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let volume = try await Volume(device: device)
        var seen: Set<UInt64> = [5]
        var queue: [UInt64] = [5]
        while let dir = queue.first {
            queue.removeFirst()
            let entries = (try? await volume.enumerate(directory: dir)) ?? []
            for e in entries where e.fileName.namespace != .dos {
                if seen.insert(e.recordNumber).inserted, e.isDirectory {
                    queue.append(e.recordNumber)
                }
            }
        }
        return seen
    }

    // MARK: - AC-1 / AC-2: host→volume --move deletes source on success

    func testHostToVolumeMoveDeletesSourceOnSuccess() async throws {
        let imagePath = try mutableFixtureCopy()
        let hostRoot = try freshHostDir()
        let srcFile = hostRoot.appendingPathComponent("moveme.txt")
        try Data("PAYLOAD".utf8).write(to: srcFile)

        let cmd = try Cp.parse([srcFile.path, imagePath, "/", "--move", "--no-free-check"])
        try await cmd.run()

        // Source gone (deleted after a successful copy).
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcFile.path),
                       "--move must delete the host source after a successful copy")
        // Destination has the bytes.
        let dst = try await readFileString(imagePath: imagePath, path: "/moveme.txt")
        XCTAssertEqual(dst, "PAYLOAD", "the volume destination must hold the moved bytes")
    }

    // MARK: - AC-2: --move leaves source on skip (-n collision)

    func testMoveLeavesSourceOnSkip() async throws {
        let imagePath = try mutableFixtureCopy()
        // Seed an existing /clash.txt = "OLD" on the volume.
        _ = try await seedVolumeFile(imagePath: imagePath, dir: "movedir", name: "clash.txt", contents: "OLD")
        let hostRoot = try freshHostDir()
        let srcFile = hostRoot.appendingPathComponent("clash.txt")
        try Data("NEW".utf8).write(to: srcFile)

        // -n --move: destination exists → file is SKIPPED → source preserved.
        let cmd = try Cp.parse([srcFile.path, imagePath, "/movedir/", "-n", "--move", "--no-free-check"])
        try await cmd.run()

        // Destination unchanged (skip).
        let dst = try await readFileString(imagePath: imagePath, path: "/movedir/clash.txt")
        XCTAssertEqual(dst, "OLD", "--no-clobber must SKIP the existing destination")
        // Source preserved (NOT deleted, because the copy never happened).
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path),
                      "a skipped file's source MUST be left intact under --move")
        let stillThere = try Data(contentsOf: srcFile)
        XCTAssertEqual(String(decoding: stillThere, as: UTF8.self), "NEW")
    }

    // MARK: - AC-3: -r --move dir cleanup, skip-aware + clean-run dir removal

    func testRecursiveMoveDirCleanupIsSkipAware() async throws {
        let imagePath = try mutableFixtureCopy()

        // Host source tree: tree/sub/{a.txt, b.txt}
        let hostRoot = try freshHostDir()
        let subDir = hostRoot.appendingPathComponent("tree/sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("AAA".utf8).write(to: subDir.appendingPathComponent("a.txt"))
        try Data("BBB".utf8).write(to: subDir.appendingPathComponent("b.txt"))
        let treeDir = hostRoot.appendingPathComponent("tree")

        // Pre-seed the volume so ONE child (b.txt) collides and is skipped under -n.
        // Destination layout after a nest of "tree" under root: /tree/sub/<files>.
        _ = try await seedVolumeFile(imagePath: imagePath, dir: "tree", name: "_placeholder", contents: "x")
        // Create /tree/sub and /tree/sub/b.txt = "OLD". Scoped in a helper so
        // the seeding device's FileHandle deinits (releasing its flock) before
        // the CLI run opens the image exclusively.
        try await seedTreeSubB(imagePath: imagePath)

        // -r -n --move into root: "tree" nests under root (dest /tree exists →
        // .nest? no — dest exists as dir so planner returns nest under
        // /tree/tree). To force a MERGE into the existing /tree, pass -T.
        let cmd = try Cp.parse([treeDir.path, imagePath, "/tree", "-r", "-T", "-n", "--move", "--no-free-check"])
        try await cmd.run()

        // a.txt was copied (new) → its source is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: subDir.appendingPathComponent("a.txt").path),
                       "non-skipped child's source must be removed under --move")
        // b.txt collided under -n → skipped → its source REMAINS.
        XCTAssertTrue(FileManager.default.fileExists(atPath: subDir.appendingPathComponent("b.txt").path),
                      "skipped child's source MUST be preserved")
        // The source subdir is NOT removed because it still holds the skipped b.txt.
        XCTAssertTrue(FileManager.default.fileExists(atPath: subDir.path),
                      "a source dir holding a skipped child must NOT be removed")
        // And the parent tree dir is likewise preserved (propagation).
        XCTAssertTrue(FileManager.default.fileExists(atPath: treeDir.path),
                      "not-fully-moved status must propagate to ancestor source dirs")
        // Destination b.txt unchanged (still OLD).
        let bDst = try await readFileString(imagePath: imagePath, path: "/tree/sub/b.txt")
        XCTAssertEqual(bDst, "OLD", "skipped child's destination must be unchanged")
    }

    /// Clean run (no collisions): a fully-moved source tree has its emptied
    /// dirs removed depth-first. (Separate test/image so the CLI exclusive open
    /// doesn't race a prior run's not-yet-released flock.)
    func testRecursiveMoveRemovesEmptiedSourceTree() async throws {
        let imagePath = try mutableFixtureCopy()
        let hostRoot = try freshHostDir()
        let subDir = hostRoot.appendingPathComponent("tree2/sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("CCC".utf8).write(to: subDir.appendingPathComponent("c.txt"))
        let treeDir = hostRoot.appendingPathComponent("tree2")

        let cmd = try Cp.parse([treeDir.path, imagePath, "/", "-r", "--move", "--no-free-check"])
        try await cmd.run()

        // The whole emptied source tree is removed depth-first.
        XCTAssertFalse(FileManager.default.fileExists(atPath: subDir.path),
                       "fully-moved source subdir must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: treeDir.path),
                       "fully-moved source root must be removed")
        // Destination has the moved file.
        let cDst = try await readFileString(imagePath: imagePath, path: "/tree2/sub/c.txt")
        XCTAssertEqual(cDst, "CCC")
    }

    // MARK: - AC-4: --dry-run --move is inert

    func testDryRunMoveIsInert() async throws {
        let imagePath = try mutableFixtureCopy()
        let hostRoot = try freshHostDir()
        let srcFile = hostRoot.appendingPathComponent("dry.txt")
        try Data("DRYBYTES".utf8).write(to: srcFile)

        let cmd = try Cp.parse([srcFile.path, imagePath, "/", "--dry-run", "--move", "--no-free-check"])
        try await cmd.run()

        // Source preserved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path),
                      "--dry-run --move must NOT delete the source")
        // Nothing written to the volume.
        let dst = try await readFileString(imagePath: imagePath, path: "/dry.txt")
        XCTAssertNil(dst, "--dry-run must NOT write anything to the volume")
    }

    // MARK: - AC-1/AC-2/AC-3: volume→host --move (--from-volume)

    func testVolumeToHostMoveDeletesVolumeSource() async throws {
        let imagePath = try mutableFixtureCopy()
        let srcRN = try await seedVolumeFile(imagePath: imagePath, dir: "pulldir", name: "pullme.txt", contents: "FROMVOL")
        let hostRoot = try freshHostDir()

        let cmd = try Cp.parse([
            "/pulldir/pullme.txt", imagePath, hostRoot.path + "/",
            "--from-volume", "--move",
        ])
        try await cmd.run()

        // Host destination has the bytes.
        let pulled = hostRoot.appendingPathComponent("pullme.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pulled.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: pulled), as: UTF8.self), "FROMVOL")

        // Volume source gone: resolvePath returns nil.
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let volume = try await Volume(device: device)
        let resolved = try await volume.resolvePath("/pulldir/pullme.txt")
        XCTAssertNil(resolved, "--from-volume --move must delete the volume source")

        // Reachability / orphan check: the deleted record must NOT be reachable
        // from root, confirming the $I30 entry was removed (no dangling link).
        let reachable = try await reachableRecnums(imagePath: imagePath)
        XCTAssertFalse(reachable.contains(srcRN),
                       "deleted volume source must not be reachable from root after --move")
    }

    // MARK: - AC-3: volume→host -r --move removes emptied volume dir (deleteFile path)

    func testVolumeToHostRecursiveMoveRemovesEmptiedDir() async throws {
        let imagePath = try mutableFixtureCopy()
        // Seed /pullroot/inner/leaf.txt on the volume.
        let device0 = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let v0 = try await Volume(device: device0)
        try await v0.beginWriteSession()
        let rootDirRN = try await v0.createFile(named: "pullroot", inDirectory: 5, isDirectory: true)
        let innerRN = try await v0.createFile(named: "inner", inDirectory: rootDirRN, isDirectory: true)
        let leafRN = try await v0.createFile(named: "leaf.txt", inDirectory: innerRN, isDirectory: false)
        try await v0.write(at: leafRN, offset: 0, bytes: Data("LEAF".utf8))
        try await v0.endWriteSession()

        let hostRoot = try freshHostDir()
        let cmd = try Cp.parse([
            "/pullroot", imagePath, hostRoot.path + "/",
            "-r", "--from-volume", "--move",
        ])
        try await cmd.run()

        // Host got the tree.
        let leafHost = hostRoot.appendingPathComponent("pullroot/inner/leaf.txt")
        XCTAssertEqual(String(decoding: try Data(contentsOf: leafHost), as: UTF8.self), "LEAF")

        // Volume source dirs + file all removed (deleteFile on emptied dirs).
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        let volume = try await Volume(device: device)
        let rLeaf = try await volume.resolvePath("/pullroot/inner/leaf.txt")
        let rInner = try await volume.resolvePath("/pullroot/inner")
        let rRoot = try await volume.resolvePath("/pullroot")
        XCTAssertNil(rLeaf)
        XCTAssertNil(rInner)
        XCTAssertNil(rRoot)

        // Verify-equivalent: none of the deleted records remain reachable, and
        // root no longer lists pullroot.
        let reachable = try await reachableRecnums(imagePath: imagePath)
        XCTAssertFalse(reachable.contains(rootDirRN))
        XCTAssertFalse(reachable.contains(innerRN))
        XCTAssertFalse(reachable.contains(leafRN))
        let rootNames = try await childNames(imagePath: imagePath, dirPath: "/")
        XCTAssertFalse(rootNames.contains(where: { $0.lowercased() == "pullroot" }),
                       "volume stays clean: emptied source root removed from / listing")
    }
}
