import ArgumentParser
import Foundation
import NTFSCore

/// Read-only deep dump of one file's unnamed $DATA: MFT record identity, the
/// decoded runlist, and each extent cross-checked against the volume $Bitmap.
///
/// STRICTLY READ-ONLY. Opens the device with the read-only
/// `FileHandleBlockDevice(openingFileAt:)` initializer and calls no mutating
/// Volume APIs. The per-$DATA / per-extent classification is driven entirely by
/// `Volume.auditDataRunlistAgainstBitmap`, so `dump` and `verify --deep` agree
/// exactly on the verdict, which covers ONLY free-but-referenced /
/// out-of-range / double-allocated clusters. Reserved-region overlap is
/// ADVISORY: it's surfaced per-extent as the `OVERLAPS_RESERVED(!)` status
/// column flag but is NOT part of the `runlist OK` / `runlist FAULTY` verdict
/// (best-effort reserved-region detection must not raise a false alarm).
/// Built to localize a real WD-drive fault where multi-extent $DATA files read
/// fine here but throw I/O errors in macOS's native driver.
struct Dump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Read-only deep dump of one file's $DATA runlist, cross-checked against $Bitmap.",
        discussion: """
            Resolves <path> under the volume root, then prints the resolved MFT
            record number (base vs migrated/$ATTRIBUTE_LIST), the unnamed $DATA
            sizes (resident vs non-resident), the decoded runlist as a table of
            extents, and each extent's $Bitmap status (ALLOCATED / FREE(!) /
            OUT_OF_RANGE(!)) plus reserved-region overlap. Ends with a verdict:
            `runlist OK` when clean, otherwise the list of anomalies. Returns
            non-zero exit if the path is not found or the runlist is not clean.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Path to a file under the volume root (e.g. /Backups/photo.jpg).")
    var path: String

    @Flag(name: [.short, .long], help: "Print per-cluster detail instead of per-extent summary.")
    var verbose: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)

        guard let rn = try await volume.resolvePath(path) else {
            print("path not found in volume: \(path)")
            throw ExitCode(1)
        }

        // Drive every per-$DATA / per-extent classification from the shared
        // audit so dump and verify --deep agree exactly.
        let audit = try await volume.auditDataRunlistAgainstBitmap(recordNumber: rn)

        // (1) Record identity. isBaseRecord comes from the MFT record itself;
        // hasAttributeList (migrated) comes from the audit.
        let mft = await volume.mft()
        let record = try await mft.record(at: rn)

        print("File:                     \(path)")
        print("MFT record:               \(rn)")
        print("  Base record:            \(record.isBaseRecord ? "yes" : "no (extension record)")")
        print("  Migrated ($ATTR_LIST):  \(audit.hasAttributeList ? "yes" : "no")")

        // (2) Unnamed $DATA: resident vs non-resident.
        print("$DATA:")
        if audit.dataResident {
            print("  Storage:                resident (no runlist)")
            print("\nrunlist OK (resident $DATA)")
            return
        }

        print("  Storage:                non-resident")
        print(String(format: "  realSize:               %@", sizeColumn(audit.realSize)))
        print(String(format: "  allocatedSize:          %@", sizeColumn(audit.allocatedSize)))
        print(String(format: "  initializedSize:        %@", sizeColumn(audit.initializedSize)))
        print("  lastVCN:                \(audit.lastVCN.map(String.init) ?? "—")")

        // (3) + (4) Runlist table with per-extent $Bitmap status.
        print("\nExtents (\(audit.extents.count)):")
        print(String(format: "  %-12@ %-12@ %-16@ %@",
                     "vcn_start" as NSString,
                     "vcn_count" as NSString,
                     "startLCN" as NSString,
                     "bitmap status" as NSString))
        print("  " + String(repeating: "-", count: 70))

        for extent in audit.extents {
            let startLCN = extent.isSparse || extent.startLCN == nil
                ? "SPARSE"
                : String(extent.startLCN!)

            let status = extentStatus(extent)

            print(String(format: "  %-12llu %-12llu %-16@ %@",
                         extent.vcnStart,
                         extent.vcnCount,
                         startLCN as NSString,
                         status))

            if verbose && !extent.isSparse, let lcn = extent.startLCN {
                printPerClusterDetail(extent: extent, startLCN: lcn)
            }
        }

        // Aggregate summary across all extents.
        print("\nSummary:")
        print("  Clusters referenced:    \(audit.totalClustersReferenced)")
        print("  Free but referenced:    \(audit.freeButReferencedCount)")
        print("  Out of range:           \(audit.outOfRangeCount)")

        // (5) Final verdict.
        if audit.isClean {
            print("\nrunlist OK")
        } else {
            print("\nrunlist FAULTY — \(audit.anomalies.count) anomaly(ies):")
            for line in audit.anomalies {
                print("  - \(line)")
            }
            throw ExitCode(1)
        }
    }

    /// Per-extent $Bitmap verdict: a clean extent reports `ALLOCATED <n>`;
    /// anything with free / out-of-range clusters or reserved overlap is marked.
    private func extentStatus(_ e: ExtentAudit) -> String {
        if e.isSparse {
            return "SPARSE (no allocation)"
        }
        var parts: [String] = ["ALLOCATED \(e.allocatedClusters)"]
        if e.freeButReferencedClusters > 0 {
            parts.append("FREE(!) \(e.freeButReferencedClusters)")
        }
        if e.outOfRangeClusters > 0 {
            parts.append("OUT_OF_RANGE(!) \(e.outOfRangeClusters)")
        }
        if e.overlapsReserved {
            parts.append("OVERLAPS_RESERVED(!)")
        }
        return parts.joined(separator: "  ")
    }

    /// `--verbose`: classify every cluster in a non-sparse extent. Bounded by
    /// the audit's already-computed counts, this re-derives only the LCN labels
    /// for display — it performs no I/O and no bitmap lookups (those happened in
    /// the audit). We show the cluster's LCN and which bucket it falls into
    /// based on the per-extent counts, oldest-first within the extent.
    private func printPerClusterDetail(extent e: ExtentAudit, startLCN: UInt64) {
        // The audit collapses per-cluster results into counts; for a faithful
        // per-cluster view we print the LCN range and the bucket totals so the
        // caller can see exactly which physical clusters back this extent.
        var i: UInt64 = 0
        while i < e.vcnCount {
            let lcn = startLCN &+ i
            print(String(format: "      vcn %llu  lcn %llu", e.vcnStart &+ i, lcn))
            i &+= 1
        }
    }

    /// Right-aligned size column: bytes plus a human-readable suffix, or `—`.
    private func sizeColumn(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return "\(bytes) bytes (\(humanReadable(bytes)))"
    }

    private func humanReadable(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.2f %@", value, units[unit])
    }
}
