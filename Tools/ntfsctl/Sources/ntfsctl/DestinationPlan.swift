import Foundation

/// Pure classification of where a `cp` host→volume destination resolves to,
/// independent of any volume or filesystem I/O. The volume-I/O parts
/// (resolving/creating parent dirs, the actual copy) stay in Cp.swift; this
/// type only decides NEW vs NEST vs MERGE and the per-file conflict policy.
enum DestinationOutcome: Equatable {
    /// Requested dest path does not exist → it will be created.
    case new
    /// Dest dir exists and `-T` was NOT passed → nest under dest/<sourceBasename> (POSIX-standard).
    case nest
    /// Dest dir exists and `-T` was passed (dir source) → merge source's contents into dest.
    case merge(conflict: ConflictPolicy)

    enum ConflictPolicy: String, Equatable {
        case skip      // --no-clobber: leave existing files untouched
        case replace   // default: delete + recreate existing files
    }
}

enum DestinationPlanError: Error, Equatable {
    case destinationIsFile   // requested dest already exists as a regular file
}

enum DestinationPlan {
    /// Pure decision. `destExists`/`destIsDirectory` describe the resolved
    /// requested path on the volume; `sourceIsDirectory` describes the host
    /// source; `noTargetDirectory`/`noClobber` are the CLI flags.
    static func resolve(
        destExists: Bool,
        destIsDirectory: Bool,
        sourceIsDirectory: Bool,
        noTargetDirectory: Bool,
        noClobber: Bool
    ) throws -> DestinationOutcome {
        let conflict: DestinationOutcome.ConflictPolicy = noClobber ? .skip : .replace
        if !destExists { return .new }
        if !destIsDirectory { throw DestinationPlanError.destinationIsFile }
        if noTargetDirectory && sourceIsDirectory { return .merge(conflict: conflict) }
        return .nest
    }
}
