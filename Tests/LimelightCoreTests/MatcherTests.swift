import XCTest
@testable import LimelightCore

final class MatcherTests: XCTestCase {
    func s(_ q: String, _ name: String, fuzzy: Bool = false) -> Int {
        Matcher.score(Fold.bytes(q), in: Fold.bytes(name), original: Array(name.utf8), fuzzy: fuzzy)
    }

    func testBandsRankInOrder() {
        XCTAssertGreaterThan(s("safari", "Safari"), s("saf", "Safari"))
        XCTAssertGreaterThan(s("saf", "Safari"), s("saf", "Safari Technology Preview"))
        XCTAssertGreaterThan(s("saf", "Safari Technology Preview"), s("tech", "Safari Technology Preview"))
        XCTAssertGreaterThan(s("tech", "Safari Technology Preview"), s("vsc", "Visual Studio Code"))
        XCTAssertGreaterThan(s("vsc", "Visual Studio Code"), s("ari", "Safari"))
        XCTAssertEqual(s("notes", "Notes.txt"), Matcher.stemExact)
    }

    func testWordStartsIncludeCamelCaseAndDigits() {
        XCTAssertGreaterThanOrEqual(s("notes", "ProjectNotes.md"), Matcher.wordPrefix)
        XCTAssertGreaterThanOrEqual(s("pn", "ProjectNotes.md"), Matcher.initials)
        XCTAssertGreaterThanOrEqual(s("2024", "taxes2024.pdf"), Matcher.wordPrefix)
    }

    func testAccentsAndCaseFold() {
        XCTAssertEqual(s("resume", "Résumé"), Matcher.exact)
        XCTAssertEqual(s("CAFE", "café"), Matcher.exact)
    }

    func testTyposAndFuzzyOnlyWhenAllowed() {
        XCTAssertEqual(s("chorme", "Google Chrome"), 0)
        XCTAssertEqual(s("chorme", "Google Chrome", fuzzy: true), Matcher.typo)
        XCTAssertGreaterThan(s("sysset", "System Settings", fuzzy: true), 0)
        XCTAssertEqual(s("zq", "Safari", fuzzy: true), 0)
    }

    func testScatteredLettersAreRejected() {
        XCTAssertEqual(s("aei", "Activity Monitor Helper", fuzzy: true), 0)
    }

    func testHighlights() {
        let name = "Visual Studio Code"
        let marked = Matcher.highlights(for: "vsc", in: name).map { String(name[$0]) }
        XCTAssertEqual(marked, ["V", "S", "C"])
        let accent = "Résumé.pdf"
        XCTAssertEqual(Matcher.highlights(for: "resu", in: accent).map { String(accent[$0]) }, ["Résu"])
    }
}

final class CalculatorTests: XCTestCase {
    func v(_ q: String) -> Double? { Calculator.evaluate(q)?.value }

    func testArithmetic() {
        XCTAssertEqual(v("2+3*4"), 14)
        XCTAssertEqual(v("(2+3)*4"), 20)
        XCTAssertEqual(v("2^3^2"), 512)
        XCTAssertEqual(v("-2^2"), -4)
        XCTAssertEqual(v("10/4"), 2.5)
        XCTAssertEqual(v("12 × 3 ÷ 4"), 9)
        XCTAssertEqual(v("3 x 4"), 12)
        XCTAssertEqual(v("2pi"), 2 * .pi)
        XCTAssertEqual(v("sqrt(16) + 5!"), 124)
        XCTAssertEqual(v("1,000,000 / 4"), 250_000)
        XCTAssertEqual(v("0xff + 1"), 256)
        XCTAssertEqual(v("max(3, 9, 4)"), 9)
        XCTAssertEqual(Calculator.evaluate("0.1+0.2")?.copyText, "0.3")
    }

    func testPercentages() {
        XCTAssertEqual(v("20% of 150"), 30)
        XCTAssertEqual(v("50 + 10%"), 55)
        XCTAssertEqual(v("80 - 25%"), 60)
        XCTAssertEqual(v("15%"), 0.15)
    }

    func testNotACalculation() {
        XCTAssertNil(v("42"))
        XCTAssertNil(v("pi"))
        XCTAssertNil(v("e"))
        XCTAssertNil(v("iphone 15"))
        XCTAssertNil(v("2+"))
        XCTAssertNil(v("1/0"))
        XCTAssertNil(v("safari"))
    }

    func testUnits() throws {
        XCTAssertEqual(try XCTUnwrap(v("5 km to mi")), 3.10686, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(v("100f in c")), 37.7778, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(v("100°F to °C")), 37.7778, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(v("2 cups to ml")), 473.176, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(v("1 gib in mb")), 1073.741824, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(v("3 weeks in days")), 21, accuracy: 0.0001)
        XCTAssertEqual(Calculator.evaluate("5 km to mi")?.display.hasSuffix(" mi"), true)
        XCTAssertNil(v("5 km to kg"))
    }
}
