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

    @Option(help: "Maximum MFT records to sweep. Default 4096; raise for larger volumes.")
    var maxRecords: UInt64 = 4096

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let mft = await volume.mft()

        print("Boot sector:              OK  (\(volume.boot.oemID.trimmingCharacters(in: .whitespaces)))")

        var inUseCount = 0
        var freeCount = 0
        var errorCount = 0
        var dirCount = 0
        var inUseUserRecords: Set<UInt64> = []
        var firstFewErrors: [(UInt64, String)] = []

        // Compute the actual MFT logical size from $MFT (record 0)'s $DATA
        // realSize so we don't read past the real MFT end into garbage.
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
                mftLogicalRecords = min(maxRecords, realSize / UInt64(volume.mftRecordSizeBytes))
            } else {
                mftLogicalRecords = maxRecords
            }
        } catch {
            mftLogicalRecords = maxRecords
        }

        for n in 0..<mftLogicalRecords {
            do {
                let record = try await mft.record(at: n)
                if record.isInUse {
                    inUseCount += 1
                    if record.isDirectory { dirCount += 1 }
                    if n >= 16 { inUseUserRecords.insert(n) }
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

        let reachableUserRecords = reachable.filter { $0 >= 16 }
        let orphans = inUseUserRecords.subtracting(reachableUserRecords)
        let dangling = reachableUserRecords.subtracting(inUseUserRecords)

        print("MFT sweep (records 0..\(maxRecords - 1)):")
        print("  In use (total):         \(inUseCount)")
        print("    User (>=16):          \(inUseUserRecords.count)")
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
        print("  Orphans (in MFT, not in tree): \(orphans.count)")
        print("  Dangling ($I30 entry but MFT slot free): \(dangling.count)")
        if verbose {
            for rn in orphans.sorted().prefix(20) {
                print("    orphan recnum \(rn)")
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

        if errorCount > 0 || !orphans.isEmpty || !dangling.isEmpty || !unreachableEnumerationErrors.isEmpty {
            print("\nVerify FAILED — \(errorCount) parse, \(orphans.count) orphan, \(dangling.count) dangling, \(unreachableEnumerationErrors.count) enum errors. Suggest running ntfsfix or chkdsk /f.")
            throw ExitCode(1)
        }
        print("\nVerify PASSED.")
    }
}
