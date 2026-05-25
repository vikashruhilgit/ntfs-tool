import XCTest
@testable import NTFSCore

/// Independent spec-conformance regression guards for MULTI-EXTENT unnamed
/// `$DATA`.
///
/// Origin (negative result): a v0.5 portability blocker suspected that files
/// whose unnamed `$DATA` spans MULTIPLE extents — readable byte-exact by OUR
/// reader — were malformed for SPEC-STRICT readers (Apple's macOS native
/// driver, ntfs-3g, Windows). The suspected multi-extent runlist ENCODING bug
/// was DISPROVEN here: the REAL serializer/encoder (`encodeRunlist`,
/// `serializeNonResidentDataAttribute`, reached via the `_*ForTesting` seams)
/// emits bytes that an INDEPENDENT, hand-written, spec-strict decoder recovers
/// exactly across all signed-width boundaries (incl. 5-byte deltas), with
/// header coverage fields (lastVCN / allocatedSize / initializedSize)
/// consistent with the runlist and an end-to-end physical read that
/// reassembles the payload byte-exact.
///
/// These assertions are written against the INDEPENDENT decoder, never "our
/// own decoder round-trips" (which would mask such a bug). They close the
/// PR #13 gap: multi-extent `$DATA` had never been independently cross-read
/// before. They are kept as PERMANENT regression guards — the real hardware
/// I/O-error remains OPEN and is not reproducible in this `.img`-fixture
/// toolchain (see `docs/STATUS.md`). NOTE: this is a documented negative
/// result, NOT a bug fix; none of these tests is expected to fail on `main`.
final class MultiExtentDataTests: XCTestCase {

    // MARK: - Independent, spec-strict runlist decoder

    /// A decoded run: nil LCN == sparse.
    private struct SpecRun: Equatable { let lcn: Int64?; let length: UInt64 }

    /// Decode an NTFS runlist STRICTLY per the on-disk format, independent of
    /// `DataRun.decode`. Throws on the FIRST byte-level spec violation so the
    /// test can pin the exact divergence.
    ///   - header byte: low nibble = length width L (bytes), high nibble =
    ///     offset width V (bytes).
    ///   - L bytes: UNSIGNED little-endian cluster count.
    ///   - V bytes: SIGNED little-endian delta from previous run's LCN. First
    ///     run's delta is absolute (relative to 0). V==0 => sparse.
    ///   - header 0x00 terminates.
    /// `boundary` is the number of bytes the strict reader is ALLOWED to read
    /// (the attribute-recorded runlist length). Reading past it is a spec
    /// violation (a strict reader stops at the recorded length).
    private enum SpecDecodeError: Error, CustomStringConvertible {
        case truncated(at: Int, need: Int, have: Int)
        case missingTerminator
        case negativeLCN(Int64)
        var description: String {
            switch self {
            case let .truncated(at, need, have):
                return "runlist truncated at byte \(at): need \(need) more bytes, only \(have) available within recorded length"
            case .missingTerminator:
                return "runlist not terminated by 0x00 within recorded length"
            case let .negativeLCN(v):
                return "signed delta produced negative LCN \(v)"
            }
        }
    }

    private func specDecode(_ data: [UInt8], boundary: Int? = nil) throws -> [SpecRun] {
        let limit = boundary ?? data.count
        var runs: [SpecRun] = []
        var cursor = 0
        var prev: Int64 = 0
        while true {
            guard cursor < limit else { throw SpecDecodeError.missingTerminator }
            let header = data[cursor]; cursor += 1
            if header == 0 { return runs }            // proper terminator
            let L = Int(header & 0x0F)
            let V = Int((header & 0xF0) >> 4)
            guard cursor + L + V <= limit else {
                throw SpecDecodeError.truncated(at: cursor, need: L + V, have: limit - cursor)
            }
            // length: unsigned LE
            var length: UInt64 = 0
            for i in 0..<L { length |= UInt64(data[cursor + i]) << (8 * i) }
            cursor += L
            if V == 0 {
                runs.append(SpecRun(lcn: nil, length: length))
                continue
            }
            // offset: SIGNED LE, sign-extended
            var u: UInt64 = 0
            for i in 0..<V { u |= UInt64(data[cursor + i]) << (8 * i) }
            if V < 8, (u & (UInt64(1) << (8 * V - 1))) != 0 {
                u |= UInt64.max << (8 * V)
            }
            let delta = Int64(bitPattern: u)
            cursor += V
            let lcn = prev &+ delta
            guard lcn >= 0 else { throw SpecDecodeError.negativeLCN(lcn) }
            runs.append(SpecRun(lcn: lcn, length: length))
            prev = lcn
        }
    }

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    private func hex(_ d: [UInt8]) -> String { hex(Data(d)) }

    // MARK: - Direct encoder sweep (no fixture needed)

    /// Drive the REAL `encodeRunlist` over a sweep of extent configurations,
    /// then assert the INDEPENDENT spec decoder recovers the EXACT input
    /// (LCNs + lengths). The first config that diverges pins the encoder bug.
    func testEncodeRunlistSpecConformanceSweep() async throws {
        // Build a Volume from the fixture purely to reach the instance method
        // seam. (encodeRunlist does not touch the device.)
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Each config is a list of (startLCN, clusterCount) extents, >= 3 runs.
        // Coverage: ascending small, ascending multi-cluster, backward delta,
        // and — crucially — LARGE LCNs whose deltas need 4 / 5 bytes and land
        // JUST ABOVE the signed-width boundaries (0x80, 0x8000, 0x800000,
        // 0x80000000) where minimal-width sign handling is fragile.
        let configs: [(String, [Extent])] = [
            ("ascending-single", [
                Extent(startLCN: 4, clusterCount: 1),
                Extent(startLCN: 6, clusterCount: 1),
                Extent(startLCN: 8, clusterCount: 1),
            ]),
            ("ascending-multi", [
                Extent(startLCN: 100, clusterCount: 50),
                Extent(startLCN: 200, clusterCount: 187),
                Extent(startLCN: 500, clusterCount: 94),
            ]),
            ("backward-delta", [
                Extent(startLCN: 326, clusterCount: 125),
                Extent(startLCN: 784, clusterCount: 187),
                Extent(startLCN: 23,  clusterCount: 94),
            ]),
            // 4TB-class volume: cluster size 4096 => ~1.07e9 clusters. Deltas
            // and absolute LCNs here need 4 bytes; values straddle 0x7FFFFFFF.
            ("large-3byte-boundary", [
                Extent(startLCN: 0x7FFFFF, clusterCount: 10),   // 3-byte positive max
                Extent(startLCN: 0x800001, clusterCount: 10),   // delta crosses 0x800000
                Extent(startLCN: 0x900000, clusterCount: 10),
            ]),
            ("large-4byte", [
                Extent(startLCN: 0x01000000, clusterCount: 64),  // 16,777,216
                Extent(startLCN: 0x02000000, clusterCount: 64),
                Extent(startLCN: 0x10000000, clusterCount: 64),  // 268M (4-byte)
            ]),
            ("large-4TB-class", [
                Extent(startLCN: 0x20000000, clusterCount: 200),  // ~537M cluster
                Extent(startLCN: 0x30000000, clusterCount: 200),
                Extent(startLCN: 0x3FFFFFFF, clusterCount: 200),  // ~1.07e9, near 4TB top
            ]),
            // delta that crosses the 4-byte signed boundary 0x7FFFFFFF.
            ("large-5byte-delta", [
                Extent(startLCN: 0x10000000, clusterCount: 8),
                Extent(startLCN: 0x90000001, clusterCount: 8),   // delta = 0x80000001 > Int32 max
                Extent(startLCN: 0x90000010, clusterCount: 8),
            ]),
        ]

        var failures: [String] = []
        for (name, extents) in configs {
            let encoded = await volume._encodeRunlistForTesting(extents)
            let bytes = [UInt8](encoded)
            do {
                let decoded = try specDecode(bytes)
                // Compare against the EXACT input.
                let expected = extents.map { SpecRun(lcn: $0.startLCN.map(Int64.init), length: $0.clusterCount) }
                if decoded != expected {
                    failures.append("""
                    [\(name)] SPEC-DECODE MISMATCH
                      encoded bytes : \(hex(encoded))
                      spec-decoded  : \(decoded.map { ($0.lcn ?? -1, $0.length) })
                      expected      : \(expected.map { ($0.lcn ?? -1, $0.length) })
                    """)
                }
            } catch {
                failures.append("""
                [\(name)] SPEC-DECODE THREW: \(error)
                  encoded bytes : \(hex(encoded))
                  expected      : \(extents.map { ($0.startLCN ?? 0, $0.clusterCount) })
                """)
            }
        }

        if !failures.isEmpty {
            XCTFail("encodeRunlist is NOT spec-conformant for:\n\n" + failures.joined(separator: "\n\n"))
        }
    }

    /// Focused regression guard (brief AC-6): a >=3-extent unnamed `$DATA`
    /// that includes BOTH a large absolute first LCN and a backward LCN delta —
    /// the two cases most likely to break minimal-width signed-offset encoding —
    /// must serialize to a runlist + header the INDEPENDENT spec decoder accepts
    /// exactly. Asserts the serialized runlist bytes (via `specDecode`) AND the
    /// header coverage fields (lastVCN, allocatedSize, initializedSize) against
    /// the independent reference, never our own decoder.
    func testMultiExtentDataAttributeIsSpecConformant() async throws {
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let clusterBytes = UInt64(volume.bytesPerCluster)

        // 3 extents: large absolute first LCN (4-byte offset), a forward jump,
        // then a BACKWARD delta (extent[2].LCN < extent[1].LCN). realSize a bit
        // under the allocation so there is a partial tail.
        let extents = [
            Extent(startLCN: 0x10000000, clusterCount: 40),   // large absolute first LCN
            Extent(startLCN: 0x20000005, clusterCount: 40),   // forward jump
            Extent(startLCN: 0x08000000, clusterCount: 40),   // backward delta
        ]
        let totalClusters = extents.reduce(0) { $0 + $1.clusterCount }
        let allocatedSize = totalClusters * clusterBytes
        let realSize = allocatedSize - 321

        let attr = await volume._serializeNonResidentDataForTesting(
            realSize: realSize,
            allocatedSize: allocatedSize,
            extents: extents
        )

        func u16(_ o: Int) -> UInt16 { UInt16(attr[attr.startIndex + o]) | (UInt16(attr[attr.startIndex + o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(attr[attr.startIndex + o + i]) << (8 * i) }; return v
        }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(attr[attr.startIndex + o + i]) << (8 * i) }; return v
        }

        let attrLen = Int(u32(4))
        let nonResident = attr[attr.startIndex + 8]
        let lastVCN = u64(24)
        let dataRunsOffset = Int(u16(32))
        let allocField = u64(40)
        let realField = u64(48)
        let initField = u64(56)

        XCTAssertEqual(nonResident, 1, "multi-extent $DATA must be non-resident")

        // Runlist must decode + terminate within the recorded attribute length.
        let runBytes = [UInt8](attr[(attr.startIndex + dataRunsOffset)..<(attr.startIndex + attrLen)])
        let decoded = try specDecode(runBytes, boundary: runBytes.count)
        let expected = extents.map { SpecRun(lcn: $0.startLCN.map(Int64.init), length: $0.clusterCount) }
        XCTAssertEqual(
            decoded, expected,
            "independent spec decode of serialized runlist must match the 3 extents exactly.\n  bytes: \(hex(runBytes))"
        )
        XCTAssertGreaterThanOrEqual(decoded.count, 3, "must exercise a >=3-extent runlist")

        // Header coverage fields must agree with the runlist.
        let coveredClusters = decoded.reduce(UInt64(0)) { $0 + $1.length }
        XCTAssertEqual(lastVCN, coveredClusters - 1, "lastVCN must equal covered clusters - 1")
        XCTAssertEqual(allocField, coveredClusters * clusterBytes, "allocatedSize must equal covered clusters * clusterBytes")
        XCTAssertEqual(realField, realSize, "realSize field must equal payload size")
        XCTAssertEqual(initField, realSize, "initializedSize field must equal payload size")
    }

    /// Assert the non-resident $DATA HEADER coverage fields (lastVCN,
    /// allocatedSize, initializedSize) plus the runlist-within-recorded-length
    /// are all spec-conformant for a MULTI-extent file, decoded independently.
    /// A strict reader trusts lastVCN/allocatedSize; if they don't match the
    /// runlist's actual coverage it reads VCNs the runlist can't map -> I/O.
    func testNonResidentHeaderAndRunlistSpecConformance() async throws {
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let clusterBytes = UInt64(volume.bytesPerCluster)

        // 5-extent, large-LCN file (4TB-class). realSize = a bit under the
        // last cluster so there is a partial tail.
        let extents = [
            Extent(startLCN: 0x10000000, clusterCount: 100),
            Extent(startLCN: 0x20000005, clusterCount: 100),
            Extent(startLCN: 0x08000000, clusterCount: 100),   // backward delta
            Extent(startLCN: 0x30000000, clusterCount: 100),
            Extent(startLCN: 0x3FFFFF00, clusterCount: 100),   // near 4TB top
        ]
        let totalClusters = extents.reduce(0) { $0 + $1.clusterCount }
        let allocatedSize = totalClusters * clusterBytes
        let realSize = allocatedSize - 1234   // partial tail in last cluster

        let attr = await volume._serializeNonResidentDataForTesting(
            realSize: realSize,
            allocatedSize: allocatedSize,
            extents: extents
        )

        // Parse the serialized attribute header fields ourselves.
        func u16(_ o: Int) -> UInt16 { UInt16(attr[attr.startIndex + o]) | (UInt16(attr[attr.startIndex + o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(attr[attr.startIndex + o + i]) << (8 * i) }; return v
        }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(attr[attr.startIndex + o + i]) << (8 * i) }; return v
        }

        let attrLen = Int(u32(4))
        let nonResident = attr[attr.startIndex + 8]
        let lastVCN = u64(24)
        let dataRunsOffset = Int(u16(32))
        let allocField = u64(40)
        let realField = u64(48)
        let initField = u64(56)

        XCTAssertEqual(nonResident, 1, "must be non-resident")

        // --- Independent runlist decode WITHIN the recorded attribute length ---
        // A strict reader reads runs from dataRunsOffset up to attrLen and
        // requires a terminator inside that window.
        let runBytes = [UInt8](attr[(attr.startIndex + dataRunsOffset)..<(attr.startIndex + attrLen)])

        var diagnostics: [String] = []

        // H-C: full runlist + terminator must fit within recorded attr length.
        let decodedRuns: [SpecRun]
        do {
            decodedRuns = try specDecode(runBytes, boundary: runBytes.count)
        } catch {
            diagnostics.append("H-C runlist does not fully fit / terminate within recorded length \(attrLen): \(error)\n  runlist window bytes: \(hex(runBytes))")
            XCTFail(diagnostics.joined(separator: "\n"))
            return
        }

        let expectedRuns = extents.map { SpecRun(lcn: $0.startLCN.map(Int64.init), length: $0.clusterCount) }
        if decodedRuns != expectedRuns {
            diagnostics.append("""
            H-A/H-C runlist spec-decode mismatch:
              runlist bytes : \(hex(runBytes))
              spec-decoded  : \(decodedRuns.map { ($0.lcn ?? -1, $0.length) })
              expected      : \(expectedRuns.map { ($0.lcn ?? -1, $0.length) })
            """)
        }

        // H-B: header coverage fields must match the runlist's true coverage.
        let coveredClusters = decodedRuns.reduce(UInt64(0)) { $0 + $1.length }
        let expectedLastVCN = coveredClusters - 1
        if lastVCN != expectedLastVCN {
            diagnostics.append("H-B lastVCN=\(lastVCN) but runlist covers \(coveredClusters) clusters (expected lastVCN=\(expectedLastVCN))")
        }
        if allocField != coveredClusters * clusterBytes {
            diagnostics.append("H-B allocatedSize=\(allocField) but runlist covers \(coveredClusters) clusters * \(clusterBytes) = \(coveredClusters * clusterBytes)")
        }
        if realField != realSize {
            diagnostics.append("H-B realSize field=\(realField) expected \(realSize)")
        }
        if initField != realSize {
            diagnostics.append("H-B initializedSize field=\(initField) expected \(realSize)")
        }

        if !diagnostics.isEmpty {
            XCTFail("Non-resident multi-extent $DATA is NOT spec-conformant:\n" + diagnostics.joined(separator: "\n"))
        }
    }

    /// END-TO-END H-E (placement vs runlist ordering): write a >=3-extent file
    /// via the REAL `writeFile` fragmented path, then re-open the image RAW,
    /// decode the on-disk runlist INDEPENDENTLY, read each physical cluster
    /// straight off the device in runlist order, and compare to the original
    /// payload BYTE-EXACT. This bypasses `Volume.readFile` entirely, so it
    /// catches a placement/order/coverage divergence that our own reader hides.
    func testEndToEndFragmentedSpecPlacement() async throws {
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let cs = UInt64(volume.bytesPerCluster)
        let bps = Int(volume.boot.bytesPerSector)

        let rn = try await volume.createFile(named: "e2e-frag.bin", inDirectory: 5)

        // Carve a swiss-cheese bitmap: consume all free as singles, free every
        // other one. Forces writeFile down the multi-extent fragmented path.
        var singles: [Extent] = []
        while let e = try? await volume.allocateClusters(1) { singles.append(e); if singles.count > 8192 { break } }
        guard singles.count >= 16 else { throw XCTSkip("not enough free clusters to fragment") }
        for (i, e) in singles.enumerated() where i % 2 == 0 { try await volume.freeClusters(e) }

        // ~8 clusters with a partial tail so realSize < allocatedSize.
        let clusters: UInt64 = 8
        let total = Int(clusters * cs) - 777
        var payload = Data(count: total)
        for i in 0..<total { payload[i] = UInt8((UInt64(i) &* 131 &+ 17) & 0xFF) }
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(total)) {
            if cursor >= total { return Data() }
            let take = min(1 << 16, total - cursor)
            let c = payload.subdata(in: cursor..<(cursor + take)); cursor += take; return c
        }

        // --- Re-open RAW and locate the unnamed non-resident $DATA attribute by
        //     hand, then INDEPENDENTLY decode the runlist + header fields. ---
        let raw = try FileHandleBlockDevice(openingFileAt: path)
        // We still need the MFT byte offset; read it via a fresh Volume but use
        // ONLY its record bytes (not its $DATA reader).
        let rv = try await Volume(device: raw)
        let mft = await rv.mft()
        let rec = try await mft.record(at: rn)
        let rb = rec.bytes

        // Walk attributes for unnamed non-resident $DATA.
        var c = Int(rec.firstAttributeOffset)
        let used = Int(rec.usedSize)
        var ds = -1
        while c + 8 <= used {
            let t = try rb.readU32LE(at: c); if t == 0xFFFFFFFF { break }
            let len = Int(try rb.readU32LE(at: c + 4))
            let nr = try rb.readU8(at: c + 8); let nl = try rb.readU8(at: c + 9)
            if t == AttributeType.data.rawValue && nr == 1 && nl == 0 { ds = c; break }
            if len <= 0 { break }
            c += len
        }
        guard ds >= 0 else {
            throw XCTSkip("$DATA stayed resident or migrated (no unnamed non-resident $DATA in base) — fragmented path not exercised")
        }

        let attrLen = Int(try rb.readU32LE(at: ds + 4))
        let lastVCN = try rb.readU64LE(at: ds + 24)
        let runsOff = Int(try rb.readU16LE(at: ds + 32))
        let allocField = try rb.readU64LE(at: ds + 40)
        let realField = try rb.readU64LE(at: ds + 48)
        let runBytes = [UInt8](rb[(rb.startIndex + ds + runsOff)..<(rb.startIndex + ds + attrLen)])

        let runs = try specDecode(runBytes, boundary: runBytes.count)
        let coveredClusters = runs.reduce(UInt64(0)) { $0 + $1.length }

        guard runs.count >= 3 else {
            throw XCTSkip("writeFile produced only \(runs.count) extents; need >=3 to exercise multi-extent")
        }

        // Header coverage must agree with the runlist.
        XCTAssertEqual(lastVCN, coveredClusters - 1, "lastVCN must equal covered clusters - 1")
        XCTAssertEqual(allocField, coveredClusters * cs, "allocatedSize must equal covered clusters * clusterBytes")
        XCTAssertEqual(realField, UInt64(total), "realSize must equal payload size")

        // --- Read physical clusters DIRECTLY off the device, in runlist order,
        //     and reassemble realSize bytes. Pure independent reader. ---
        var assembled = Data(); assembled.reserveCapacity(total)
        var remaining = total
        for r in runs where remaining > 0 {
            let take = Int(min(r.length * cs, UInt64(remaining)))
            if let lcn = r.lcn {
                let chunk = try await raw.read(offset: UInt64(lcn) * cs, length: take)
                assembled.append(chunk)
            } else {
                assembled.append(Data(repeating: 0, count: take))
            }
            remaining -= take
        }

        XCTAssertEqual(assembled.count, total, "independent reassembly length")
        XCTAssertEqual(assembled, payload, "INDEPENDENT spec-order physical read must match payload byte-exact")
        _ = bps
    }

    /// Pure byte-dump of the REAL encoder across the signed-width boundaries so
    /// the diagnosis can quote exact bytes. Always passes; prints evidence.
    func testDumpEncoderBoundaryBytes() async throws {
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Single-run configs to isolate the FIRST (absolute) offset encoding at
        // each boundary, then a two-run config to isolate DELTA encoding.
        let absConfigs: [(String, UInt64)] = [
            ("abs 0x7F", 0x7F), ("abs 0x80", 0x80),
            ("abs 0x7FFF", 0x7FFF), ("abs 0x8000", 0x8000),
            ("abs 0x7FFFFF", 0x7FFFFF), ("abs 0x800000", 0x800000),
            ("abs 0x7FFFFFFF", 0x7FFFFFFF), ("abs 0x80000000", 0x80000000),
            ("abs 0x3FFFFFFF (4TB-class)", 0x3FFFFFFF),
        ]
        for (name, lcn) in absConfigs {
            let enc = await volume._encodeRunlistForTesting([Extent(startLCN: lcn, clusterCount: 1)])
            let decoded = try? specDecode([UInt8](enc))
            print("ABS \(name): bytes=\(hex(enc))  spec-decode=\(decoded?.map { ($0.lcn ?? -1, $0.length) } ?? [])")
        }
        // length-field high-bit cases.
        let lenConfigs: [(String, UInt64)] = [
            ("len 0x7F", 0x7F), ("len 0x80", 0x80),
            ("len 0xFF", 0xFF), ("len 0x100", 0x100),
            ("len 0x8000", 0x8000),
        ]
        for (name, len) in lenConfigs {
            let enc = await volume._encodeRunlistForTesting([Extent(startLCN: 5, clusterCount: len)])
            let decoded = try? specDecode([UInt8](enc))
            print("LEN \(name): bytes=\(hex(enc))  spec-decode=\(decoded?.map { ($0.lcn ?? -1, $0.length) } ?? [])")
        }
        // positive delta crossing each boundary (run2 LCN = run1 + boundary).
        let deltaConfigs: [(String, UInt64, UInt64)] = [
            ("delta +0x7FFF", 1000, 1000 + 0x7FFF),
            ("delta +0x8000", 1000, 1000 + 0x8000),
            ("delta +0x7FFFFF", 1000, 1000 + 0x7FFFFF),
            ("delta +0x800000", 1000, 1000 + 0x800000),
            ("delta +0x7FFFFFFF", 1, 1 + 0x7FFFFFFF),
            ("delta +0x80000000", 1, 1 + 0x80000000),
        ]
        for (name, a, b) in deltaConfigs {
            let enc = await volume._encodeRunlistForTesting([
                Extent(startLCN: a, clusterCount: 1),
                Extent(startLCN: b, clusterCount: 1),
            ])
            let decoded = try? specDecode([UInt8](enc))
            print("DELTA \(name): bytes=\(hex(enc))  spec-decode=\(decoded?.map { ($0.lcn ?? -1, $0.length) } ?? [])")
        }
    }
}
