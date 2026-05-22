import ArgumentParser
import Foundation
import NTFSCore

/// Sweep the MFT for IN_USE-but-unreachable user records (orphans) and clear
/// them. The same operation chkdsk /f and ntfsfix perform when they reclaim
/// allocated-but-detached inodes. Provides a way to recover from old buggy
/// builds (e.g., the pre-v0.3 leaf-split silent-orphan bug) without needing
/// a Windows machine or a Linux Docker container.
///
/// Dry-run by default — pass --confirm to actually flip the IN_USE flag +
/// clear the $MFT.$BITMAP bit. Wraps mutations in beginWriteSession /
/// endWriteSession so the dirty bit flickers correctly.
struct ReclaimOrphans: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclaim-orphans",
        abstract: "Find and (optionally) clear orphaned MFT records.",
        discussion: """
            Walks every MFT record (bounded by $MFT's logical size), walks the
            directory tree from root, and identifies user records (recnum >= 16)
            that are IN_USE=1 but unreachable from any directory. For each such
            orphan, --confirm clears the IN_USE flag and frees the $MFT.$BITMAP
            bit — recovering the slot for future allocations.

            Use case: recovering from older buggy builds that produced silent
            orphans (e.g., pre-v0.3 leaf-split bug). The current build's
            createFile path correctly rolls back orphans on failure.

            Dry-run by default. Passes through `verify`'s identification logic
            so any orphan that `ntfsctl verify` flags is the same orphan this
            command would clean.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable to clean).")
    var device: String

    @Flag(name: .long, help: "Actually clean the orphans. Without this flag, only prints what WOULD be cleaned (dry-run).")
    var confirm: Bool = false

    @Flag(name: [.short, .long], help: "Print per-orphan details (recnum, $FILE_NAME if present).")
    var verbose: Bool = false

    @Option(help: "Cap MFT sweep at this many records (0 = unlimited, bounded by $MFT logical size). Default 0.")
    var maxRecords: UInt64 = 0

    func run() async throws {
        let blockDevice: FileHandleBlockDevice
        if confirm {
            blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        } else {
            blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        }
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let mft = await volume.mft()

        // Step 1: bound the sweep — same logic verify uses, so the two
        // commands agree on what counts as in-MFT.
        let mftLogicalRecords: UInt64
        do {
            let mftRecord = try await mft.record(at: 0)
            let attrs = try mftRecord.attributes()
            if let data = attrs.first(where: { $0.type == .data }) {
                let realSize: UInt64
                switch data.value {
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

        // Step 2: collect all IN_USE user records, tagged base-vs-extension so
        // the classifier can keep v0.5 Fix B migration extension records out of
        // the reclaim set (see MFTConsistency). An extension record holds a
        // live file's migrated $DATA / $INDEX_ALLOCATION and is reachable only
        // via its base — freeing one corrupts the base file.
        var inUseUserSummaries: [InUseRecordSummary] = []
        for n: UInt64 in 0..<mftLogicalRecords {
            do {
                let rec = try await mft.record(at: n)
                if rec.isInUse, n >= 16 {
                    inUseUserSummaries.append(InUseRecordSummary(
                        recordNumber: n,
                        isBaseRecord: rec.isBaseRecord,
                        baseRecordNumber: rec.isBaseRecord
                            ? nil
                            : MFTConsistency.baseRecordNumber(
                                fromBaseFileReference: rec.baseFileReference)
                    ))
                }
            } catch {
                // Parse failure / zeroed slot — skip; verify would flag this
                // separately. reclaim-orphans only touches valid IN_USE slots.
                continue
            }
        }

        // Step 3: walk the directory tree from root → reachable set.
        var reachable: Set<UInt64> = [5]
        var queue: [UInt64] = [5]
        while let dir = queue.popLast() {
            do {
                let entries = try await volume.enumerate(directory: dir)
                for e in entries where e.fileName.namespace != .dos {
                    if !reachable.contains(e.recordNumber) {
                        reachable.insert(e.recordNumber)
                        if e.isDirectory { queue.append(e.recordNumber) }
                    }
                }
            } catch {
                // Skip unreachable dirs; verify will flag the corruption.
                continue
            }
        }

        // Classify. Reclaim acts on orphaned BASE records and on base-FREE
        // leaked extensions. A legitimate extension's slot belongs to a live
        // base file — freeing it detaches the migrated $DATA / $INDEX_ALLOCATION
        // and corrupts that file, so legitimate extensions are NEVER reclaimed.
        let classification = MFTConsistency.classifyInUseRecords(
            inUseUserSummaries, reachable: reachable)
        let extensionRecnums = classification.legitimateExtensions
            .union(classification.leakedExtensions)

        // The classifier's `leakedExtensions` conflates "base genuinely free"
        // (reclaimable) with "base IN_USE-but-unparseable" (a LIVE file we must
        // not touch), because classifyInUseRecords only sees the IN_USE records
        // the sweep PARSED — a leaked extension's base may be IN_USE yet absent
        // from the parsed set. So AUTHORITATIVELY read each leaked extension's
        // base record off disk; a base counts as free ONLY if the read succeeds
        // and IN_USE=0. Read failure or IN_USE=1 ⇒ defer (default-deny).
        var basesConfirmedFree: Set<UInt64> = []
        let leakedBaseRecnums = Set(
            inUseUserSummaries
                .filter { classification.leakedExtensions.contains($0.recordNumber) }
                .compactMap { $0.baseRecordNumber }
        )
        for baseRN in leakedBaseRecnums {
            do {
                let rec = try await mft.record(at: baseRN)
                if !rec.isInUse { basesConfirmedFree.insert(baseRN) }
            } catch {
                // Ambiguous (parse error / out of bounds) ⇒ defer, don't free.
                continue
            }
        }

        let split = MFTConsistency.splitLeakedExtensions(
            inUseUserSummaries,
            leakedExtensions: classification.leakedExtensions,
            basesConfirmedFree: basesConfirmedFree)

        // Reclaim set: orphaned BASE records (empty-resident, freed via
        // reclaimOrphanedMFTRecord) PLUS base-free leaked EXTENSIONS (freed via
        // freeExtensionRecord, which also releases their non-resident clusters).
        // Orphans always exclude ALL extensions (a base record is never an
        // extension); the two reclaim sets are disjoint and freed differently.
        let orphans = classification.orphanBaseRecords
            .subtracting(extensionRecnums)
            .sorted()
        let baseFreeExtensions = split.baseFreeExtensions.sorted()

        // Safety invariant (AC-10): the reclaim set must NEVER include a
        // legitimate extension (base IN_USE → live file) or an unresolved one
        // (base not provably free → could be live). Assert it explicitly so a
        // future refactor can't reintroduce the "freed a live file's extension"
        // corruption.
        let reclaimSet = Set(orphans).union(baseFreeExtensions)
        precondition(
            reclaimSet.isDisjoint(with: classification.legitimateExtensions),
            "reclaim-orphans invariant violated: a legitimate extension reached the reclaim set"
        )
        precondition(
            reclaimSet.isDisjoint(with: split.baseUnresolvedExtensions),
            "reclaim-orphans invariant violated: a base-unresolved extension reached the reclaim set"
        )

        // Step 4: report.
        print("MFT sweep:               records 0..\(mftLogicalRecords - 1)")
        print("In-use user records:     \(inUseUserSummaries.count)")
        print("Reachable from root:     \(reachable.filter { $0 >= 16 }.count)")
        print("Extension records:       \(classification.legitimateExtensions.count) (linked, never reclaimed)")
        print("Orphans found:           \(orphans.count)")

        if !classification.leakedExtensions.isEmpty {
            print("Leaked extensions:       \(classification.leakedExtensions.count) total")
            print("  reclaimable (base free): \(split.baseFreeExtensions.count)")
            if !split.baseUnresolvedExtensions.isEmpty {
                print("  deferred (base in use / unparseable): \(split.baseUnresolvedExtensions.count) (run `chkdsk /f`)")
            }
        }

        if orphans.isEmpty && baseFreeExtensions.isEmpty {
            if split.baseUnresolvedExtensions.isEmpty {
                print("No orphans to reclaim. Volume is clean.")
            } else {
                print("No reclaimable records, but deferred leaked extensions exist — run `chkdsk /f`.")
            }
            return
        }

        if verbose {
            for rn in orphans.prefix(50) {
                var label = "orphan recnum \(rn)"
                if let rec = try? await mft.record(at: rn),
                   let attrs = try? rec.attributes() {
                    // Find a $FILE_NAME (any namespace) and print its name + parent ref.
                    for a in attrs where a.type == .fileName {
                        if case let .resident(body, _) = a.value,
                           let fn = try? FileName.parse(body) {
                            label += "  name='\(fn.name)' parent_ref=\(fn.parentRecordNumber)"
                            break
                        }
                    }
                }
                print("  \(label)")
            }
            if orphans.count > 50 {
                print("  … (\(orphans.count - 50) more)")
            }
            for rn in baseFreeExtensions.prefix(50) {
                print("  base-free extension recnum \(rn) (clusters + slot will be freed)")
            }
            if baseFreeExtensions.count > 50 {
                print("  … (\(baseFreeExtensions.count - 50) more)")
            }
        }

        let totalToReclaim = orphans.count + baseFreeExtensions.count

        if !confirm {
            print("")
            print("Dry-run — no changes made. Re-run with --confirm to clear the IN_USE flag")
            print("and free the $MFT.$BITMAP bit for each orphan, and to free the clusters +")
            print("slot of each base-free leaked extension listed above.")
            return
        }

        // Step 5: clean. Wrap in dirty-bit transaction. Orphan base records are
        // empty-resident — reclaimOrphanedMFTRecord just flips the slot. Base-
        // free leaked extensions own non-resident clusters, so they go through
        // freeExtensionRecord (frees clusters FIRST, then the slot — AC-9).
        try await volume.beginWriteSession()
        var cleaned = 0
        var failed: [(UInt64, String)] = []
        for rn in orphans {
            do {
                try await volume.reclaimOrphanedMFTRecord(at: rn)
                cleaned += 1
            } catch {
                failed.append((rn, "\(error)"))
            }
        }
        for rn in baseFreeExtensions {
            do {
                try await volume.freeExtensionRecord(at: rn)
                cleaned += 1
            } catch {
                failed.append((rn, "\(error)"))
            }
        }
        try await volume.endWriteSession()
        try await blockDevice.synchronize()

        print("")
        print("Reclaimed:               \(cleaned)/\(totalToReclaim) record(s)")
        if !failed.isEmpty {
            print("Failed:                  \(failed.count)")
            for (rn, msg) in failed.prefix(10) {
                print("  recnum \(rn): \(msg)")
            }
        }
        print("")
        print("Re-run `ntfsctl verify \(device)` to confirm a clean tree.")
    }
}
