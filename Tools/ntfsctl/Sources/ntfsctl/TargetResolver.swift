import ArgumentParser
import Foundation
import NTFSCore

/// Shared "resolve a CLI argument to an MFT record number" helper. Used by
/// every subcommand that accepts a target file/directory.
///
/// **The CLI contract (as of v0.2.0):** bare arguments are ALWAYS treated as
/// paths under the volume root. To target by MFT record number, pass
/// `--recnum`. This prevents the silent ambiguity where a file literally
/// named "38" was indistinguishable from MFT record 38 — a one-typo
/// data-loss class on `rm` / `mv`.
///
/// Earlier versions (≤ v0.1) auto-parsed numeric strings as recnums. That
/// behavior is now an opt-in flag.
enum TargetResolver {

    /// Resolve `arg` to a recnum, treating it as a path by default. If
    /// `recnumFlag` is true, `arg` must parse as UInt64 — otherwise raise a
    /// ValidationError so the user can fix the command line.
    ///
    /// Throws a ValidationError with an actionable hint if either:
    ///  - recnumFlag=true but `arg` isn't a valid UInt64
    ///  - recnumFlag=false and the path doesn't resolve in the volume
    static func resolve(
        _ arg: String,
        recnumFlag: Bool,
        volume: NTFSCore.Volume
    ) async throws -> UInt64 {
        if recnumFlag {
            guard let n = UInt64(arg) else {
                throw ValidationError("--recnum requires an integer, got: \(arg)")
            }
            return n
        }
        guard let resolved = try await volume.resolvePath(arg) else {
            throw ValidationError("path not found in volume: \(arg) (hint: run `ntfsctl list <device>` to see the root; pass --recnum to target by MFT record number)")
        }
        return resolved
    }
}
