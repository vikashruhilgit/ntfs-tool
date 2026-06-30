import FSKit
import Foundation
import NTFSCore

// BlockDevice adapter that drives an FSBlockDeviceResource. FSKit hands us
// the resource on loadResource; we never close it manually — FSKit owns its
// lifecycle.
@available(macOS 15.4, *)
final class FSKitBlockDevice: BlockDevice, @unchecked Sendable {
    private let block: FSBlockDeviceResource

    init(block: FSBlockDeviceResource) {
        self.block = block
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        guard length >= 0 else {
            throw NTFSError.ioFailure(description: "negative read length \(length)")
        }
        if length == 0 { return Data() }

        return try await withCheckedThrowingContinuation { continuation in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 8)
            block.read(into: buffer, startingAt: off_t(offset), length: length) { actuallyRead, error in
                defer { buffer.deallocate() }
                if let error = error {
                    continuation.resume(throwing: NTFSError.ioFailure(description: error.localizedDescription))
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

    func write(offset: UInt64, bytes: Data) async throws {
        let length = bytes.count
        if length == 0 { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Copy `bytes` into a stable, contiguous buffer the completion
            // handler keeps alive until FSKit finishes the write. We can't
            // pass Data's storage directly because FSBlockDeviceResource.write
            // wants a mutable raw pointer that outlives this scope.
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 8)
            bytes.copyBytes(to: buffer.bindMemory(to: UInt8.self))
            block.write(from: UnsafeRawBufferPointer(buffer), startingAt: off_t(offset), length: length) { actuallyWritten, error in
                defer { buffer.deallocate() }
                if let error = error {
                    continuation.resume(throwing: NTFSError.ioFailure(description: error.localizedDescription))
                    return
                }
                guard actuallyWritten == length else {
                    continuation.resume(
                        throwing: NTFSError.ioFailure(
                            description: "short write: wrote \(actuallyWritten) of \(length) bytes at offset \(offset)"
                        )
                    )
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    func synchronize() async throws {
        // FSBlockDeviceResource buffers metadata in the kernel buffer cache.
        // Flush it to physical media. `metadataFlush()` is the Swift-refined
        // form of `-metadataFlushWithError:`; it throws on EIO. This is the
        // closest FSBlockDeviceResource analog to F_FULLFSYNC and is the
        // load-bearing durability step before the dirty bit is cleared.
        do {
            try block.metadataFlush()
        } catch {
            throw NTFSError.ioFailure(description: "metadataFlush failed: \(error.localizedDescription)")
        }
    }
}
