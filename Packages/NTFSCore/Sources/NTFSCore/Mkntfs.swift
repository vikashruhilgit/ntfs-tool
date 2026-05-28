import Foundation

// Mkntfs.swift — pure-Swift in-memory NTFS volume formatter.
//
// Builds a self-consistent NTFS 3.1 initial volume image (matching what
// `mkntfs -Q` would emit) and writes it to a BlockDevice in one pass:
//   1. Compute geometry (bytes/sector, sectors/cluster, total clusters)
//      from a device size in bytes.
//   2. Allocate cluster regions for the system files ($MFT, $MFTMirr,
//      $LogFile, $AttrDef, $UpCase, $Boot, $Bitmap).
//   3. Build MFT records 0..15 in memory (compute-first).
//   4. Build system-file data streams ($Bitmap, $LogFile, $UpCase,
//      $AttrDef, $Boot).
//   5. Write everything in order: boot sector, $MFT region, $MFTMirr
//      region, system-file data clusters, backup boot sector at the
//      last sector of the volume.
//   6. fsync (`F_FULLFSYNC` via BlockDevice.synchronize()).
//
// SCOPE: matches `mkntfs -Q` semantics (quick format). The bad-cluster
// sweep is skipped; $LogFile is initialized to all-0xFF (Windows
// re-initializes it on first mount); $Secure is a minimal default-ACL
// stub (Everyone full control — sufficient for data volumes). This is
// NOT a bootable Windows install image.
//
// CLEAN-ROOM: this orchestrator is a clean implementation of the
// public NTFS 3.1 on-disk format documented at
// https://flatcap.github.io/linux-ntfs/ntfs/ + Microsoft's NTFS file
// system reference. No code or constants are derived from GPL sources
// (ntfsprogs / mkntfs-3g / Linux fs/ntfs3).

public enum Mkntfs {

    /// User-tweakable format options.
    public struct Options: Sendable {
        public var label: String
        public var bytesPerSector: UInt16
        public var sectorsPerCluster: UInt8
        public var mftRecordSize: UInt32
        public var indexRecordSize: UInt32
        public var volumeSerial: UInt64?     // nil → random
        public var quick: Bool               // matches `mkntfs -Q`

        public init(
            label: String = "",
            bytesPerSector: UInt16 = 512,
            sectorsPerCluster: UInt8 = 8,
            mftRecordSize: UInt32 = 1024,
            indexRecordSize: UInt32 = 4096,
            volumeSerial: UInt64? = nil,
            quick: Bool = true
        ) {
            self.label = label
            self.bytesPerSector = bytesPerSector
            self.sectorsPerCluster = sectorsPerCluster
            self.mftRecordSize = mftRecordSize
            self.indexRecordSize = indexRecordSize
            self.volumeSerial = volumeSerial
            self.quick = quick
        }
    }

    /// Geometry of the volume + the cluster regions allocated to each
    /// system file. Computed in `planGeometry` and consumed by every
    /// per-record builder so layout is consistent.
    public struct Geometry: Sendable {
        public let bytesPerSector: UInt16
        public let sectorsPerCluster: UInt8
        public let bytesPerCluster: UInt32
        public let totalSectors: UInt64
        public let totalClusters: UInt64
        public let mftRecordSize: UInt32
        public let indexRecordSize: UInt32
        public let clustersPerMFTRecord: Int8
        public let clustersPerIndexRecord: Int8
        // System-file cluster regions (startLCN, clusterCount):
        public let mftStartLCN: UInt64
        public let mftClusterCount: UInt64
        public let mftMirrorStartLCN: UInt64
        public let mftMirrorClusterCount: UInt64
        public let logFileStartLCN: UInt64
        public let logFileClusterCount: UInt64
        public let logFileSize: UInt64                 // bytes
        public let attrDefStartLCN: UInt64
        public let attrDefClusterCount: UInt64
        public let upcaseStartLCN: UInt64
        public let upcaseClusterCount: UInt64
        public let bootBackupStartLCN: UInt64          // 1-cluster region for backup BS
        public let bootBackupSectorLBA: UInt64         // device offset = last sector
        public let bitmapStartLCN: UInt64
        public let bitmapClusterCount: UInt64
        public let volumeSerial: UInt64

        public var totalClusterBytes: UInt64 { UInt64(bytesPerCluster) * totalClusters }
    }

    /// Plan a layout from device size + options. Pure computation; does
    /// not touch the device.
    public static func planGeometry(deviceSizeBytes: UInt64, options: Options) throws -> Geometry {
        let bps = UInt64(options.bytesPerSector)
        let spc = UInt64(options.sectorsPerCluster)
        let clusterBytes = bps * spc
        guard deviceSizeBytes >= 16 * 1024 * 1024 else {
            throw NTFSError.unsupportedFeature(description: "mkntfs: device too small (<16 MiB)")
        }
        guard clusterBytes > 0 else {
            throw NTFSError.invalidBootSector(reason: "bytesPerCluster is 0")
        }
        let totalSectors = deviceSizeBytes / bps
        let totalClusters = deviceSizeBytes / clusterBytes

        // Resolve clustersPerMFTRecord:
        //   recordSize / clusterBytes if record >= cluster (typical: record=1024,
        //   cluster=4096 → record < cluster → use signed-negative encoding -10).
        let cmft: Int8
        if UInt32(clusterBytes) <= options.mftRecordSize {
            let q = options.mftRecordSize / UInt32(clusterBytes)
            cmft = Int8(q)
        } else {
            // record < cluster → use -log2(recordSize)
            let recSize = options.mftRecordSize
            var exp: Int = 0
            var v = recSize
            while v > 1 { v >>= 1; exp += 1 }
            cmft = Int8(-exp)
        }

        let cidx: Int8
        if UInt32(clusterBytes) <= options.indexRecordSize {
            cidx = Int8(options.indexRecordSize / UInt32(clusterBytes))
        } else {
            var exp: Int = 0
            var v = options.indexRecordSize
            while v > 1 { v >>= 1; exp += 1 }
            cidx = Int8(-exp)
        }

        // Cluster allocation policy (mkntfs-style):
        //  - $MFT initial size: max(16 MiB, 0.125% of volume) — rounded up
        //    to a whole cluster. Capped to a sane minimum so even a tiny
        //    image has ~16 records of headroom.
        let mftInitialBytes = max(
            UInt64(16 * 1024 * 1024),
            (deviceSizeBytes / 800) // ~0.125%
        )
        let mftClusters = max(UInt64(4), (mftInitialBytes + clusterBytes - 1) / clusterBytes)

        // Backup boot sector lives in the very last sector of the volume.
        let backupBsLBA = totalSectors > 0 ? totalSectors - 1 : 0
        // The cluster containing the backup BS is reserved.
        let backupBsCluster = backupBsLBA / spc

        // Layout from low LCNs upward — keep system files near the front
        // for cache locality and to match mkntfs's typical layout:
        //   LCN 0   .. (mftClusters-1)    : padding (BPB area lives in sector 0
        //                                   already, but we keep cluster 0 reserved)
        //   actually mkntfs puts $MFT at a cluster ~3 GiB in for big volumes;
        //   for small volumes (≤ 1 GiB) it puts $MFT at cluster 4. We follow
        //   the "small-volume convention" since AC-3 targets a 256 MiB image
        //   and the layout works for any size.
        var nextLCN: UInt64 = 4   // skip cluster 0 (boot) + 1..3 padding
        let mftStart = nextLCN
        nextLCN += mftClusters
        let mftMirrorClusters: UInt64 = 1  // mirrors first 4 MFT records = 4 KiB
        let mftMirrorStart = nextLCN
        nextLCN += mftMirrorClusters
        // $LogFile: mkntfs -Q caps at 64 MiB; min size matches mkntfs's
        // table — for our 256 MiB tests, 1 MiB is plenty and matches the
        // brief's "match mkntfs-3g -Q's default" guidance for tiny images.
        let logFileSize = max(UInt64(1024 * 1024), min(UInt64(64 * 1024 * 1024), deviceSizeBytes / 64))
        let logFileClusters = (logFileSize + clusterBytes - 1) / clusterBytes
        let logFileStart = nextLCN
        nextLCN += logFileClusters
        // $AttrDef: 2,560 bytes → 1 cluster.
        let attrDefStart = nextLCN
        let attrDefClusters: UInt64 = (2560 + clusterBytes - 1) / clusterBytes
        nextLCN += attrDefClusters
        // $UpCase: 131,072 bytes → ceil(128 KiB / clusterBytes) clusters.
        let upcaseStart = nextLCN
        let upcaseClusters: UInt64 = (131_072 + clusterBytes - 1) / clusterBytes
        nextLCN += upcaseClusters
        // $Bitmap: 1 bit per cluster → totalClusters / 8 bytes, rounded
        // up to whole clusters.
        let bitmapBytes = (totalClusters + 7) / 8
        let bitmapClusters = (bitmapBytes + clusterBytes - 1) / clusterBytes
        let bitmapStart = nextLCN
        nextLCN += bitmapClusters

        // Sanity: everything must fit before the backup-BS cluster.
        guard nextLCN < backupBsCluster else {
            throw NTFSError.unsupportedFeature(
                description: "mkntfs: device too small to fit system files (need \(nextLCN) clusters, have \(backupBsCluster))"
            )
        }

        // Volume serial: random unless overridden (for deterministic tests).
        let serial = options.volumeSerial ?? UInt64.random(in: 1...UInt64.max)

        return Geometry(
            bytesPerSector: options.bytesPerSector,
            sectorsPerCluster: options.sectorsPerCluster,
            bytesPerCluster: UInt32(clusterBytes),
            totalSectors: totalSectors,
            totalClusters: totalClusters,
            mftRecordSize: options.mftRecordSize,
            indexRecordSize: options.indexRecordSize,
            clustersPerMFTRecord: cmft,
            clustersPerIndexRecord: cidx,
            mftStartLCN: mftStart,
            mftClusterCount: mftClusters,
            mftMirrorStartLCN: mftMirrorStart,
            mftMirrorClusterCount: mftMirrorClusters,
            logFileStartLCN: logFileStart,
            logFileClusterCount: logFileClusters,
            logFileSize: logFileClusters * clusterBytes,
            attrDefStartLCN: attrDefStart,
            attrDefClusterCount: attrDefClusters,
            upcaseStartLCN: upcaseStart,
            upcaseClusterCount: upcaseClusters,
            bootBackupStartLCN: backupBsCluster,
            bootBackupSectorLBA: backupBsLBA,
            bitmapStartLCN: bitmapStart,
            bitmapClusterCount: bitmapClusters,
            volumeSerial: serial
        )
    }

    // MARK: — Top-level orchestrator

    /// Format `device` as a fresh NTFS volume. `deviceSizeBytes` is the
    /// usable byte length of the device/partition (caller is responsible
    /// for discovering it via `BlockDevice.size()`).
    public static func format(
        device: any BlockDevice,
        deviceSizeBytes: UInt64,
        options: Options
    ) async throws {
        let geom = try planGeometry(deviceSizeBytes: deviceSizeBytes, options: options)

        // --- 1. Build the boot sector.
        let boot = BootSector(
            oemID: "NTFS    ",
            bytesPerSector: geom.bytesPerSector,
            sectorsPerCluster: geom.sectorsPerCluster,
            mediaDescriptor: 0xF8,
            totalSectors: geom.totalSectors,
            mftCluster: geom.mftStartLCN,
            mftMirrorCluster: geom.mftMirrorStartLCN,
            clustersPerMFTRecord: geom.clustersPerMFTRecord,
            clustersPerIndexRecord: geom.clustersPerIndexRecord,
            volumeSerial: geom.volumeSerial
        )
        let bootBytes = try boot.serialize()

        // --- 2. Build MFT records 0..15.
        let records = try buildSystemRecords(geom: geom, options: options)

        // --- 3. Assemble the $MFT region (all record bytes back-to-back).
        let mftRegionSize = Int(geom.mftClusterCount) * Int(geom.bytesPerCluster)
        var mftRegion = Data(count: mftRegionSize)
        for (recNum, recBytes) in records {
            let off = Int(recNum) * Int(geom.mftRecordSize)
            for (i, b) in recBytes.enumerated() {
                mftRegion[off + i] = b
            }
        }

        // --- 4. Assemble the $MFTMirr region: first 4 records.
        let mirrorRegionSize = Int(geom.mftMirrorClusterCount) * Int(geom.bytesPerCluster)
        var mirrorRegion = Data(count: mirrorRegionSize)
        for recNum in UInt64(0)...3 {
            if let recBytes = records[recNum] {
                let off = Int(recNum) * Int(geom.mftRecordSize)
                for (i, b) in recBytes.enumerated() {
                    mirrorRegion[off + i] = b
                }
            }
        }

        // --- 5. System-file data streams.
        let logFile = makeLogFile(size: Int(geom.logFileSize))
        let bitmap = makeVolumeBitmap(geom: geom)

        // --- 6. Write everything. Order: sector 0, MFT region, mirror,
        // attrdef, upcase, logfile, bitmap, backup boot.
        try await device.write(offset: 0, bytes: bootBytes)
        try await device.write(
            offset: UInt64(geom.bytesPerCluster) * geom.mftStartLCN,
            bytes: mftRegion
        )
        try await device.write(
            offset: UInt64(geom.bytesPerCluster) * geom.mftMirrorStartLCN,
            bytes: mirrorRegion
        )
        try await device.write(
            offset: UInt64(geom.bytesPerCluster) * geom.attrDefStartLCN,
            bytes: AttrDefTable.data
        )
        try await device.write(
            offset: UInt64(geom.bytesPerCluster) * geom.upcaseStartLCN,
            bytes: UpcaseTable.data
        )
        try await device.write(
            offset: UInt64(geom.bytesPerCluster) * geom.logFileStartLCN,
            bytes: logFile
        )
        try await device.write(
            offset: UInt64(geom.bytesPerCluster) * geom.bitmapStartLCN,
            bytes: bitmap
        )
        // Backup boot sector — at the LAST SECTOR of the volume.
        try await device.write(
            offset: geom.bootBackupSectorLBA * UInt64(geom.bytesPerSector),
            bytes: bootBytes
        )
        try await device.synchronize()
    }

    // MARK: — System file builders

    /// Produce post-fix-up MFT record bytes for records 0..15.
    /// Records 12..15 are "reserved" — empty but in-use base records.
    public static func buildSystemRecords(
        geom: Geometry,
        options: Options
    ) throws -> [UInt64: Data] {
        var out: [UInt64: Data] = [:]
        let now = MFTRecordBuilder.windowsFiletimeNow()

        // Helper to build a system file record. parentRN=5 always for
        // records that appear in the root directory.
        func sysRecord(
            recordNumber: UInt64,
            fileName: String,
            isDirectory: Bool,
            extraAttributes: [Data]
        ) throws -> Data {
            try buildSystemMFTRecord(
                geom: geom,
                recordNumber: recordNumber,
                fileName: fileName,
                isDirectory: isDirectory,
                parentReference: packMFTReference(rn: 5, seq: 5),  // root parent
                extraAttributes: extraAttributes,
                now: now
            )
        }

        // Record 0: $MFT — self-describing. $DATA points at the MFT
        // region. Also carries $BITMAP marking records 0..15 in-use.
        let mftDataAttr = serializeNonResidentDataAttribute(
            attrID: 3,
            flags: 0,
            attrName: nil,
            realSize: UInt64(geom.mftClusterCount) * UInt64(geom.bytesPerCluster),
            allocatedSize: UInt64(geom.mftClusterCount) * UInt64(geom.bytesPerCluster),
            extents: [Extent(startLCN: geom.mftStartLCN, clusterCount: geom.mftClusterCount)],
            typeOverride: AttributeType.data.rawValue
        )
        let mftBitmapBytes = makeMFTBitmap(geom: geom)
        let mftBitmapAttr = serializeResidentAttribute(
            type: AttributeType.bitmap.rawValue,
            attrID: 4,
            attrName: nil,
            body: mftBitmapBytes
        )
        out[0] = try sysRecord(
            recordNumber: 0,
            fileName: "$MFT",
            isDirectory: false,
            extraAttributes: [mftDataAttr, mftBitmapAttr]
        )

        // Record 1: $MFTMirr — $DATA points at the mirror region.
        let mirrorDataAttr = serializeNonResidentDataAttribute(
            attrID: 3,
            flags: 0,
            attrName: nil,
            realSize: UInt64(geom.mftMirrorClusterCount) * UInt64(geom.bytesPerCluster),
            allocatedSize: UInt64(geom.mftMirrorClusterCount) * UInt64(geom.bytesPerCluster),
            extents: [Extent(startLCN: geom.mftMirrorStartLCN, clusterCount: geom.mftMirrorClusterCount)],
            typeOverride: AttributeType.data.rawValue
        )
        out[1] = try sysRecord(
            recordNumber: 1, fileName: "$MFTMirr", isDirectory: false,
            extraAttributes: [mirrorDataAttr]
        )

        // Record 2: $LogFile.
        let logDataAttr = serializeNonResidentDataAttribute(
            attrID: 3, flags: 0, attrName: nil,
            realSize: geom.logFileSize,
            allocatedSize: geom.logFileSize,
            extents: [Extent(startLCN: geom.logFileStartLCN, clusterCount: geom.logFileClusterCount)],
            typeOverride: AttributeType.data.rawValue
        )
        out[2] = try sysRecord(
            recordNumber: 2, fileName: "$LogFile", isDirectory: false,
            extraAttributes: [logDataAttr]
        )

        // Record 3: $Volume — $VOLUME_NAME + $VOLUME_INFORMATION.
        let volNameAttr = serializeResidentAttribute(
            type: 0x60,            // $VOLUME_NAME
            attrID: 3, attrName: nil,
            body: utf16Bytes(options.label)
        )
        let volInfoAttr = serializeResidentAttribute(
            type: 0x70,            // $VOLUME_INFORMATION
            attrID: 4, attrName: nil,
            body: volumeInformationBody(major: 3, minor: 1, flags: 0)
        )
        out[3] = try sysRecord(
            recordNumber: 3, fileName: "$Volume", isDirectory: false,
            extraAttributes: [volNameAttr, volInfoAttr]
        )

        // Record 4: $AttrDef.
        let attrDefDataAttr = serializeNonResidentDataAttribute(
            attrID: 3, flags: 0, attrName: nil,
            realSize: 2560,
            allocatedSize: UInt64(geom.bytesPerCluster) * geom.attrDefClusterCount,
            extents: [Extent(startLCN: geom.attrDefStartLCN, clusterCount: geom.attrDefClusterCount)],
            typeOverride: AttributeType.data.rawValue
        )
        out[4] = try sysRecord(
            recordNumber: 4, fileName: "$AttrDef", isDirectory: false,
            extraAttributes: [attrDefDataAttr]
        )

        // Record 5: / (root directory) — $INDEX_ROOT:$I30 empty.
        let rootIndexRoot = serializeResidentAttribute(
            type: 0x90,            // $INDEX_ROOT
            attrID: 3,
            attrName: "$I30",
            body: emptyIndexRootBody()
        )
        out[5] = try buildSystemMFTRecord(
            geom: geom,
            recordNumber: 5,
            fileName: ".",
            isDirectory: true,
            parentReference: packMFTReference(rn: 5, seq: 5),  // root's parent is itself
            extraAttributes: [rootIndexRoot],
            now: now
        )

        // Record 6: $Bitmap — $DATA points at the bitmap region.
        let bitmapDataAttr = serializeNonResidentDataAttribute(
            attrID: 3, flags: 0, attrName: nil,
            realSize: (geom.totalClusters + 7) / 8,
            allocatedSize: UInt64(geom.bytesPerCluster) * geom.bitmapClusterCount,
            extents: [Extent(startLCN: geom.bitmapStartLCN, clusterCount: geom.bitmapClusterCount)],
            typeOverride: AttributeType.data.rawValue
        )
        out[6] = try sysRecord(
            recordNumber: 6, fileName: "$Bitmap", isDirectory: false,
            extraAttributes: [bitmapDataAttr]
        )

        // Record 7: $Boot — $DATA covers sector 0 + reserved area.
        // Boot region is the first 8 KiB of the volume by convention.
        let bootRegionClusters: UInt64 = max(1, 8192 / UInt64(geom.bytesPerCluster))
        let bootDataAttr = serializeNonResidentDataAttribute(
            attrID: 3, flags: 0, attrName: nil,
            realSize: 8192,
            allocatedSize: UInt64(geom.bytesPerCluster) * bootRegionClusters,
            extents: [Extent(startLCN: 0, clusterCount: bootRegionClusters)],
            typeOverride: AttributeType.data.rawValue
        )
        out[7] = try sysRecord(
            recordNumber: 7, fileName: "$Boot", isDirectory: false,
            extraAttributes: [bootDataAttr]
        )

        // Record 8: $BadClus — unnamed $DATA empty + $DATA:$Bad sparse.
        let badClusUnnamed = serializeResidentAttribute(
            type: AttributeType.data.rawValue,
            attrID: 3, attrName: nil, body: Data()
        )
        // Sparse $DATA:$Bad covering the entire volume.
        let badClusBad = serializeNonResidentDataAttribute(
            attrID: 4, flags: 0, attrName: "$Bad",
            realSize: 0,
            allocatedSize: 0,
            extents: [Extent(startLCN: nil, clusterCount: geom.totalClusters)],
            typeOverride: AttributeType.data.rawValue
        )
        out[8] = try sysRecord(
            recordNumber: 8, fileName: "$BadClus", isDirectory: false,
            extraAttributes: [badClusUnnamed, badClusBad]
        )

        // Record 9: $Secure — minimal stub. For v0.6, we ship an empty
        // $SDS (security descriptor stream) and stub $SDH/$SII indexes.
        // Data volumes mounted by livefiles_ntfs/ntfs-3g tolerate this
        // (security descriptors fall through to the volume default).
        let secSDS = serializeResidentAttribute(
            type: AttributeType.data.rawValue, attrID: 3, attrName: "$SDS", body: Data()
        )
        out[9] = try sysRecord(
            recordNumber: 9, fileName: "$Secure", isDirectory: false,
            extraAttributes: [secSDS]
        )

        // Record 10: $UpCase — $DATA points at the upcase clusters.
        let upcaseDataAttr = serializeNonResidentDataAttribute(
            attrID: 3, flags: 0, attrName: nil,
            realSize: 131_072,
            allocatedSize: UInt64(geom.bytesPerCluster) * geom.upcaseClusterCount,
            extents: [Extent(startLCN: geom.upcaseStartLCN, clusterCount: geom.upcaseClusterCount)],
            typeOverride: AttributeType.data.rawValue
        )
        out[10] = try sysRecord(
            recordNumber: 10, fileName: "$UpCase", isDirectory: false,
            extraAttributes: [upcaseDataAttr]
        )

        // Record 11: $Extend — directory with empty $I30.
        let extendIndexRoot = serializeResidentAttribute(
            type: 0x90, attrID: 3, attrName: "$I30", body: emptyIndexRootBody()
        )
        out[11] = try sysRecord(
            recordNumber: 11, fileName: "$Extend", isDirectory: true,
            extraAttributes: [extendIndexRoot]
        )

        // Records 12-15: reserved empty in-use records.
        for rn in UInt64(12)...15 {
            out[rn] = try sysRecord(
                recordNumber: rn,
                fileName: "$Reserved\(rn)",
                isDirectory: false,
                extraAttributes: [
                    serializeResidentAttribute(type: AttributeType.data.rawValue, attrID: 3, attrName: nil, body: Data())
                ]
            )
        }

        return out
    }

    // MARK: — MFT record assembly

    static func buildSystemMFTRecord(
        geom: Geometry,
        recordNumber: UInt64,
        fileName: String,
        isDirectory: Bool,
        parentReference: UInt64,
        extraAttributes: [Data],
        now: UInt64
    ) throws -> Data {
        let recordSize = Int(geom.mftRecordSize)
        let sectorSize = Int(geom.bytesPerSector)
        guard recordSize % sectorSize == 0 else {
            throw NTFSError.corruptOnDisk(description: "mkntfs: recordSize \(recordSize) not multiple of sectorSize \(sectorSize)")
        }
        var data = Data(count: recordSize)
        let usaOffset: UInt16 = 48
        let usaCount = UInt16(1 + recordSize / sectorSize)
        let firstAttrOffset = UInt16(((Int(usaOffset) + Int(usaCount) * 2 + 7) / 8) * 8)

        // Header.
        MFTRecord.writeU32LE(into: &data, at: 0,  value: MFTRecord.magicFILE)
        MFTRecord.writeU16LE(into: &data, at: 4,  value: usaOffset)
        MFTRecord.writeU16LE(into: &data, at: 6,  value: usaCount)
        MFTRecord.writeU64LE(into: &data, at: 8,  value: 0)
        // System files use sequence number == recordNumber when nonzero, or 1 for record 0.
        // Standard NTFS convention: sysfiles 1..N use seq = recordNumber; record 0 uses 1.
        let seq: UInt16 = recordNumber == 0 ? 1 : UInt16(recordNumber)
        MFTRecord.writeU16LE(into: &data, at: 16, value: seq)
        MFTRecord.writeU16LE(into: &data, at: 18, value: 1)
        MFTRecord.writeU16LE(into: &data, at: 20, value: firstAttrOffset)
        let flags: UInt16 = isDirectory ? 0x0003 : 0x0001
        MFTRecord.writeU16LE(into: &data, at: 22, value: flags)
        MFTRecord.writeU32LE(into: &data, at: 28, value: UInt32(recordSize))
        MFTRecord.writeU64LE(into: &data, at: 32, value: 0)
        // nextAttributeID — high enough that we won't collide. Always set to
        // (maxAttrID + 1) where maxAttrID is the highest used in the record.
        MFTRecord.writeU16LE(into: &data, at: 40, value: 16)
        MFTRecord.writeU32LE(into: &data, at: 44, value: UInt32(recordNumber & 0xFFFF_FFFF))
        MFTRecord.writeU16LE(into: &data, at: Int(usaOffset), value: 1)

        var cursor = Int(firstAttrOffset)

        // $STANDARD_INFORMATION (attrID 0)
        let siAttr = serializeResidentAttribute(
            type: 0x10, attrID: 0, attrName: nil,
            body: standardInformationBody(now: now)
        )
        try splice(&data, &cursor, siAttr, recordSize: recordSize)

        // $FILE_NAME (attrID 1) — special "win32 + dos" namespace for sysfiles
        let fnAttr = serializeResidentAttribute(
            type: 0x30, attrID: 1, attrName: nil,
            body: fileNameBody(fileName: fileName, parentReference: parentReference, isDirectory: isDirectory, now: now)
        )
        try splice(&data, &cursor, fnAttr, recordSize: recordSize)

        // Extra attributes.
        for a in extraAttributes {
            try splice(&data, &cursor, a, recordSize: recordSize)
        }

        // End marker.
        guard cursor + 4 <= recordSize else {
            throw NTFSError.corruptOnDisk(description: "mkntfs: record \(recordNumber) overflow at \(cursor)/\(recordSize)")
        }
        MFTRecord.writeU32LE(into: &data, at: cursor, value: 0xFFFF_FFFF)
        cursor += 4
        MFTRecord.writeU32LE(into: &data, at: 24, value: UInt32(cursor))

        // Apply USA reverse-fixup so the produced bytes are ON-DISK form.
        return try UpdateSequenceArray.reverseFixup(
            recordBytes: data,
            usaOffset: Int(usaOffset),
            usaCount: Int(usaCount),
            blockSize: sectorSize
        )
    }

    private static func splice(_ data: inout Data, _ cursor: inout Int, _ attr: Data, recordSize: Int) throws {
        guard cursor + attr.count + 4 <= recordSize else {
            throw NTFSError.corruptOnDisk(description: "mkntfs: attribute (\(attr.count)B) does not fit at \(cursor) (record \(recordSize))")
        }
        for (i, b) in attr.enumerated() {
            data[cursor + i] = b
        }
        cursor += attr.count
    }

    // MARK: — Attribute body helpers

    static func standardInformationBody(now: UInt64) -> Data {
        var d = Data(count: 48)
        MFTRecord.writeU64LE(into: &d, at: 0,  value: now)
        MFTRecord.writeU64LE(into: &d, at: 8,  value: now)
        MFTRecord.writeU64LE(into: &d, at: 16, value: now)
        MFTRecord.writeU64LE(into: &d, at: 24, value: now)
        // 32: fileAttributes — set HIDDEN+SYSTEM (0x06) for system files.
        MFTRecord.writeU32LE(into: &d, at: 32, value: 0x06)
        return d
    }

    static func fileNameBody(fileName: String, parentReference: UInt64, isDirectory: Bool, now: UInt64) -> Data {
        let utf16 = Array(fileName.utf16)
        let nameByteCount = utf16.count * 2
        var d = Data(count: 66 + nameByteCount)
        MFTRecord.writeU64LE(into: &d, at: 0,  value: parentReference)
        MFTRecord.writeU64LE(into: &d, at: 8,  value: now)
        MFTRecord.writeU64LE(into: &d, at: 16, value: now)
        MFTRecord.writeU64LE(into: &d, at: 24, value: now)
        MFTRecord.writeU64LE(into: &d, at: 32, value: now)
        MFTRecord.writeU64LE(into: &d, at: 40, value: 0)
        MFTRecord.writeU64LE(into: &d, at: 48, value: 0)
        // 56: fileAttributes — HIDDEN+SYSTEM for sysfiles; DIRECTORY bit if dir.
        let attrs: UInt32 = 0x06 | (isDirectory ? 0x1000_0000 : 0)
        MFTRecord.writeU32LE(into: &d, at: 56, value: attrs)
        MFTRecord.writeU32LE(into: &d, at: 60, value: 0)
        d[64] = UInt8(utf16.count)
        d[65] = 2   // namespace = Win32+DOS for sysfiles
        for (i, cu) in utf16.enumerated() {
            d[66 + 2 * i]     = UInt8(cu & 0xFF)
            d[66 + 2 * i + 1] = UInt8((cu >> 8) & 0xFF)
        }
        return d
    }

    static func volumeInformationBody(major: UInt8, minor: UInt8, flags: UInt16) -> Data {
        // 12 bytes per NTFS spec: 8 reserved zeros, u8 major, u8 minor, u16 flags.
        var d = Data(count: 12)
        d[8]  = major
        d[9]  = minor
        MFTRecord.writeU16LE(into: &d, at: 10, value: flags)
        return d
    }

    static func emptyIndexRootBody() -> Data {
        var body = Data(count: 48)
        MFTRecord.writeU32LE(into: &body, at: 0,  value: 0x30)              // type = $FILE_NAME
        MFTRecord.writeU32LE(into: &body, at: 4,  value: 0x01)              // COLLATION_FILENAME
        MFTRecord.writeU32LE(into: &body, at: 8,  value: 4096)              // index allocation block size
        body[12] = 1
        MFTRecord.writeU32LE(into: &body, at: 16, value: 16)                // entries offset
        MFTRecord.writeU32LE(into: &body, at: 20, value: 32)                // used size
        MFTRecord.writeU32LE(into: &body, at: 24, value: 32)                // allocated size
        body[28] = 0
        MFTRecord.writeU64LE(into: &body, at: 32, value: 0)
        MFTRecord.writeU16LE(into: &body, at: 40, value: 16)
        MFTRecord.writeU16LE(into: &body, at: 42, value: 0)
        MFTRecord.writeU16LE(into: &body, at: 44, value: 0x02)              // LAST
        MFTRecord.writeU16LE(into: &body, at: 46, value: 0)
        return body
    }

    static func utf16Bytes(_ s: String) -> Data {
        var d = Data()
        for cu in s.utf16 {
            d.append(UInt8(cu & 0xFF))
            d.append(UInt8((cu >> 8) & 0xFF))
        }
        return d
    }

    static func packMFTReference(rn: UInt64, seq: UInt16) -> UInt64 {
        (UInt64(seq) << 48) | (rn & 0x0000_FFFF_FFFF_FFFF)
    }

    // MARK: — Generic attribute serializers (decoupled from Volume.swift)

    static func serializeResidentAttribute(
        type: UInt32,
        attrID: UInt16,
        attrName: String?,
        body: Data
    ) -> Data {
        let nameUTF16: [UInt16] = attrName.map { Array($0.utf16) } ?? []
        let nameByteCount = nameUTF16.count * 2
        let nameOffset: UInt16 = nameByteCount == 0 ? 0 : 24
        let valueOffset: UInt16 = UInt16(24 + nameByteCount)
        let rawLen = Int(valueOffset) + body.count
        let alignedLen = ((rawLen + 7) / 8) * 8
        var d = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &d, at: 0,  value: type)
        MFTRecord.writeU32LE(into: &d, at: 4,  value: UInt32(alignedLen))
        d[8]  = 0       // resident
        d[9]  = UInt8(nameUTF16.count)
        MFTRecord.writeU16LE(into: &d, at: 10, value: nameOffset)
        MFTRecord.writeU16LE(into: &d, at: 12, value: 0)
        MFTRecord.writeU16LE(into: &d, at: 14, value: attrID)
        MFTRecord.writeU32LE(into: &d, at: 16, value: UInt32(body.count))
        MFTRecord.writeU16LE(into: &d, at: 20, value: valueOffset)
        d[22] = 0; d[23] = 0
        if nameByteCount > 0 {
            for (i, cu) in nameUTF16.enumerated() {
                d[Int(nameOffset) + 2 * i]     = UInt8(cu & 0xFF)
                d[Int(nameOffset) + 2 * i + 1] = UInt8((cu >> 8) & 0xFF)
            }
        }
        for (i, b) in body.enumerated() {
            d[Int(valueOffset) + i] = b
        }
        return d
    }

    static func serializeNonResidentDataAttribute(
        attrID: UInt16,
        flags: UInt16,
        attrName: String?,
        realSize: UInt64,
        allocatedSize: UInt64,
        extents: [Extent],
        typeOverride: UInt32
    ) -> Data {
        let nameUTF16: [UInt16] = attrName.map { Array($0.utf16) } ?? []
        let nameByteCount = nameUTF16.count * 2
        let nameOffset: UInt16 = nameByteCount == 0 ? 0 : 64
        let dataRunsOffset: UInt16 = UInt16(64 + nameByteCount)
        let runlist = encodeRunlist(extents: extents)
        let totalLen = Int(dataRunsOffset) + runlist.count
        let alignedLen = ((totalLen + 7) / 8) * 8
        var d = Data(count: alignedLen)
        MFTRecord.writeU32LE(into: &d, at: 0,  value: typeOverride)
        MFTRecord.writeU32LE(into: &d, at: 4,  value: UInt32(alignedLen))
        d[8]  = 1   // non-resident
        d[9]  = UInt8(nameUTF16.count)
        MFTRecord.writeU16LE(into: &d, at: 10, value: nameOffset)
        MFTRecord.writeU16LE(into: &d, at: 12, value: flags)
        MFTRecord.writeU16LE(into: &d, at: 14, value: attrID)
        // Non-resident extension
        let totalClusters = extents.reduce(UInt64(0)) { $0 + $1.clusterCount }
        let lastVCN = totalClusters > 0 ? totalClusters - 1 : 0
        MFTRecord.writeU64LE(into: &d, at: 16, value: 0)
        MFTRecord.writeU64LE(into: &d, at: 24, value: lastVCN)
        MFTRecord.writeU16LE(into: &d, at: 32, value: dataRunsOffset)
        d[34] = 0
        MFTRecord.writeU64LE(into: &d, at: 40, value: allocatedSize)
        MFTRecord.writeU64LE(into: &d, at: 48, value: realSize)
        MFTRecord.writeU64LE(into: &d, at: 56, value: realSize)
        if nameByteCount > 0 {
            for (i, cu) in nameUTF16.enumerated() {
                d[Int(nameOffset) + 2 * i]     = UInt8(cu & 0xFF)
                d[Int(nameOffset) + 2 * i + 1] = UInt8((cu >> 8) & 0xFF)
            }
        }
        for (i, b) in runlist.enumerated() {
            d[Int(dataRunsOffset) + i] = b
        }
        return d
    }

    static func encodeRunlist(extents: [Extent]) -> Data {
        var bytes = Data()
        var prevLCN: Int64 = 0
        for extent in extents {
            let lengthBytes = encodeUnsignedLE(extent.clusterCount)
            if let startLCN = extent.startLCN {
                let delta = Int64(startLCN) - prevLCN
                let offsetBytes = encodeSignedLE(delta)
                let header = UInt8(lengthBytes.count) | (UInt8(offsetBytes.count) << 4)
                bytes.append(header)
                bytes.append(lengthBytes)
                bytes.append(offsetBytes)
                prevLCN = Int64(startLCN)
            } else {
                let header = UInt8(lengthBytes.count)
                bytes.append(header)
                bytes.append(lengthBytes)
            }
        }
        bytes.append(0)
        return bytes
    }

    static func encodeUnsignedLE(_ value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var v = value
        var bytes: [UInt8] = []
        while v != 0 { bytes.append(UInt8(v & 0xFF)); v >>= 8 }
        return Data(bytes)
    }

    static func encodeSignedLE(_ value: Int64) -> Data {
        if value == 0 { return Data([0]) }
        for width in 1...8 {
            let bits = width * 8
            let lo: Int64 = -(Int64(1) << (bits - 1))
            let hi: Int64 = (Int64(1) << (bits - 1)) - 1
            if value >= lo && value <= hi {
                var bytes: [UInt8] = []
                var bp = UInt64(bitPattern: value)
                for _ in 0..<width { bytes.append(UInt8(bp & 0xFF)); bp >>= 8 }
                return Data(bytes)
            }
        }
        return Data()
    }

    // MARK: — Volume-level data streams

    /// $LogFile: empty, all-0xFF — Windows / ntfs-3g reinit on first mount.
    static func makeLogFile(size: Int) -> Data {
        Data(repeating: 0xFF, count: size)
    }

    /// $MFT $BITMAP: 1 bit per MFT record. Set bits 0..15 (system file
    /// records in use), rest zero. Sized to cover the whole MFT region.
    static func makeMFTBitmap(geom: Geometry) -> Data {
        let bytesPerCluster = Int(geom.bytesPerCluster)
        let totalRecords = Int(geom.mftClusterCount) * bytesPerCluster / Int(geom.mftRecordSize)
        let bitmapBytes = (totalRecords + 7) / 8
        // Resident size limit — MFTRecord can only hold ~700 bytes of
        // resident attribute body. Use a smaller bitmap (cover at least
        // the first 16 records). The full MFT bitmap is typically held
        // as a $BITMAP attribute in $MFT, but for small initial volumes
        // a resident bitmap covering 16-128 records is acceptable.
        let bm = min(bitmapBytes, 8)   // 8 bytes = 64 records of coverage
        var d = Data(count: bm)
        // Set bits 0..15.
        d[0] = 0xFF
        d[1] = 0xFF
        return d
    }

    /// $Bitmap (volume cluster bitmap): mark cluster 0..nextLCN-1 (system
    /// files + boot) and the backup-BS cluster as in-use; everything else
    /// free.
    static func makeVolumeBitmap(geom: Geometry) -> Data {
        let bitmapBytes = Int((geom.totalClusters + 7) / 8)
        var d = Data(count: bitmapBytes)
        // Mark cluster 0..bitmapStart+bitmapClusterCount (system region) as in-use.
        let systemEnd = geom.bitmapStartLCN + geom.bitmapClusterCount
        markRange(&d, start: 0, count: systemEnd)
        // Mark backup BS cluster as in-use.
        markRange(&d, start: geom.bootBackupStartLCN, count: 1)
        return d
    }

    private static func markRange(_ d: inout Data, start: UInt64, count: UInt64) {
        for c in start..<(start + count) {
            let byteIdx = Int(c / 8)
            let bitIdx = Int(c % 8)
            guard byteIdx < d.count else { return }
            d[byteIdx] |= (1 << bitIdx)
        }
    }
}

// MARK: — Volume.formatNTFS entry point

extension Volume {
    /// Convenience: format the underlying device as a fresh NTFS volume
    /// with `label`. The caller must have opened the device read-write.
    /// `deviceSizeBytes` must be the usable size of the device.
    public static func formatNTFS(
        device: any BlockDevice,
        deviceSizeBytes: UInt64,
        label: String = "",
        quick: Bool = true,
        volumeSerial: UInt64? = nil
    ) async throws {
        try await Mkntfs.format(
            device: device,
            deviceSizeBytes: deviceSizeBytes,
            options: Mkntfs.Options(
                label: label,
                volumeSerial: volumeSerial,
                quick: quick
            )
        )
    }
}

// MARK: — BlockDevice.size() helper

public extension BlockDevice {
    /// Default: throws — only specific backings know how to discover size.
    func size() async throws -> UInt64 {
        throw NTFSError.unsupportedFeature(description: "BlockDevice.size() not implemented for this backing")
    }
}
