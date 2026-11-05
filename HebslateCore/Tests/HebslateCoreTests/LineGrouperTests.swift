import XCTest
@testable import HebslateCore

final class LineGrouperTests: XCTestCase {

    let white = RGB(255, 255, 255)
    let green = RGB(217, 253, 211)
    let darkGreen = RGB(0, 92, 75)
    let darkGray = RGB(32, 44, 51)

    func line(_ text: String, x: Double, y: Double, w: Double = 0.5, color: RGB?, same: Bool? = nil) -> OCRLine {
        OCRLine(text: text, box: NormRect(x: x, y: y, width: w, height: 0.02), bubbleColor: color, sameBubbleAsPrevious: same)
    }

    func testGreenIsOutgoing() {
        XCTAssertTrue(green.isWhatsAppGreen)
        XCTAssertTrue(darkGreen.isWhatsAppGreen)
        XCTAssertFalse(white.isWhatsAppGreen)
        XCTAssertFalse(darkGray.isWhatsAppGreen)
        XCTAssertFalse(RGB(239, 234, 226).isWhatsAppGreen) // default wallpaper
    }

    func testGroupsLinesIntoBubbles() {
        let lines = [
            line("היום", x: 0.45, y: 0.15, w: 0.1, color: RGB(225, 242, 251)),
            line("היי, מה נשמע?", x: 0.05, y: 0.20, color: white),
            line("שאלה קטנה 10:41", x: 0.05, y: 0.225, color: white, same: true),
            line("הכל טוב", x: 0.5, y: 0.30, w: 0.4, color: green),
            line("10:42 ✓✓", x: 0.75, y: 0.325, w: 0.15, color: green),
            line("נדבר אחר כך", x: 0.5, y: 0.37, w: 0.4, color: green, same: false),
        ]
        let (_, msgs, _) = LineGrouper().group(lines)
        XCTAssertEqual(msgs.map(\.side), [.system, .incoming, .outgoing, .outgoing])
        XCTAssertEqual(msgs[1].text, "היי, מה נשמע?\nשאלה קטנה")
        XCTAssertEqual(msgs[1].time, "10:41")
        XCTAssertEqual(msgs[2].text, "הכל טוב")
        XCTAssertEqual(msgs[2].time, "10:42")
        XCTAssertEqual(msgs[3].text, "נדבר אחר כך")
    }

    func testHeaderAndInputBarIgnoredAndContactNameFound() {
        let lines = [
            OCRLine(text: "9:41", box: NormRect(x: 0.1, y: 0.01, width: 0.1, height: 0.02)),
            OCRLine(text: "יוסי כהן", box: NormRect(x: 0.3, y: 0.06, width: 0.3, height: 0.025)),
            OCRLine(text: "מחובר/ת", box: NormRect(x: 0.3, y: 0.088, width: 0.2, height: 0.015)),
            line("שלום", x: 0.05, y: 0.4, w: 0.2, color: white),
            OCRLine(text: "הקלד/י הודעה", box: NormRect(x: 0.2, y: 0.95, width: 0.3, height: 0.02)),
        ]
        let (name, msgs, _) = LineGrouper().group(lines)
        XCTAssertEqual(name, "יוסי כהן")
        XCTAssertEqual(msgs.map(\.text), ["שלום"])
    }

    func testTallBubbleCutOffAtTopAssumesOneMessage() {
        // A bubble big enough that only its lower portion fits in frame: the
        // first line sits right at the top of the chat area (cut off), and
        // the next line is far enough below it that the usual gap heuristic
        // would otherwise treat it as a new bubble.
        let lines = [
            line("line one cut off at top", x: 0.05, y: 0.118, color: white),
            line("much further down, same bubble", x: 0.05, y: 0.4, color: white),
        ]
        let (_, msgs, _) = LineGrouper().group(lines)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].text, "line one cut off at top\nmuch further down, same bubble")
        XCTAssertTrue(msgs[0].cutOffTop)
    }

    func testCutOffFlags() {
        let lines = [
            line("סוף של הודעה ארוכה", x: 0.05, y: 0.118, color: white),
            line("תחילת הודעה", x: 0.5, y: 0.885, w: 0.4, color: green),
        ]
        let (_, msgs, _) = LineGrouper().group(lines)
        XCTAssertTrue(msgs[0].cutOffTop)
        XCTAssertTrue(msgs[1].cutOffBottom)
    }

    func testExtractTime() {
        XCTAssertEqual(LineGrouper.extractTime(from: "מה קורה 21:05").1, "21:05")
        XCTAssertEqual(LineGrouper.extractTime(from: "מה קורה 21:05").0, "מה קורה")
        XCTAssertEqual(LineGrouper.extractTime(from: "9:05 PM ✓✓").1, "9:05 PM")
        XCTAssertEqual(LineGrouper.extractTime(from: "נערכה 14:10").1, "14:10")
        XCTAssertNil(LineGrouper.extractTime(from: "נפגש ב10:30 ליד הבית").1)
        XCTAssertTrue(LineGrouper.isTimeOnly("12:30 ✓✓"))
        XCTAssertFalse(LineGrouper.isTimeOnly("בשעה 12:30"))
    }
}
