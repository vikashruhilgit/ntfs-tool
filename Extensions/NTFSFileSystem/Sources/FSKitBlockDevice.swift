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
}
