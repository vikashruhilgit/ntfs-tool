import ArgumentParser
import Foundation
import NTFSCore

/// Resolve the "where do I start walking" argument shared by `tree` and
/// `find`. Both need the same two things: the directory's MFT record number
/// AND its volume-absolute path, so emitted paths stay absolute even when the
/// walk root was given as a record number.
///
/// Target syntax matches `list` (the read-side convention): a bare integer is
/// an MFT record number, anything else is a path under the volume root. These
/// are read-only commands, so the numeric ambiguity `--recnum` exists to
/// prevent on the write side carries no data-loss risk here.
enum WalkTarget {

    struct Resolved {
        let recordNumber: UInt64
        /// Volume-absolute path, e.g. `/` or `/gallery/Android`.
        let path: String
    }

    static func resolve(_ target: String, volume: NTFSCore.Volume) async throws -> Resolved {
        if let recordNumber = UInt64(target) {
            // Record-number form: reconstruct the path from the parent chain
            // so output paths are still absolute. Fall back to a synthetic
            // label if the chain is broken (orphan / unreachable directory).
            let path = try await volume.absolutePath(of: recordNumber)
            return Resolved(recordNumber: recordNumber, path: path ?? "/<recnum \(recordNumber)>")
        }
        guard let recordNumber = try await volume.resolvePath(target) else {
            throw ValidationError("path not found in volume: \(target) (hint: run `ntfsctl list <device>` to see the root)")
        }
        let trimmed = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Resolved(recordNumber: recordNumber, path: trimmed.isEmpty ? "/" : "/" + trimmed)
    }
}
