import XCTest
import NTFSCore
@testable import NTFSUIKit

/// Drives the browser end-to-end against a real NTFS image: open, list,
/// navigate, create, copy in from the host, and delete. This is the test that
/// proves the GUI path actually reaches the volume — the pure-value tests can't.
///
/// Works on a COPY of the shared fixture so the committed image is never
/// mutated. Skips (rather than fails) when the fixture isn't reachable from the
/// NTFSUIKit package, so the suite stays green in checkouts that build the UI
/// package alone.
@MainActor
final class FileBrowserIntegrationTests: XCTestCase {

    private var workingCopy: String?

    override func tearDown() {
        if let workingCopy { try? FileManager.default.removeItem(atPath: workingCopy) }
        workingCopy = nil
        super.tearDown()
    }

    func testOpenListsRootAndReportsWritable() async throws {
        let model = try makeModel()
        await model.open()

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isWritable, "an .img file is user-owned, so the writable open must succeed")
        XCTAssertEqual(model.crumbs.map(\.name), ["/"])
        // The root of any NTFS volume holds the system metafiles; an empty list
        // would mean the enumerate path silently failed.
        XCTAssertFalse(model.entries.isEmpty)
    }

    func testCreateEnterAndDeleteRoundTrip() async throws {
        let model = try makeModel()
        await model.open()
        try XCTSkipUnless(model.isWritable)

        let name = "browser-test-dir"
        model.newFolder(named: name)
        try await settle(model)
        guard let created = model.entries.first(where: { $0.name == name }) else {
            return XCTFail("new folder did not appear in the listing")
        }
        XCTAssertTrue(created.isDirectory)

        // Navigating in must update both the listing and the crumb trail.
        await model.enter(created)
        XCTAssertEqual(model.crumbs.map(\.name), ["/", name])

        await model.goUp()
        XCTAssertEqual(model.crumbs.map(\.name), ["/"])

        // Delete it again and confirm it's gone from the volume, not just the
        // local array — reload() re-reads the directory from disk.
        model.selection = [created.recordNumber]
        model.deleteSelection()
        try await settle(model)
        XCTAssertFalse(model.entries.contains { $0.name == name })
    }

    func testImportFromHostCopiesFileContents() async throws {
        let model = try makeModel()
        await model.open()
        try XCTSkipUnless(model.isWritable)

        // Deliberately larger than the ~700-byte resident threshold. A resident
        // file's `$I30` entry correctly carries realSize 0 — resident data
        // occupies zero clusters, and Windows stamps 0/0 there too, so a
        // non-zero hint on a small file would be the actual defect. Only a
        // NON-resident file's hint is expected to carry the size, and that is
        // the value Windows Explorer displays.
        let payload = Data(repeating: 0xAB, count: 4096)
        let hostFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-import-\(UUID().uuidString).bin")
        try payload.write(to: hostFile)
        defer { try? FileManager.default.removeItem(at: hostFile) }

        model.importFromHost(paths: [hostFile.path])
        try await settle(model)

        let name = hostFile.lastPathComponent
        guard let copied = model.entries.first(where: { $0.name == name }) else {
            return XCTFail("imported file is not in the listing")
        }
        XCTAssertEqual(copied.size, UInt64(payload.count),
                       "a non-resident file's $I30 size hint is what Explorer shows")

        // Read the bytes back through a fresh Volume — proves the content
        // landed, not merely the directory entry.
        let device = try FileHandleBlockDevice(openingFileAt: try imagePath())
        let volume = try await Volume(device: device)
        let readBack = try await volume.readFile(at: copied.recordNumber)
        XCTAssertEqual(readBack, payload)
    }

    func testSelectionIsPrunedWhenEntriesDisappear() async throws {
        let model = try makeModel()
        await model.open()

        // A stale selection must not survive a reload, or a later Delete would
        // act on a record number that has been reused by another file.
        model.selection = [999_999]
        await model.reload()
        XCTAssertTrue(model.selection.isEmpty)
    }

    // MARK: - Fixture plumbing

    /// Copy the shared fixture so mutations never touch the committed image.
    private func imagePath() throws -> String {
        if let existing = workingCopy { return existing }
        let candidates = [
            URL(fileURLWithPath: #filePath)                 // …/Tests/NTFSUIKitTests/<file>
                .deletingLastPathComponent()                // NTFSUIKitTests
                .deletingLastPathComponent()                // Tests
                .deletingLastPathComponent()                // NTFSUIKit
                .deletingLastPathComponent()                // Packages
                .appendingPathComponent("NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img")
        ]
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("small.img fixture not reachable from the NTFSUIKit package")
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-fixture-\(UUID().uuidString).img")
        try FileManager.default.copyItem(at: source, to: copy)
        workingCopy = copy.path
        return copy.path
    }

    private func makeModel() throws -> FileBrowserModel {
        FileBrowserModel(devicePath: try imagePath())
    }

    /// Operations run on a detached task; wait for the model to go idle rather
    /// than sleeping a fixed interval.
    private func settle(_ model: FileBrowserModel, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // Give the task a beat to start, so "no operation yet" isn't mistaken
        // for "already finished".
        try await Task.sleep(nanoseconds: 120_000_000)
        while model.operation != nil {
            if Date() > deadline { return XCTFail("operation did not finish within \(timeout)s") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await model.reload()
    }
}
