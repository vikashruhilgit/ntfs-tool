import FSKit
import Foundation
import NTFSCore
import os.log

// FSUnaryFileSystem adapter for NTFSCore. One container per probed resource;
// the volume backing it is created lazily on loadResource. v1 surface:
// probe + load + unload — recognize NTFS by boot-sector signature, hand the
// system a thin NTFSVolume backed by an NTFSCore.Volume.
@available(macOS 15.4, *)
final class NTFSUnaryFS: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {

    private let log = Logger(subsystem: "com.ntfs-tool.fskit", category: "NTFSUnaryFS")

    /// Probe a resource and decide whether we recognize it as NTFS.
    /// FSKit hands us an `FSResource`; we read its first 512 bytes via
    /// the FSBlockDeviceResource read API and run them through
    /// `BootSector.parse`.
    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping @Sendable (FSProbeResult?, Error?) -> Void
    ) {
        Task {
            do {
                guard let block = resource as? FSBlockDeviceResource else {
                    log.error("probeResource: resource is not an FSBlockDeviceResource")
                    reply(FSProbeResult.notRecognized, nil)
                    return
                }

                let bytes = try await readBootSector(from: block)
                let boot = try BootSector.parse(bytes)

                // mkntfs writes "NTFSCORETEST" for our test fixture; real Windows
                // volumes get whatever the user named it. FSKit lets us return a
                // volume name from the probe — we don't have $VOLUME_NAME parsing
                // yet (Block C didn't surface it), so we report the OEM ID
                // trimmed of trailing spaces as a placeholder. Block F can
                // surface the real $VOLUME_NAME attribute later.
                let oem = boot.oemID.trimmingCharacters(in: .whitespaces)
                let name = oem.isEmpty ? "NTFS" : oem
                let containerID = FSContainerIdentifier(uuid: UUID())
                log.info("probeResource: recognized NTFS volume '\(oem, privacy: .public)'")
                reply(FSProbeResult.recognized(name: name, containerID: containerID), nil)
            } catch let error as NTFSError {
                log.info("probeResource: not NTFS (\(String(describing: error), privacy: .public))")
                reply(FSProbeResult.notRecognized, nil)
            } catch {
                log.error("probeResource: unexpected error: \(error.localizedDescription, privacy: .public)")
                reply(nil, error)
            }
        }
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable (FSVolume?, Error?) -> Void
    ) {
        Task {
            do {
                guard let block = resource as? FSBlockDeviceResource else {
                    throw NTFSError.ioFailure(description: "loadResource: not an FSBlockDeviceResource")
                }
                let device = FSKitBlockDevice(block: block)
                let coreVolume = try await NTFSCore.Volume(device: device)
                let volumeName = FSFileName(string: coreVolume.boot.oemID.trimmingCharacters(in: .whitespaces))
                let volume = NTFSVolume(coreVolume: coreVolume, volumeName: volumeName, isReadOnly: true)
                log.info("loadResource: NTFS volume loaded read-only")
                reply(volume, nil)
            } catch {
                log.error("loadResource: \(error.localizedDescription, privacy: .public)")
                reply(nil, error)
            }
        }
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable (Error?) -> Void
    ) {
        log.info("unloadResource: NTFS volume released")
        reply(nil)
    }

    // MARK: - Helpers

    /// Read the boot sector (first 512 bytes) from an FSBlockDeviceResource.
    /// FSBlockDeviceResource exposes synchronous + async pread variants.
    private func readBootSector(from block: FSBlockDeviceResource) async throws -> Data {
        let length = BootSector.onDiskSize
        return try await withCheckedThrowingContinuation { continuation in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 8)
            block.read(into: buffer, startingAt: 0, length: length) { actuallyRead, error in
                defer { buffer.deallocate() }
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard actuallyRead == length else {
                    continuation.resume(throwing: NTFSError.shortRead(expected: length, got: actuallyRead))
                    return
                }
                let data = Data(bytes: buffer.baseAddress!, count: length)
                continuation.resume(returning: data)
            }
        }
    }
}
