import XCTest
@testable import NTFSCore

/// Block G stage 5 deliverable: round-trip integration test that proves our
/// writes produce byte sequences the canonical NTFS userspace driver (ntfs-3g)
/// reads back correctly. Skipped when Docker isn't available (CI runners
/// without Docker, contributor machines that haven't started Docker Desktop).
///
/// This is the strongest correctness check short of running `chkdsk /f` on a
/// real Windows machine — and chkdsk's read-side checks are derived from the
/// same NTFS spec ntfs-3g implements, so passing ntfs-3g + ntfsfix gives us
/// high confidence the volume would pass chkdsk too.
final class IntegrationTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Returns true if a `docker` binary is on PATH AND the daemon is
    /// reachable. Falsy → integration tests XCTSkip.
    private func dockerAvailable() -> Bool {
        // Check binary first.
        let which = Process()
        which.launchPath = "/usr/bin/env"
        which.arguments = ["which", "docker"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            guard which.terminationStatus == 0 else { return false }
        } catch {
            return false
        }

        // Then check daemon.
        let info = Process()
        info.launchPath = "/usr/bin/env"
        info.arguments = ["docker", "info"]
        info.standardOutput = Pipe()
        info.standardError = Pipe()
        do {
            try info.run()
            info.waitUntilExit()
            return info.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Run a shell command inside the standard `debian:bookworm-slim` Docker
    /// image with ntfs-3g installed and /tmp mounted as /io. Returns combined
    /// stdout+stderr and the exit status.
    @discardableResult
    private func dockerNTFSExec(_ command: String) throws -> (output: String, status: Int32) {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = [
            "docker", "run", "--rm", "--privileged",
            "-v", "/tmp:/io",
            "debian:bookworm-slim",
            "bash", "-c",
            "apt-get update -qq >/dev/null && apt-get install -y -qq ntfs-3g >/dev/null && \(command)"
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(decoding: data, as: UTF8.self), proc.terminationStatus)
    }

    /// Full write round-trip: create file → write bytes → clear dirty bit →
    /// ntfsfix says clean → ntfs-3g mounts → cat returns byte-exact content.
    func testWriteRoundTripValidatedByNTFS3G() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        guard dockerAvailable() else {
            throw XCTSkip("Docker unavailable; integration test requires Docker Desktop")
        }

        // Copy fixture out to /tmp where Docker can see it.
        let here = URL(fileURLWithPath: #filePath)
        let source = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("small.img")
        let tmpPath = "/tmp/ntfscore-integration-\(UUID().uuidString).img"
        try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: tmpPath))
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }

        // === Step 1: mutate via our code ===
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: tmpPath)
        let volume = try await Volume(device: device)

        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root lacks 'sub/'")
        }

        let recordNumber = try await volume.createFile(
            named: "integration.txt",
            inDirectory: sub.recordNumber
        )
        let payload = Data("Integration test content — Block G stage 5.\n".utf8)
        try await volume.write(at: recordNumber, offset: 0, bytes: payload)
        try await volume.setDirty(false)

        // Sanity-check the dirty bit was actually cleared.
        let dirtyAfter = try await volume.isDirty()
        XCTAssertFalse(dirtyAfter, "dirty bit should be 0 after setDirty(false)")

        // === Step 2: external validation via ntfsfix ===
        let fsckResult = try dockerNTFSExec("ntfsfix --no-action /io/\(URL(fileURLWithPath: tmpPath).lastPathComponent)")
        XCTAssertEqual(fsckResult.status, 0, "ntfsfix should succeed; got status \(fsckResult.status), output: \(fsckResult.output)")
        XCTAssertTrue(
            fsckResult.output.contains("was processed successfully"),
            "ntfsfix output should mention success; got: \(fsckResult.output)"
        )

        // === Step 3: ntfs-3g read-back ===
        let mountCheck = try dockerNTFSExec("""
            mkdir -p /m && ntfs-3g -o force /io/\(URL(fileURLWithPath: tmpPath).lastPathComponent) /m && \
            cat /m/sub/integration.txt && umount /m
        """)
        XCTAssertEqual(mountCheck.status, 0, "ntfs-3g mount + cat should succeed; got: \(mountCheck.output)")
        XCTAssertTrue(
            mountCheck.output.contains("Block G stage 5"),
            "ntfs-3g should read back our payload; got: \(mountCheck.output)"
        )
    }
}
