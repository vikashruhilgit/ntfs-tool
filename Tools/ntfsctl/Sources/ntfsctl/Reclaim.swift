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

        // Classify. Reclaim acts ONLY on orphaned BASE records. Extension
        // records (legitimate OR leaked) are never reclaimed: a legitimate
        // extension's slot belongs to a live base file, and freeing it detaches
        // the migrated $DATA / $INDEX_ALLOCATION and corrupts that file; a
        // leaked extension needs base-side / $ATTRIBUTE_LIST fixup that v0.5
        // doesn't do, so we defer it to chkdsk /f rather than free it blind.
        let classification = MFTConsistency.classifyInUseRecords(
            inUseUserSummaries, reachable: reachable)
        let extensionRecnums = classification.legitimateExtensions
            .union(classification.leakedExtensions)

        // Defensive guard: orphanBaseRecords excludes extensions BY
        // CONSTRUCTION, but assert it explicitly so a future refactor of the
        // classifier can never reintroduce the "reclaim freed an extension and
        // corrupted the base" bug. Reclaim must NEVER touch an extension slot.
        let orphans = classification.orphanBaseRecords
            .subtracting(extensionRecnums)
            .sorted()
        precondition(
            Set(orphans).isDisjoint(with: extensionRecnums),
            "reclaim-orphans invariant violated: an extension record reached the reclaim set"
        )

        // Step 4: report.
        print("MFT sweep:               records 0..\(mftLogicalRecords - 1)")
        print("In-use user records:     \(inUseUserSummaries.count)")
        print("Reachable from root:     \(reachable.filter { $0 >= 16 }.count)")
        print("Extension records:       \(classification.legitimateExtensions.count) (linked, never reclaimed)")
        print("Orphans found:           \(orphans.count)")

        if !classification.leakedExtensions.isEmpty {
            // Leaked extensions are a real defect but not safe to auto-free in
            // v0.5 (would need to also repair the base / $ATTRIBUTE_LIST).
            print("Leaked extensions:       \(classification.leakedExtensions.count) (NOT reclaimed — run `chkdsk /f`)")
        }

        if orphans.isEmpty {
            if classification.leakedExtensions.isEmpty {
                print("No orphans to reclaim. Volume is clean.")
            } else {
                print("No orphan base records to reclaim, but leaked extensions exist — run `chkdsk /f`.")
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
        }

        if !confirm {
            print("")
            print("Dry-run — no changes made. Re-run with --confirm to clear the IN_USE flag")
            print("and free the $MFT.$BITMAP bit for each orphan listed above.")
            return
        }

        // Step 5: clean. Wrap in dirty-bit transaction.
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
        try await volume.endWriteSession()
        try await blockDevice.synchronize()

        print("")
        print("Reclaimed:               \(cleaned)/\(orphans.count) orphan(s)")
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
