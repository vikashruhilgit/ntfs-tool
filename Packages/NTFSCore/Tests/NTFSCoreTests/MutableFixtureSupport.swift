import Foundation
import XCTest

/// Mutable-fixture helper for write-side tests. Copies the read-only
/// `small.img` into a tmp file for each test, returns the writable path,
/// and registers a teardown that deletes the copy. Tests can mutate the
/// copy freely without polluting the committed fixture.
///
/// Used by BitmapAllocatorTests and (Phase 5c+) by file-create tests.
enum MutableFixture {

    /// Copy the read-only `name` fixture into a tmp file. Returns the tmp
    /// path. Caller must register cleanup via `XCTestCase.addTeardownBlock`.
    static func copy(_ name: String, from sourceFile: String = #filePath) throws -> String {
        let here = URL(fileURLWithPath: sourceFile)
        let source = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)

        let tmpDir = FileManager.default.temporaryDirectory
        let copy = tmpDir.appendingPathComponent("ntfscore-test-\(UUID().uuidString)-\(name)")

        // Copy file into tmp. Source must exist or test should XCTSkip first.
        try FileManager.default.copyItem(at: source, to: copy)

        // Ensure copy is writable (FileManager preserves permissions; the
        // committed fixture is 644 which is fine, but be explicit).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: copy.path
        )

        return copy.path
    }

    /// Convenience: copy + auto-cleanup wrapper for a single test method.
    /// Usage:
    ///     let path = try MutableFixture.scopedCopy("small.img", testCase: self)
    static func scopedCopy(
        _ name: String,
        testCase: XCTestCase,
        from sourceFile: String = #filePath
    ) throws -> String {
        let path = try copy(name, from: sourceFile)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
        }
        return path
    }
}
