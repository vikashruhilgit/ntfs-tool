import XCTest
@testable import NTFSCore

// Spec-conformance tests for the canonical $UpCase and $AttrDef tables.
// These are HAND-DECODED reference assertions — they intentionally do not
// round-trip through any NTFSCore decoder. The point is to prove our
// shipped binary blobs match the NTFS spec independent of our parser
// (the PR #26 lesson).

final class UpcaseTableTests: XCTestCase {

    func testTableSizeIs128KiB() {
        XCTAssertEqual(UpcaseTable.data.count, 131_072,
                       "$UpCase must be exactly 65,536 UTF-16 codepoints (128 KiB)")
    }

    func testAsciiAToZMapsToUpperCase() {
        for c in 0x61...0x7A {
            let lower = UInt16(c)
            let upper = upcaseEntry(at: Int(lower))
            XCTAssertEqual(upper, lower - 0x20,
                           "ASCII codepoint 0x\(String(format: "%04X", lower)) should map to 0x\(String(format: "%04X", lower - 0x20))")
        }
    }

    func testAsciiAToZIsIdempotent() {
        // Already-uppercase ASCII A-Z must map to itself.
        for c in 0x41...0x5A {
            let upper = upcaseEntry(at: c)
            XCTAssertEqual(upper, UInt16(c),
                           "ASCII uppercase 0x\(String(format: "%04X", c)) must be a fixed point")
        }
    }

    func testAsciiNonAlphaIsIdentity() {
        // Digits, punctuation, space, etc. must be fixed points.
        for c in [0x20, 0x30, 0x39, 0x40, 0x5B, 0x60, 0x7B, 0x7F] {
            XCTAssertEqual(upcaseEntry(at: c), UInt16(c),
                           "Non-alphabetic ASCII 0x\(String(format: "%04X", c)) must be a fixed point")
        }
    }

    func testLatin1LowercaseMaps() {
        // Latin-1 supplement: ä→Ä, à→À, ñ→Ñ, ö→Ö, ÿ→Ÿ.
        let pairs: [(UInt16, UInt16)] = [
            (0x00E4, 0x00C4),  // ä → Ä
            (0x00E0, 0x00C0),  // à → À
            (0x00F1, 0x00D1),  // ñ → Ñ
            (0x00F6, 0x00D6),  // ö → Ö
            (0x00FF, 0x0178),  // ÿ → Ÿ
        ]
        for (lower, expected) in pairs {
            XCTAssertEqual(upcaseEntry(at: Int(lower)), expected,
                           "Codepoint 0x\(String(format: "%04X", lower)) should fold to 0x\(String(format: "%04X", expected))")
        }
    }

    func testGreekSigmaFolds() {
        // σ (U+03C3) → Σ (U+03A3).
        XCTAssertEqual(upcaseEntry(at: 0x03C3), 0x03A3, "σ → Σ")
    }

    func testGermanSharpSIsIdentity() {
        // ß (U+00DF) uppercases to "SS" (multi-codepoint expansion),
        // which the NTFS table represents as a fixed-point (no fold).
        XCTAssertEqual(upcaseEntry(at: 0x00DF), 0x00DF, "ß must be a fixed point (multi-codepoint expansion ignored)")
    }

    func testSurrogateHalvesAreIdentity() {
        // Surrogates [0xD800, 0xDFFF] must map to themselves — they're not
        // standalone characters and have no defined case mapping.
        for c in stride(from: 0xD800, through: 0xDFFF, by: 0x100) {
            XCTAssertEqual(upcaseEntry(at: c), UInt16(c),
                           "Surrogate 0x\(String(format: "%04X", c)) must be a fixed point")
        }
    }

    /// Read the LE u16 at codepoint index `cp` from `UpcaseTable.data`.
    /// Intentionally does NOT call any NTFSCore decoder.
    private func upcaseEntry(at cp: Int) -> UInt16 {
        precondition(cp >= 0 && cp < 65_536)
        let off = cp * 2
        let lo = UInt16(UpcaseTable.data[off])
        let hi = UInt16(UpcaseTable.data[off + 1])
        return (hi << 8) | lo
    }
}

final class AttrDefTableTests: XCTestCase {

    func testTableSizeIs2560Bytes() {
        XCTAssertEqual(AttrDefTable.data.count, 2_560,
                       "$AttrDef must be exactly 16 × 160 = 2,560 bytes")
        XCTAssertEqual(AttrDefTable.entries.count, 16,
                       "Canonical NTFS 3.1 $AttrDef has 16 entries")
    }

    /// Hand-decoded reference: assert each entry's name + type + min/max
    /// bytes appear at the correct offset, byte by byte.
    func testStandardInformationEntry() {
        // Entry 0 (offset 0): "$STANDARD_INFORMATION", type 0x10, min 48, max 72
        XCTAssertEqual(readName(entryIndex: 0), "$STANDARD_INFORMATION")
        XCTAssertEqual(readU32(entryIndex: 0, fieldOffset: 128), 0x10)
        XCTAssertEqual(readU64(entryIndex: 0, fieldOffset: 144), 48)
        XCTAssertEqual(readU64(entryIndex: 0, fieldOffset: 152), 72)
        XCTAssertEqual(readU32(entryIndex: 0, fieldOffset: 140), 0x40, "flags")
    }

    func testFileNameEntry() {
        // Entry 2 (offset 320): "$FILE_NAME", type 0x30, coll 1, min 68, max 578
        XCTAssertEqual(readName(entryIndex: 2), "$FILE_NAME")
        XCTAssertEqual(readU32(entryIndex: 2, fieldOffset: 128), 0x30)
        XCTAssertEqual(readU32(entryIndex: 2, fieldOffset: 136), 1, "collationRule = FILE_NAME")
        XCTAssertEqual(readU64(entryIndex: 2, fieldOffset: 144), 68)
        XCTAssertEqual(readU64(entryIndex: 2, fieldOffset: 152), 578)
    }

    func testDataEntry() {
        // Entry 7 (offset 1120): "$DATA", type 0x80, flags 0, maxSize unlimited
        XCTAssertEqual(readName(entryIndex: 7), "$DATA")
        XCTAssertEqual(readU32(entryIndex: 7, fieldOffset: 128), 0x80)
        XCTAssertEqual(readU32(entryIndex: 7, fieldOffset: 140), 0, "no flags on $DATA")
        XCTAssertEqual(readU64(entryIndex: 7, fieldOffset: 152), 0xFFFF_FFFF_FFFF_FFFF)
    }

    func testIndexRootEntry() {
        XCTAssertEqual(readName(entryIndex: 8), "$INDEX_ROOT")
        XCTAssertEqual(readU32(entryIndex: 8, fieldOffset: 128), 0x90)
    }

    func testIndexAllocationEntry() {
        XCTAssertEqual(readName(entryIndex: 9), "$INDEX_ALLOCATION")
        XCTAssertEqual(readU32(entryIndex: 9, fieldOffset: 128), 0xA0)
    }

    func testBitmapEntry() {
        XCTAssertEqual(readName(entryIndex: 10), "$BITMAP")
        XCTAssertEqual(readU32(entryIndex: 10, fieldOffset: 128), 0xB0)
    }

    func testLoggedUtilityStreamEntry() {
        // Entry 15 — last entry, type 0x100
        XCTAssertEqual(readName(entryIndex: 15), "$LOGGED_UTILITY_STREAM")
        XCTAssertEqual(readU32(entryIndex: 15, fieldOffset: 128), 0x100)
        XCTAssertEqual(readU64(entryIndex: 15, fieldOffset: 152), 65536)
    }

    func testAllTypeCodesPresent() {
        let typeAtIndex: [Int: UInt32] = [
            0: 0x10, 1: 0x20, 2: 0x30, 3: 0x40, 4: 0x50, 5: 0x60, 6: 0x70,
            7: 0x80, 8: 0x90, 9: 0xA0, 10: 0xB0, 11: 0xC0, 12: 0xD0, 13: 0xE0,
            14: 0xF0, 15: 0x100,
        ]
        for (idx, type) in typeAtIndex {
            XCTAssertEqual(readU32(entryIndex: idx, fieldOffset: 128), type,
                           "Entry \(idx) type code")
        }
    }

    // MARK: — hand decoders

    private func readName(entryIndex: Int) -> String {
        let base = entryIndex * 160
        var codeUnits: [UInt16] = []
        for j in 0..<64 {
            let lo = UInt16(AttrDefTable.data[base + 2 * j])
            let hi = UInt16(AttrDefTable.data[base + 2 * j + 1])
            let cu = (hi << 8) | lo
            if cu == 0 { break }
            codeUnits.append(cu)
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private func readU32(entryIndex: Int, fieldOffset: Int) -> UInt32 {
        let off = entryIndex * 160 + fieldOffset
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(AttrDefTable.data[off + i]) << (8 * i) }
        return v
    }

    private func readU64(entryIndex: Int, fieldOffset: Int) -> UInt64 {
        let off = entryIndex * 160 + fieldOffset
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(AttrDefTable.data[off + i]) << (8 * i) }
        return v
    }
}
