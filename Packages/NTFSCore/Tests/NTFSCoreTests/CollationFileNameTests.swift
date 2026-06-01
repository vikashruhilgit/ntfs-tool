import XCTest
@testable import NTFSCore

/// Regression coverage for **NTFS `COLLATION_FILE_NAME`** ordering
/// (`IndexBuilder.collationFilenameSortsBefore`).
///
/// Why this is critical — the bug it guards against:
/// Directory `$I30` indexes are sorted B-trees that Windows and ntfs-3g
/// **binary-search**. If our index insertion orders entries by anything other
/// than NTFS's exact collation (UTF-16 code units mapped through `$UpCase`),
/// their search misses entries — e.g. `$Secure` becomes unfindable and the
/// whole volume reads as "corrupted / not accessible".
///
/// The original implementation used Swift's `localizedCaseInsensitiveCompare`,
/// whose locale-aware rules reorder punctuation: it sorts `.` (0x2E) **before**
/// `$` (0x24), the opposite of NTFS. Inserting into a real Windows/ntfs-3g
/// root directory then re-sorted the system entries into an order those drivers
/// reject. Verified against the real `ntfs-3g`/`ntfsfix` oracle (see
/// `scripts/ntfs-oracle.sh`).
final class CollationFileNameTests: XCTestCase {

    private func lt(_ a: String, _ b: String) -> Bool {
        IndexBuilder.collationFilenameSortsBefore(a, b)
    }

    /// The exact case that corrupted real volumes: `$` (0x24) sorts before
    /// `.` (0x2E). `localizedCaseInsensitiveCompare` gets this backwards.
    func testDollarSortsBeforeDot() {
        XCTAssertTrue(lt("$AttrDef", "."), "$AttrDef must sort before '.' (NTFS: 0x24 < 0x2E)")
        XCTAssertFalse(lt(".", "$AttrDef"), "'.' must NOT sort before $AttrDef")
    }

    /// A fresh NTFS root directory's exact entry set must collate in this
    /// order (matches `mkntfs`/Windows; verified byte-for-byte against an
    /// ntfs-3g-formatted volume's root $I30).
    func testRootSystemEntryOrderMatchesNTFS() {
        let entries = ["$AttrDef", "$BadClus", "$Bitmap", "$Boot", "$Extend",
                       "$LogFile", "$MFT", "$MFTMirr", "$Secure", "$UpCase",
                       "$Volume", ".", "b"]
        let shuffled = ["b", ".", "$Volume", "$MFT", "$AttrDef", "$Secure",
                        "$Boot", "$Bitmap", "$Extend", "$LogFile", "$MFTMirr",
                        "$BadClus", "$UpCase"]
        let sorted = shuffled.sorted(by: lt)
        XCTAssertEqual(sorted, entries,
            "system entries must collate in NTFS $UpCase order; got \(sorted)")
    }

    /// Case-insensitive: upper/lower compare equal, so order falls to length /
    /// the next differing unit — never producing a strict order between
    /// case-variants of the same name.
    func testCaseInsensitive() {
        XCTAssertFalse(lt("README.TXT", "readme.txt"))
        XCTAssertFalse(lt("readme.txt", "README.TXT"))
        XCTAssertTrue(lt("File", "File2"), "prefix sorts before longer name")
    }

    /// Digits (0x30-0x39) sort before uppercase letters (0x41+), matching
    /// raw UTF-16 order — a common real-world ordering (e.g. "2024" < "Android").
    func testDigitsBeforeLetters() {
        XCTAssertTrue(lt("2024", "Android"))
        XCTAssertTrue(lt("100", "ABC"))
        XCTAssertFalse(lt("Android", "2024"))
    }

    /// `upcase` maps ASCII lowercase to uppercase and leaves punctuation /
    /// digits unchanged (sanity for the table accessor the comparator uses).
    func testUpcaseTableBasics() {
        XCTAssertEqual(UpcaseTable.upcase(UInt16(UnicodeScalar("a").value)),
                       UInt16(UnicodeScalar("A").value))
        XCTAssertEqual(UpcaseTable.upcase(UInt16(UnicodeScalar("Z").value)),
                       UInt16(UnicodeScalar("Z").value))
        XCTAssertEqual(UpcaseTable.upcase(UInt16(UnicodeScalar("$").value)),
                       UInt16(UnicodeScalar("$").value))
        XCTAssertEqual(UpcaseTable.upcase(UInt16(UnicodeScalar(".").value)),
                       UInt16(UnicodeScalar(".").value))
    }
}
