import ArgumentParser
import Foundation
import NTFSCore

/// Read-only volume sanity check. Walks the full MFT (not just records 0-63),
/// looks for in-use records that aren't reachable from root's $I30 (orphan
/// detection), and reports per-record parse errors.
struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Read-only sanity check — boot sector + full MFT sweep + orphan detection.",
        discussion: """
            Walks every MFT record (up to --max-records), parses each, walks the
            directory tree from root and compares the set of reachable in-use
            user records against the set found in the MFT. Mismatches are
            reported as orphans (in-MFT-but-unreachable) or dangling (in-tree-
            but-not-in-MFT). Returns non-zero exit if any errors are found.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Flag(name: [.short, .long], help: "Print per-record / per-orphan details.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Also run a whole-volume runlist↔$Bitmap + double-allocation sweep (catches free-but-referenced / out-of-range / double-allocated clusters the plain check misses).")
    var deep: Bool = false

    @Option(help: "Cap MFT sweep to this many records (0 = unlimited, auto-bounded by $MFT's logical size). Default 0.")
    var maxRecords: UInt64 = 0

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let mft = await volume.mft()

        print("Boot sector:              OK  (\(volume.boot.oemID.trimmingCharacters(in: .whitespaces)))")

        var inUseCount = 0
        var freeCount = 0
        var errorCount = 0
        var dirCount = 0
        // Summaries of every IN_USE user record (recnum >= 16), tagged
        // base-vs-extension so the classifier can keep migration extension
        // records (v0.5 Fix B) out of the orphan set — see MFTConsistency.
        var inUseUserSummaries: [InUseRecordSummary] = []
        var firstFewErrors: [(UInt64, String)] = []

        // Compute the actual MFT logical size from $MFT (record 0)'s $DATA
        // realSize so we don't read past the real MFT end into garbage —
        // AND so we don't silently false-pass volumes with corruption past
        // an arbitrary 4096-record cap. `--max-records 0` (default) means
        // scan the whole MFT bounded only by what $MFT.$DATA claims is real.
        let mftLogicalRecords: UInt64
        do {
            let mftRec = try await mft.record(at: 0)
            let attrs = try mftRec.attributes()
            if let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) {
                let realSize: UInt64
                switch dataAttr.value {
                case let .resident(b, _): realSize = UInt64(b.count)
                case let .nonResident(_, _, _, _, _, r, _, _): realSize = r
                }
                let inferred = realSize / UInt64(volume.mftRecordSizeBytes)
                mftLogicalRecords = maxRecords == 0 ? inferred : min(maxRecords, inferred)
            } else {
                mftLogicalRecords = maxRecords == 0 ? 4096 : maxRecords
            }
        } catch {
            mftLogicalRecords = maxRecords == 0 ? 4096 : maxRecords
        }

        for n in 0..<mftLogicalRecords {
            do {
                let record = try await mft.record(at: n)
                if record.isInUse {
                    inUseCount += 1
                    if record.isDirectory { dirCount += 1 }
                    if n >= 16 {
                        inUseUserSummaries.append(InUseRecordSummary(
                            recordNumber: n,
                            isBaseRecord: record.isBaseRecord,
                            baseRecordNumber: record.isBaseRecord
                                ? nil
                                : MFTConsistency.baseRecordNumber(
                                    fromBaseFileReference: record.baseFileReference)
                        ))
                    }
                    if verbose && n < 16 {
                        let attrs = (try? record.attributes()) ?? []
                        let kinds = attrs.compactMap { $0.type }.map { String(describing: $0) }.joined(separator: ",")
                        print(String(format: "MFT %4llu  IN_USE  attrs: %@", n, kinds))
                    }
                } else {
                    freeCount += 1
                }
            } catch let NTFSError.corruptOnDisk(desc) where desc.contains("magic 0x00000000") {
                // Zeroed MFT slot — that's a never-used slot, not corruption.
                freeCount += 1
            } catch {
                errorCount += 1
                if firstFewErrors.count < 10 {
                    firstFewErrors.append((n, "\(error)"))
                }
            }
        }

        // Walk the directory tree from root, collecting reachable record numbers.
        var reachable: Set<UInt64> = [5]   // root is reachable
        var visitQueue: [UInt64] = [5]
        var unreachableEnumerationErrors: [(UInt64, String)] = []
        while let dirRN = visitQueue.popLast() {
            do {
                let entries = try await volume.enumerate(directory: dirRN)
                for e in entries where e.fileName.namespace != .dos {
                    if !reachable.contains(e.recordNumber) {
                        reachable.insert(e.recordNumber)
                        if e.isDirectory {
                            visitQueue.append(e.recordNumber)
                        }
                    }
                }
            } catch {
                unreachableEnumerationErrors.append((dirRN, "\(error)"))
            }
        }

        // Classify the sweep. Orphans are now BASE records only — v0.5 Fix B
        // extension records (baseFileReference != 0) hold migrated $DATA /
        // $INDEX_ALLOCATION and are reachable only via their base, never via
        // $I30, so the old `inUse \ reachable` definition false-flagged every
        // one of them. The classifier keeps legitimate extensions out of the
        // orphan set and surfaces leaked extensions (base gone) separately.
        let reachableUserRecords = reachable.filter { $0 >= 16 }
        let classification = MFTConsistency.classifyInUseRecords(
            inUseUserSummaries, reachable: reachable)
        let orphans = classification.orphanBaseRecords
        // Dangling: a $I30 entry points at a slot the MFT doesn't have as an
        // IN_USE base. (Extensions are never named in $I30, so comparing
        // against base records is the right set.)
        let dangling = reachableUserRecords.subtracting(classification.baseRecords)
        let legitimateExtensions = classification.legitimateExtensions
        let leakedExtensions = classification.leakedExtensions

        print("MFT sweep (records 0..\(mftLogicalRecords - 1)):")
        print("  In use (total):         \(inUseCount)")
        print("    User (>=16):          \(inUseUserSummaries.count)")
        print("    Directories:          \(dirCount)")
        print("  Free:                   \(freeCount)")
        print("  Parse errors:           \(errorCount)")
        if verbose && !firstFewErrors.isEmpty {
            for (n, msg) in firstFewErrors {
                print(String(format: "    MFT %4llu  %@", n, msg))
            }
        }
        print("Directory tree (from root):")
        print("  Reachable user files:   \(reachableUserRecords.count)")
        print("  Extension records:      \(legitimateExtensions.count) (linked)")
        print("  Orphans (base record in MFT, not in tree): \(orphans.count)")
        print("  Leaked extensions (base record free): \(leakedExtensions.count)")
        print("  Dangling ($I30 entry but MFT slot free): \(dangling.count)")
        if verbose {
            for rn in orphans.sorted().prefix(20) {
                print("    orphan recnum \(rn)")
            }
            for rn in leakedExtensions.sorted().prefix(20) {
                print("    leaked extension recnum \(rn)")
            }
            for rn in dangling.sorted().prefix(20) {
                print("    dangling recnum \(rn)")
            }
        }
        if !unreachableEnumerationErrors.isEmpty {
            print("Directory enumeration errors:")
            for (rn, msg) in unreachableEnumerationErrors.prefix(10) {
                print("    dir recnum \(rn): \(msg)")
            }
        }

        let plainFailed = errorCount > 0 || !orphans.isEmpty || !leakedExtensions.isEmpty
            || !dangling.isEmpty || !unreachableEnumerationErrors.isEmpty

        // Opt-in deep pass: whole-volume runlist↔$Bitmap + double-allocation
        // sweep. PURE / read-only — the audit performs no writes. Reuses the
        // same --max-records bound as the MFT sweep above.
        var deepFailed = false
        var deepFreeButReferenced: UInt64 = 0
        var deepOutOfRange: UInt64 = 0
        var deepDoubleAllocated: UInt64 = 0
        var deepUnreadable = 0
        if deep {
            let audit = try await volume.auditAllDataRunlistsAgainstBitmap(maxRecords: maxRecords)
            deepFreeButReferenced = audit.freeButReferencedClusters
            deepOutOfRange = audit.outOfRangeClusters
            deepDoubleAllocated = audit.doubleAllocatedClusters
            deepUnreadable = audit.unreadableRecords.count
            print("Deep runlist/$Bitmap audit:")
            print("  Files checked:                \(audit.filesChecked)")
            print("  Runlist clusters verified:    \(audit.runlistClustersVerified)")
            print("  Free-but-referenced clusters: \(audit.freeButReferencedClusters)")
            print("  Out-of-range clusters:        \(audit.outOfRangeClusters)")
            print("  Double-allocated clusters:    \(audit.doubleAllocatedClusters)")
            print("  Unreadable records:           \(audit.unreadableRecords.count)")
            if verbose {
                if !audit.unreadableRecords.isEmpty {
                    for rn in audit.unreadableRecords.prefix(20) {
                        print("    unreadable recnum \(rn)")
                    }
                }
                for rec in audit.perRecordAnomalies.prefix(20) {
                    print("    recnum \(rec.recordNumber):")
                    for a in rec.anomalies {
                        print("      - \(a)")
                    }
                }
            }
            // Deep verdict: drive it directly off the audit's own cleanliness
            // rule so `verify --deep` and `VolumeRunlistAudit.isClean` can
            // never diverge. `isClean` fails on any free-but-referenced /
            // out-of-range / double-allocated cluster AND on any unreadable
            // record. After the audit's `magic 0x00000000` skip excludes the
            // zeroed/uninitialized $MFT tail, anything still in
            // `unreadableRecords` is a genuine record we couldn't audit and
            // cannot vouch for, so it correctly fails the run.
            deepFailed = !audit.isClean
        }

        if plainFailed || deepFailed {
            var reason = "\(errorCount) parse, \(orphans.count) orphan, \(leakedExtensions.count) leaked-extension, \(dangling.count) dangling, \(unreachableEnumerationErrors.count) enum errors"
            if deepFailed {
                reason += " — deep audit: \(deepFreeButReferenced) free-but-referenced, \(deepOutOfRange) out-of-range, \(deepDoubleAllocated) double-allocated cluster(s), \(deepUnreadable) unreadable record(s)"
            }
            print("\nVerify FAILED — \(reason). Suggest running ntfsfix or chkdsk /f.")
            throw ExitCode(1)
        }
        print("\nVerify PASSED.")
    }
}
