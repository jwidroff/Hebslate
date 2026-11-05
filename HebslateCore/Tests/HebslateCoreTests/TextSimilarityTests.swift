import XCTest
@testable import HebslateCore

final class TextSimilarityTests: XCTestCase {

    func testNormalizeStripsNiqqudPunctuationAndSpaces() {
        let a = TextSimilarity.normalize("שָׁלוֹם,   עוֹלָם!")
        let b = TextSimilarity.normalize("שלום עולם")
        XCTAssertEqual(a, b)
    }

    func testRatio() {
        XCTAssertEqual(TextSimilarity.ratio("מה שלומך", "מה שלומך"), 1)
        XCTAssertGreaterThan(TextSimilarity.ratio("מה שלומך היום", "מה שלומר היום"), 0.9)
        XCTAssertLessThan(TextSimilarity.ratio("מה שלומך", "איפה אתה גר"), 0.5)
    }

    func testFragmentRatio() {
        let full = TextSimilarity.normalize("אל תשכח להביא את הספר שדיברנו עליו")
        let start = TextSimilarity.normalize("אל תשכח להביא")
        let end = TextSimilarity.normalize("הספר שדיברנו עליו")
        XCTAssertGreaterThan(TextSimilarity.fragmentRatio(start, in: full, position: .prefix), 0.95)
        XCTAssertGreaterThan(TextSimilarity.fragmentRatio(end, in: full, position: .suffix), 0.95)
        XCTAssertLessThan(TextSimilarity.fragmentRatio(end, in: full, position: .prefix), 0.6)
        XCTAssertGreaterThan(TextSimilarity.fragmentRatio(TextSimilarity.normalize("להביא את הספר"), in: full, position: .anywhere), 0.9)
    }
}

final class ScrollEstimatorTests: XCTestCase {

    /// A fake "chat" brightness profile with distinct bumps (bubbles).
    func content(_ length: Int) -> [Double] {
        (0..<length).map { i in 120 + 80 * sin(Double(i) / 7) + Double((i * 37) % 23) }
    }

    func testDetectsUpwardShift() {
        let all = content(400)
        let prev = Array(all[0..<200])
        let cur = Array(all[30..<230])          // content moved up by 30 rows
        let e = ScrollEstimator.estimate(previous: prev, current: cur)
        XCTAssertEqual(e.shift, 30)
        XCTAssertLessThan(e.error, 1)
    }

    func testDetectsDownwardShift() {
        let all = content(400)
        let prev = Array(all[100..<300])
        let cur = Array(all[60..<260])
        XCTAssertEqual(ScrollEstimator.estimate(previous: prev, current: cur).shift, -40)
    }

    func testSelectorKeepsFramesAfterEnoughScroll() {
        let all = content(1000)
        var sel = ScrollEstimator.Selector(keepFraction: 0.5)
        var kept: [Int] = []
        // Scroll 20 rows per sampled frame, chat area is 200 rows tall.
        for (i, start) in stride(from: 0, through: 600, by: 20).enumerated() {
            if sel.shouldKeep(Array(all[start..<(start + 200)])) { kept.append(start) }
        }
        XCTAssertEqual(kept, [0, 100, 200, 300, 400, 500, 600])
    }

    func testSelectorSkipsStillFrames() {
        let frame = Array(content(200))
        var sel = ScrollEstimator.Selector()
        XCTAssertTrue(sel.shouldKeep(frame))
        XCTAssertFalse(sel.shouldKeep(frame))
        XCTAssertFalse(sel.shouldKeep(frame))
    }
}
