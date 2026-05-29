import Foundation

// Pure, read-only diagnostics that cross-check a file's unnamed $DATA runlist
// against the volume $Bitmap (record 6). These functions perform NO writes and
// call no mutating Volume/Bitmap APIs — they exist to localize an OPEN bug
// where multi-extent $DATA files copied to real hardware read fine with our
// reader but throw I/O errors in macOS's native NTFS driver. Leading
// hypothesis: a post-cap rollback over-freed clusters belonging to committed
// files, leaving them marked FREE in $Bitmap (or reused), which a spec-strict
// reader rejects.
//
// THIS DOES NOT FIX THE BUG — it builds the cross-check a later `dump` /
// `verify --deep` consumes.
//
// Classification per non-sparse cluster LCN:
//   OUT_OF_RANGE  if lcn >= totalClusters
//   FREE(!)       else if !bitmap.isAllocated(cluster: lcn)
//   ALLOCATED     otherwise
// Sparse extents (startLCN == nil) have no physical clusters and contribute
// nothing to the allocation checks.

// MARK: - Per-extent audit

/// Audit of a single decoded $DATA extent against the $Bitmap.
public struct ExtentAudit: Sendable, Equatable {
    /// First VCN this extent covers.
    public let vcnStart: UInt64
    /// Number of clusters (VCNs) the extent spans (sparse or not).
    public let vcnCount: UInt64
    /// Starting LCN, or nil for a sparse run (no physical allocation).
    public let startLCN: UInt64?
    /// True when this is a sparse extent (startLCN == nil).
    public let isSparse: Bool

    /// Clusters in this extent that are within range AND set in $Bitmap.
    public let allocatedClusters: UInt64
    /// Clusters in this extent that are within range but FREE in $Bitmap —
    /// the smoking gun for the over-free bug.
    public let freeButReferencedClusters: UInt64
    /// Clusters in this extent whose LCN is >= the volume cluster count.
    public let outOfRangeClusters: UInt64
    /// True if any cluster in this extent lands inside a reserved region
    /// ($MFT / $MFTMirr / $Bitmap). Diagnostic only — overlap with a reserved
    /// region a file shouldn't share is itself suspicious.
    public let overlapsReserved: Bool

    public init(
        vcnStart: UInt64,
        vcnCount: UInt64,
        startLCN: UInt64?,
        isSparse: Bool,
        allocatedClusters: UInt64,
        freeButReferencedClusters: UInt64,
        outOfRangeClusters: UInt64,
        overlapsReserved: Bool
    ) {
        self.vcnStart = vcnStart
        self.vcnCount = vcnCount
        self.startLCN = startLCN
        self.isSparse = isSparse
        self.allocatedClusters = allocatedClusters
        self.freeButReferencedClusters = freeButReferencedClusters
        self.outOfRangeClusters = outOfRangeClusters
        self.overlapsReserved = overlapsReserved
    }
}

// MARK: - Per-record audit

/// Cross-check of one file's unnamed $DATA runlist against the volume $Bitmap.
public struct RunlistBitmapAudit: Sendable, Equatable {
    public let recordNumber: UInt64
    /// True if the record is a base record (baseFileReference == 0).
    public let isBaseRecord: Bool
    /// True if the unnamed $DATA was resolved via $ATTRIBUTE_LIST (i.e. the
    /// file is "migrated" — its $DATA lives in an extension record).
    public let hasAttributeList: Bool

    /// True when the unnamed $DATA is resident (no runlist to check).
    public let dataResident: Bool
    /// Non-resident $DATA real/allocated/initialized sizes and last VCN.
    /// All nil when resident (or when there is no unnamed $DATA at all).
    public let realSize: UInt64?
    public let allocatedSize: UInt64?
    public let initializedSize: UInt64?
    public let lastVCN: UInt64?

    /// Per-extent breakdown, in runlist order. Empty for resident $DATA.
    public let extents: [ExtentAudit]

    /// Aggregate: total clusters referenced by non-sparse extents.
    public let totalClustersReferenced: UInt64
    /// Aggregate: clusters referenced but FREE in $Bitmap.
    public let freeButReferencedCount: UInt64
    /// Aggregate: clusters referenced whose LCN is out of volume range.
    public let outOfRangeCount: UInt64

    /// Human-readable verdict lines. Empty ⇒ clean.
    public let anomalies: [String]

    public var isClean: Bool { anomalies.isEmpty }

    public init(
        recordNumber: UInt64,
        isBaseRecord: Bool,
        hasAttributeList: Bool,
        dataResident: Bool,
        realSize: UInt64?,
        allocatedSize: UInt64?,
        initializedSize: UInt64?,
        lastVCN: UInt64?,
        extents: [ExtentAudit],
        totalClustersReferenced: UInt64,
        freeButReferencedCount: UInt64,
        outOfRangeCount: UInt64,
        anomalies: [String]
    ) {
        self.recordNumber = recordNumber
        self.isBaseRecord = isBaseRecord
        self.hasAttributeList = hasAttributeList
        self.dataResident = dataResident
        self.realSize = realSize
        self.allocatedSize = allocatedSize
        self.initializedSize = initializedSize
        self.lastVCN = lastVCN
        self.extents = extents
        self.totalClustersReferenced = totalClustersReferenced
        self.freeButReferencedCount = freeButReferencedCount
        self.outOfRangeCount = outOfRangeCount
        self.anomalies = anomalies
    }
}

// MARK: - Whole-volume audit

/// One record's anomaly strings, surfaced from the whole-volume sweep so a
/// `--verbose` caller can print per-record detail. A named struct (not a
/// tuple) so Equatable synthesizes.
public struct RecordAnomalies: Sendable, Equatable {
    public let recordNumber: UInt64
    public let anomalies: [String]

    public init(recordNumber: UInt64, anomalies: [String]) {
        self.recordNumber = recordNumber
        self.anomalies = anomalies
    }
}

/// Result of sweeping every in-use base record's unnamed $DATA runlist against
/// the volume $Bitmap, plus cross-record double-allocation detection.
public struct VolumeRunlistAudit: Sendable, Equatable {
    /// Number of in-use base records whose $DATA was audited.
    public let filesChecked: UInt64
    /// Total non-sparse clusters verified across all audited files.
    public let runlistClustersVerified: UInt64
    /// Clusters referenced by some file but marked FREE in $Bitmap.
    public let freeButReferencedClusters: UInt64
    /// Clusters referenced whose LCN is out of volume range.
    public let outOfRangeClusters: UInt64
    /// Clusters referenced by two or more distinct base records.
    public let doubleAllocatedClusters: UInt64
    /// Records whose per-record audit threw — reported, not fatal.
    public let unreadableRecords: [UInt64]
    /// Per-record anomaly detail for a verbose caller (only records with
    /// non-empty anomalies are listed).
    public let perRecordAnomalies: [RecordAnomalies]

    /// Clean iff no free-but-referenced, out-of-range, or double-allocated
    /// clusters AND no unreadable records. Unreadable records count against
    /// cleanliness deliberately: a record we couldn't audit is a record whose
    /// runlist we cannot vouch for, so we can't certify the volume clean.
    public var isClean: Bool {
        freeButReferencedClusters == 0
            && outOfRangeClusters == 0
            && doubleAllocatedClusters == 0
            && unreadableRecords.isEmpty
    }

    public init(
        filesChecked: UInt64,
        runlistClustersVerified: UInt64,
        freeButReferencedClusters: UInt64,
        outOfRangeClusters: UInt64,
        doubleAllocatedClusters: UInt64,
        unreadableRecords: [UInt64],
        perRecordAnomalies: [RecordAnomalies]
    ) {
        self.filesChecked = filesChecked
        self.runlistClustersVerified = runlistClustersVerified
        self.freeButReferencedClusters = freeButReferencedClusters
        self.outOfRangeClusters = outOfRangeClusters
        self.doubleAllocatedClusters = doubleAllocatedClusters
        self.unreadableRecords = unreadableRecords
        self.perRecordAnomalies = perRecordAnomalies
    }
}

// MARK: - Reserved-region model

/// A half-open [start, end) LCN region that should not be shared by ordinary
/// files. Used to flag `overlapsReserved` on per-extent audits.
struct ReservedRegion: Sendable, Equatable {
    let startLCN: UInt64
    let clusterCount: UInt64
    var endLCN: UInt64 { startLCN &+ clusterCount }

    /// Does [otherStart, otherStart+otherCount) intersect this region?
    func overlaps(startLCN other: UInt64, count: UInt64) -> Bool {
        guard count > 0, clusterCount > 0 else { return false }
        let otherEnd = other &+ count
        return other < endLCN && startLCN < otherEnd
    }
}

extension Volume {

    // MARK: - (A) Per-record audit

    /// Cross-check the unnamed $DATA runlist of the file at `recordNumber`
    /// against the volume $Bitmap. PURE / read-only — performs no writes and
    /// calls no mutating APIs.
    ///
    /// Resolves the unnamed $DATA via `allAttributesOf` so a MIGRATED $DATA
    /// (living in an extension record) is found through the $ATTRIBUTE_LIST.
    /// Resident $DATA ⇒ no extents, trivially clean.
    public func auditDataRunlistAgainstBitmap(
        recordNumber: UInt64
    ) async throws -> RunlistBitmapAudit {
        let mft = self.mft()
        let baseRecord = try await mft.record(at: recordNumber)
        let isBaseRecord = baseRecord.isBaseRecord

        // "Migrated" detection: does the base record carry an $ATTRIBUTE_LIST?
        let baseAttrs = try baseRecord.attributes()
        let hasAttributeList = baseAttrs.contains {
            $0.rawType == AttributeType.attributeList.rawValue
        }

        // Resolve the unnamed $DATA through attribute-list-aware lookup.
        // v0.7 AC-5: route through the merge so audit walks every extent of
        // a multi-extension $DATA, not just the VCN-0 portion.
        let allAttrs = try await allAttributesOf(recordNumber: recordNumber)
        let dataAttr = try mergeMultiExtensionAttribute(
            in: allAttrs,
            rawType: AttributeType.data.rawValue,
            name: ""
        )

        // No unnamed $DATA (e.g. a pure directory) ⇒ nothing to check.
        guard let dataAttr else {
            return RunlistBitmapAudit(
                recordNumber: recordNumber,
                isBaseRecord: isBaseRecord,
                hasAttributeList: hasAttributeList,
                dataResident: false,
                realSize: nil,
                allocatedSize: nil,
                initializedSize: nil,
                lastVCN: nil,
                extents: [],
                totalClustersReferenced: 0,
                freeButReferencedCount: 0,
                outOfRangeCount: 0,
                anomalies: []
            )
        }

        // Resident $DATA ⇒ trivially clean, no runlist.
        guard case let .nonResident(
            _, lastVCN, _, _, allocatedSize, realSize, initializedSize, extents
        ) = dataAttr.value else {
            return RunlistBitmapAudit(
                recordNumber: recordNumber,
                isBaseRecord: isBaseRecord,
                hasAttributeList: hasAttributeList,
                dataResident: true,
                realSize: nil,
                allocatedSize: nil,
                initializedSize: nil,
                lastVCN: nil,
                extents: [],
                totalClustersReferenced: 0,
                freeButReferencedCount: 0,
                outOfRangeCount: 0,
                anomalies: []
            )
        }

        let bitmap = try await self.bitmap()
        let totalClusters = self.totalClusterCount
        let reserved = await reservedRegions()

        var extentAudits: [ExtentAudit] = []
        var vcn: UInt64 = 0
        var totalReferenced: UInt64 = 0
        var totalFreeButReferenced: UInt64 = 0
        var totalOutOfRange: UInt64 = 0
        var anomalies: [String] = []

        for extent in extents {
            let count = extent.clusterCount
            if extent.isSparse {
                // Sparse: no physical clusters, nothing to verify.
                extentAudits.append(ExtentAudit(
                    vcnStart: vcn,
                    vcnCount: count,
                    startLCN: nil,
                    isSparse: true,
                    allocatedClusters: 0,
                    freeButReferencedClusters: 0,
                    outOfRangeClusters: 0,
                    overlapsReserved: false
                ))
                vcn &+= count
                continue
            }

            guard let startLCN = extent.startLCN else {
                // Defensive: non-sparse extent without an LCN shouldn't happen.
                vcn &+= count
                continue
            }

            var allocated: UInt64 = 0
            var freeButRef: UInt64 = 0
            var outOfRange: UInt64 = 0

            var i: UInt64 = 0
            while i < count {
                let lcn = startLCN &+ i
                if lcn >= totalClusters {
                    outOfRange &+= 1
                } else if !bitmap.isAllocated(cluster: lcn) {
                    freeButRef &+= 1
                } else {
                    allocated &+= 1
                }
                i &+= 1
            }

            let overlapsReserved = reserved.contains {
                $0.overlaps(startLCN: startLCN, count: count)
            }

            totalReferenced &+= count
            totalFreeButReferenced &+= freeButRef
            totalOutOfRange &+= outOfRange

            if freeButRef > 0 {
                anomalies.append(
                    "extent VCN \(vcn) LCN \(startLCN)+\(count): \(freeButRef) cluster(s) FREE in $Bitmap but referenced"
                )
            }
            if outOfRange > 0 {
                anomalies.append(
                    "extent VCN \(vcn) LCN \(startLCN)+\(count): \(outOfRange) cluster(s) out of volume range (>= \(totalClusters))"
                )
            }
            // Reserved-region overlap is ADVISORY ONLY: it is surfaced via the
            // per-extent `overlapsReserved` flag (computed above and stored on
            // ExtentAudit) but is deliberately NOT appended to `anomalies`, so it
            // does not affect `RunlistBitmapAudit.isClean`. This keeps the
            // per-record verdict scoped to exactly free-but-referenced +
            // out-of-range, matching `VolumeRunlistAudit.isClean` / `verify
            // --deep` so the two commands can never disagree. Reserved-region
            // detection is best-effort/approximate ($MFTMirr uses a fallback),
            // so excluding it from the verdict also avoids false alarms.

            extentAudits.append(ExtentAudit(
                vcnStart: vcn,
                vcnCount: count,
                startLCN: startLCN,
                isSparse: false,
                allocatedClusters: allocated,
                freeButReferencedClusters: freeButRef,
                outOfRangeClusters: outOfRange,
                overlapsReserved: overlapsReserved
            ))

            vcn &+= count
        }

        return RunlistBitmapAudit(
            recordNumber: recordNumber,
            isBaseRecord: isBaseRecord,
            hasAttributeList: hasAttributeList,
            dataResident: false,
            realSize: realSize,
            allocatedSize: allocatedSize,
            initializedSize: initializedSize,
            lastVCN: lastVCN,
            extents: extentAudits,
            totalClustersReferenced: totalReferenced,
            freeButReferencedCount: totalFreeButReferenced,
            outOfRangeCount: totalOutOfRange,
            anomalies: anomalies
        )
    }

    // MARK: - (B) Whole-volume sweep

    /// Sweep every in-use BASE record's unnamed $DATA runlist against the
    /// volume $Bitmap, detecting free-but-referenced clusters, out-of-range
    /// clusters, and cross-record double-allocation. PURE / read-only.
    ///
    /// Extension records are skipped — their $DATA is reached via the base
    /// through `allAttributesOf`. Per-record errors are caught and reported in
    /// `unreadableRecords`, never thrown out of the sweep.
    ///
    /// `maxRecords == 0` (default) auto-bounds the sweep to $MFT's logical
    /// record count (record 0's $DATA realSize / mftRecordSizeBytes), mirroring
    /// `Verify.swift`.
    public func auditAllDataRunlistsAgainstBitmap(
        maxRecords: UInt64 = 0
    ) async throws -> VolumeRunlistAudit {
        let mft = self.mft()
        let totalClusters = self.totalClusterCount

        // Bound the sweep like Verify.swift: infer the MFT logical record
        // count from record 0's $DATA realSize.
        let mftLogicalRecords: UInt64
        do {
            let r0 = try await mft.record(at: 0)
            let attrs = try r0.attributes()
            if let dataAttr = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) {
                let realSize: UInt64
                switch dataAttr.value {
                case let .resident(b, _): realSize = UInt64(b.count)
                case let .nonResident(_, _, _, _, _, r, _, _): realSize = r
                }
                let inferred = realSize / UInt64(self.mftRecordSizeBytes)
                mftLogicalRecords = maxRecords == 0 ? inferred : min(maxRecords, inferred)
            } else {
                mftLogicalRecords = maxRecords == 0 ? 4096 : maxRecords
            }
        } catch {
            mftLogicalRecords = maxRecords == 0 ? 4096 : maxRecords
        }

        // Compact bitset over the volume's clusters to detect double
        // allocation. ~size of $Bitmap (~128 MB for a 4 TB/4 KB volume).
        let wordCount = Int((totalClusters + 63) / 64)
        var referenced = [UInt64](repeating: 0, count: wordCount)

        var filesChecked: UInt64 = 0
        var runlistClustersVerified: UInt64 = 0
        var freeButReferencedClusters: UInt64 = 0
        var outOfRangeClusters: UInt64 = 0
        var doubleAllocatedClusters: UInt64 = 0
        var unreadableRecords: [UInt64] = []
        var perRecordAnomalies: [RecordAnomalies] = []

        var n: UInt64 = 0
        while n < mftLogicalRecords {
            defer { n &+= 1 }
            do {
                let record = try await mft.record(at: n)
                guard record.isInUse else { continue }
                // Only base records; extension $DATA is reached via the base.
                guard record.isBaseRecord else { continue }

                let audit = try await auditDataRunlistAgainstBitmap(recordNumber: n)
                guard !audit.dataResident, !audit.extents.isEmpty else {
                    // Resident or no $DATA — counts as a checked file but no
                    // runlist clusters. (Directories with no $DATA included.)
                    filesChecked &+= 1
                    if !audit.anomalies.isEmpty {
                        perRecordAnomalies.append(
                            RecordAnomalies(recordNumber: n, anomalies: audit.anomalies)
                        )
                    }
                    continue
                }

                filesChecked &+= 1
                freeButReferencedClusters &+= audit.freeButReferencedCount
                outOfRangeClusters &+= audit.outOfRangeCount

                var recordAnomalies = audit.anomalies
                var recordDoubleAlloc: UInt64 = 0

                // Walk the in-range, allocated clusters again to mark the
                // double-allocation bitset. Out-of-range clusters can't be
                // indexed into the bitset, so they're skipped here (already
                // counted in outOfRangeClusters).
                for extent in audit.extents where !extent.isSparse {
                    guard let startLCN = extent.startLCN else { continue }
                    let count = extent.vcnCount
                    runlistClustersVerified &+= count
                    var i: UInt64 = 0
                    while i < count {
                        let lcn = startLCN &+ i
                        i &+= 1
                        guard lcn < totalClusters else { continue }
                        let word = Int(lcn / 64)
                        let bit = UInt64(1) << UInt64(lcn % 64)
                        if (referenced[word] & bit) != 0 {
                            recordDoubleAlloc &+= 1
                        } else {
                            referenced[word] |= bit
                        }
                    }
                }

                if recordDoubleAlloc > 0 {
                    doubleAllocatedClusters &+= recordDoubleAlloc
                    recordAnomalies.append(
                        "\(recordDoubleAlloc) cluster(s) double-allocated (also referenced by another record)"
                    )
                }

                if !recordAnomalies.isEmpty {
                    perRecordAnomalies.append(
                        RecordAnomalies(recordNumber: n, anomalies: recordAnomalies)
                    )
                }
            } catch let NTFSError.corruptOnDisk(desc) where desc.contains("magic 0x00000000") {
                // Zeroed/uninitialized MFT slot (the allocated-but-never-used
                // tail of $MFT). That's a FREE slot, NOT corruption, so it must
                // NOT count as unreadable and must NOT bump filesChecked. The
                // `defer { n &+= 1 }` above advances the loop, so an empty body
                // is correct here — we simply skip this slot. Mirrors the plain
                // MFT sweep in Verify.swift (the `magic 0x00000000` catch that
                // increments freeCount): on a clean 4 TB volume the empty MFT
                // tail (recnums past the last used record) must report 0
                // unreadable, not N.
            } catch {
                // Per-record failure: report, never abort the sweep.
                unreadableRecords.append(n)
            }
        }

        return VolumeRunlistAudit(
            filesChecked: filesChecked,
            runlistClustersVerified: runlistClustersVerified,
            freeButReferencedClusters: freeButReferencedClusters,
            outOfRangeClusters: outOfRangeClusters,
            doubleAllocatedClusters: doubleAllocatedClusters,
            unreadableRecords: unreadableRecords,
            perRecordAnomalies: perRecordAnomalies
        )
    }

    // MARK: - Helpers

    /// Total clusters described by the volume = totalSectors / sectorsPerCluster.
    var totalClusterCount: UInt64 {
        boot.totalSectors / UInt64(boot.sectorsPerCluster)
    }

    /// Reserved LCN regions an ordinary file should not occupy: $MFT,
    /// $MFTMirr, and $Bitmap. Read-only; best-effort — a region we can't
    /// resolve is simply omitted (it can't cause a false positive).
    private func reservedRegions() async -> [ReservedRegion] {
        var regions: [ReservedRegion] = []

        // $MFT (record 0) $DATA extents.
        if let mftExtents = await mftDataExtents() {
            for e in mftExtents where !e.isSparse {
                if let lcn = e.startLCN {
                    regions.append(ReservedRegion(startLCN: lcn, clusterCount: e.clusterCount))
                }
            }
        }

        // $MFTMirr (record 1) $DATA extents. Fall back to a single-cluster
        // region at boot.mftMirrorCluster if we can't resolve its runlist —
        // an approximation: $MFTMirr is conventionally a few clusters, so a
        // single cluster may under-cover it, but it never over-reports.
        if let mirrorExtents = try? await resolveDataExtents(recordNumber: 1),
           !mirrorExtents.isEmpty {
            for e in mirrorExtents where !e.isSparse {
                if let lcn = e.startLCN {
                    regions.append(ReservedRegion(startLCN: lcn, clusterCount: e.clusterCount))
                }
            }
        } else {
            regions.append(ReservedRegion(startLCN: boot.mftMirrorCluster, clusterCount: 1))
        }

        // $Bitmap (record 6) $DATA extents.
        if let bitmapExtents = try? await resolveDataExtents(recordNumber: Self.bitmapRecordNumber),
           !bitmapExtents.isEmpty {
            for e in bitmapExtents where !e.isSparse {
                if let lcn = e.startLCN {
                    regions.append(ReservedRegion(startLCN: lcn, clusterCount: e.clusterCount))
                }
            }
        }

        return regions
    }

    /// Resolve the non-resident unnamed $DATA extents of a record via
    /// attribute-list-aware lookup. Returns nil if there is no non-resident
    /// unnamed $DATA. Read-only.
    private func resolveDataExtents(recordNumber: UInt64) async throws -> [Extent]? {
        let attrs = try await allAttributesOf(recordNumber: recordNumber)
        // v0.7 AC-5: route through the merge so multi-extension $DATA returns
        // every VCN's extents, not just the VCN-0 portion (half-read bug).
        guard let dataAttr = try mergeMultiExtensionAttribute(
            in: attrs,
            rawType: AttributeType.data.rawValue,
            name: ""
        ) else {
            return nil
        }
        return dataAttr.value.nonResidentExtents
    }
}
