import XCTest
@testable import NTFSCore

/// Name-glob matching used by `ntfsctl find --name`.
final class GlobTests: XCTestCase {

    private func match(_ pattern: String, _ name: String, caseInsensitive: Bool = true) -> Bool {
        Glob.matches(pattern: pattern, name: name, caseInsensitive: caseInsensitive)
    }

    func testLiteralMatching() {
        XCTAssertTrue(match("hello.txt", "hello.txt"))
        XCTAssertFalse(match("hello.txt", "hello.txt2"))
        XCTAssertFalse(match("hello.txt", "ahello.txt"))
        XCTAssertTrue(match("", ""))
        XCTAssertFalse(match("", "x"))
    }

    func testStar() {
        XCTAssertTrue(match("*", "anything"))
        XCTAssertTrue(match("*", ""))
        XCTAssertTrue(match("*.jpg", "IMG_0001.jpg"))
        XCTAssertFalse(match("*.jpg", "IMG_0001.jpeg"))
        XCTAssertTrue(match("IMG_*", "IMG_0001.jpg"))
        XCTAssertTrue(match("IMG_*.jpg", "IMG_0001.jpg"))
        XCTAssertTrue(match("*IMG*", "xxIMGyy"))
        XCTAssertTrue(match("**", "double-star"))
        // Backtracking: the first `*` must give characters back to let the
        // trailing literal match.
        XCTAssertTrue(match("*a*b", "xxaybzzab"))
        XCTAssertFalse(match("*a*b", "xxaybzz"))
    }

    func testQuestionMark() {
        XCTAssertTrue(match("?.txt", "a.txt"))
        XCTAssertFalse(match("?.txt", "ab.txt"))
        XCTAssertFalse(match("?", ""))
        XCTAssertTrue(match("IMG_????.jpg", "IMG_0042.jpg"))
        XCTAssertFalse(match("IMG_????.jpg", "IMG_042.jpg"))
    }

    func testCharacterClasses() {
        XCTAssertTrue(match("[abc].txt", "b.txt"))
        XCTAssertFalse(match("[abc].txt", "d.txt"))
        XCTAssertTrue(match("file[0-9].bin", "file7.bin"))
        XCTAssertFalse(match("file[0-9].bin", "filex.bin"))
        XCTAssertTrue(match("[!0-9]*", "alpha"))
        XCTAssertFalse(match("[!0-9]*", "9lives"))
        XCTAssertTrue(match("[^0-9]*", "alpha"), "^ negation accepted as well as !")
        // A '[' with no closing bracket degrades to a literal.
        XCTAssertTrue(match("[abc", "[abc"))
    }

    func testEscaping() {
        XCTAssertTrue(match("star\\*.txt", "star*.txt"))
        XCTAssertFalse(match("star\\*.txt", "starry.txt"))
        XCTAssertTrue(match("q\\?.txt", "q?.txt"))
        XCTAssertFalse(match("q\\?.txt", "qx.txt"))
    }

    func testCaseFolding() {
        XCTAssertTrue(match("*.JPG", "img.jpg"), "NTFS is case-insensitive; find matches that way by default")
        XCTAssertTrue(match("img*", "IMG_1.JPG"))
        XCTAssertFalse(match("*.JPG", "img.jpg", caseInsensitive: false))
        XCTAssertTrue(match("*.jpg", "img.jpg", caseInsensitive: false))
    }

    func testUnicodeNames() {
        XCTAssertTrue(match("*.txt", "фото.txt"))
        XCTAssertTrue(match("ph?to.txt", "phöto.txt"))
        XCTAssertTrue(match("*😀*", "hi😀there"))
    }
}
