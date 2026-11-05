import XCTest
@testable import HebslateCore

final class ConversationStitcherTests: XCTestCase {

    // A small Hebrew conversation, top (oldest) to bottom (newest).
    let chat: [FrameMessage] = [
        FrameMessage(side: .system, text: "היום"),
        FrameMessage(side: .incoming, text: "היי, מה שלומך?", time: "09:12"),
        FrameMessage(side: .outgoing, text: "בסדר גמור, תודה! ואתה?", time: "09:13"),
        FrameMessage(side: .incoming, text: "מצוין. נפגשים מחר בערב?", time: "09:15"),
        FrameMessage(side: .outgoing, text: "כן, בשמונה בבית קפה ליד הים", time: "09:16"),
        FrameMessage(side: .incoming, text: "סגור", time: "09:16"),
        FrameMessage(side: .outgoing, text: "אל תשכח להביא את הספר שדיברנו עליו", time: "09:20"),
        FrameMessage(side: .incoming, text: "בטח, אני כבר שם אותו בתיק", time: "09:21"),
        FrameMessage(side: .outgoing, text: "תודה רבה!", time: "09:22"),
    ]

    func frame(_ i: Int, _ range: Range<Int>) -> FrameReading {
        FrameReading(frameIndex: i, timestamp: Double(i), messages: Array(chat[range]))
    }

    func texts(_ s: ConversationStitcher) -> [String] {
        s.messages.filter { !$0.isGapMarker }.map(\.original)
    }

    func testScrollingDownDeduplicatesOverlap() {
        var s = ConversationStitcher()
        s.add(frame(0, 0..<4))
        s.add(frame(1, 2..<6))
        s.add(frame(2, 4..<9))
        XCTAssertEqual(texts(s), chat.map(\.text))
        XCTAssertFalse(s.messages.contains(where: \.isGapMarker))
    }

    func testScrollingUpPrependsOlderMessages() {
        var s = ConversationStitcher()
        s.add(frame(0, 5..<9))
        s.add(frame(1, 3..<7))
        s.add(frame(2, 0..<4))
        XCTAssertEqual(texts(s), chat.map(\.text))
        XCTAssertEqual(s.direction, -1)
    }

    func testIdenticalFramesAddNothing() {
        var s = ConversationStitcher()
        s.add(frame(0, 2..<6))
        let r = s.add(frame(1, 2..<6))
        XCTAssertEqual(r.appended, 0)
        XCTAssertEqual(r.prepended, 0)
        XCTAssertEqual(s.messages.count, 4)
    }

    func testOCRNoiseStillMatches() {
        var s = ConversationStitcher()
        s.add(frame(0, 0..<5))
        var noisy = Array(chat[3..<8])
        noisy[0].text = "מצוין נפגשים מחר בערב"       // punctuation dropped
        noisy[1].text = "כן, בשמונה בבית קפה ליד הים."  // extra period
        s.add(FrameReading(frameIndex: 1, timestamp: 1, messages: noisy))
        XCTAssertEqual(texts(s), chat[0..<8].map(\.text))
    }

    func testCutOffMessageIsCompletedByLaterFrame() {
        var s = ConversationStitcher()
        var first = Array(chat[0..<7])
        // The last bubble is cut by the bottom of the screen.
        first[6] = FrameMessage(side: .outgoing, text: "אל תשכח להביא", cutOffBottom: true)
        s.add(FrameReading(frameIndex: 0, timestamp: 0, messages: first))
        // Pretend the partial message was already translated.
        let partialID = s.messages[6].id
        s.applyTranslations([partialID: "Don't forget to bring"])

        s.add(frame(1, 4..<9))
        XCTAssertEqual(texts(s), chat.map(\.text))
        let completed = s.messages.first { $0.id == partialID }!
        XCTAssertFalse(completed.isPartial)
        XCTAssertNil(completed.translation, "text changed, so it must be re-translated")
    }

    func testCutOffTopFragmentMatchesExistingMessage() {
        var s = ConversationStitcher()
        s.add(frame(0, 3..<8))
        var next = Array(chat[6..<9])
        next[0] = FrameMessage(side: .outgoing, text: "הספר שדיברנו עליו", time: "09:20", cutOffTop: true)
        s.add(FrameReading(frameIndex: 1, timestamp: 1, messages: next))
        XCTAssertEqual(texts(s), chat[3..<9].map(\.text))
        XCTAssertFalse(s.messages[3].isPartial, "full reading must not be replaced by a fragment")
    }

    func testRepeatedShortMessagesUseContext() {
        let msgs: [FrameMessage] = [
            .init(side: .incoming, text: "אוקיי"),
            .init(side: .outgoing, text: "מגיע עוד עשר דקות"),
            .init(side: .incoming, text: "אוקיי"),
            .init(side: .outgoing, text: "חונה עכשיו ליד הכניסה"),
            .init(side: .incoming, text: "אוקיי"),
            .init(side: .outgoing, text: "אני בפנים, איפה אתה?"),
        ]
        var s = ConversationStitcher()
        s.add(FrameReading(frameIndex: 0, timestamp: 0, messages: Array(msgs[0..<4])))
        s.add(FrameReading(frameIndex: 1, timestamp: 1, messages: Array(msgs[2..<6])))
        XCTAssertEqual(texts(s), msgs.map(\.text))
    }

    func testNoOverlapInsertsGapMarker() {
        var s = ConversationStitcher()
        s.add(frame(0, 0..<3))
        let r = s.add(frame(1, 6..<9))
        XCTAssertFalse(r.foundOverlap)
        XCTAssertEqual(s.messages.filter(\.isGapMarker).count, 1)
        XCTAssertEqual(texts(s), chat[0..<3].map(\.text) + chat[6..<9].map(\.text))
    }

    func testOnlyNewMessagesNeedTranslation() {
        var s = ConversationStitcher()
        s.add(frame(0, 0..<4))
        s.applyTranslations(Dictionary(uniqueKeysWithValues: s.messages.map { ($0.id, "x") }))
        s.add(frame(1, 2..<6))
        XCTAssertEqual(s.untranslated.map(\.original), chat[4..<6].map(\.text))
    }

    func testSideMismatchNeverMatches() {
        var s = ConversationStitcher()
        s.add(FrameReading(frameIndex: 0, timestamp: 0, messages: [.init(side: .incoming, text: "תודה רבה לך")]))
        s.add(FrameReading(frameIndex: 1, timestamp: 1, messages: [
            .init(side: .incoming, text: "תודה רבה לך"),
            .init(side: .outgoing, text: "תודה רבה לך"),
        ]))
        XCTAssertEqual(s.messages.map(\.side), [.incoming, .outgoing])
    }

    func testContactNameVoting() {
        var s = ConversationStitcher()
        s.add(FrameReading(frameIndex: 0, timestamp: 0, contactName: "דני", messages: Array(chat[0..<3])))
        s.add(FrameReading(frameIndex: 1, timestamp: 1, contactName: "דנו", messages: Array(chat[1..<4])))
        s.add(FrameReading(frameIndex: 2, timestamp: 2, contactName: "דני", messages: Array(chat[2..<5])))
        XCTAssertEqual(s.contactName, "דני")
    }
}
