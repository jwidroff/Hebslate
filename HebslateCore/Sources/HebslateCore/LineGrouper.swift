import Foundation

/// RGB color sampled from the bubble behind an OCR line (0...255).
public struct RGB: Codable, Sendable, Hashable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    /// WhatsApp outgoing bubbles are green in both themes
    /// (light #D9FDD3, dark #005C4B / #144D37). Incoming bubbles are white
    /// (#FFFFFF) or dark gray (#202C33); neither passes this test.
    public var isWhatsAppGreen: Bool { g - r > 20 && g - b > 8 }

    /// Known WhatsApp bubble colors (light and dark themes).
    public static let whatsAppBubbles: [RGB] = [
        RGB(255, 255, 255), RGB(217, 253, 211),   // light: incoming, outgoing
        RGB(32, 44, 51), RGB(0, 92, 75), RGB(20, 77, 55), // dark: incoming, outgoing (old/new)
        RGB(31, 44, 52)
    ]

    /// True when this looks like the inside of a WhatsApp bubble.
    public var isWhatsAppBubble: Bool {
        isWhatsAppGreen || Self.whatsAppBubbles.contains { distance(to: $0) < 22 }
    }

    public func distance(to o: RGB) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// Rectangle in normalized frame coordinates (0...1), origin top-left,
/// y growing downward.
public struct NormRect: Codable, Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// One line of text recognized by on-device OCR.
/// `box` is normalized to the full frame: origin top-left, y grows downward.
public struct OCRLine: Sendable, Hashable {
    public var text: String
    public var box: NormRect
    /// Color of the bubble right next to the text, if it could be sampled.
    public var bubbleColor: RGB?
    /// Result of a pixel scan between this line and the previous one:
    /// `true` = still inside the same bubble, `false` = crossed the chat
    /// background, `nil` = unknown (fall back to the vertical-gap rule).
    public var sameBubbleAsPrevious: Bool?

    public init(text: String, box: NormRect, bubbleColor: RGB? = nil, sameBubbleAsPrevious: Bool? = nil) {
        self.text = text
        self.box = box
        self.bubbleColor = bubbleColor
        self.sameBubbleAsPrevious = sameBubbleAsPrevious
    }
}

/// Turns raw OCR lines from one frame into ordered chat messages, using bubble
/// color and geometry the way WhatsApp lays out a conversation.
public struct LineGrouper: Sendable {

    public struct Layout: Sendable, Hashable, Codable {
        /// Normalized y where the chat area starts (below the contact header).
        public var chatTop: Double = 0.115
        /// Normalized y where the chat area ends (above the text input bar).
        public var chatBottom: Double = 0.905
        /// Lines this close to the chat edges are treated as cut off.
        public var edgeMargin: Double = 0.012
        /// In a left-to-right UI your own messages are on the right. When the
        /// phone's UI language is Hebrew WhatsApp mirrors the layout. Only used
        /// when the bubble color could not be sampled.
        public var outgoingOnRight: Bool = true

        public init() {}
    }

    public var layout: Layout

    public init(layout: Layout = Layout()) { self.layout = layout }

    /// `groups[i]` are the raw OCR lines that were merged into `messages[i]`,
    /// so a caller with access to the frame's pixels (the app target) can
    /// decide whether that bubble is a photo and, if so, where its text sat.
    public func group(_ allLines: [OCRLine]) -> (contactName: String?, messages: [FrameMessage], groups: [[OCRLine]]) {
        let header = allLines.filter { $0.box.midY < layout.chatTop }
        let lines = allLines
            .filter { $0.box.midY >= layout.chatTop && $0.box.midY <= layout.chatBottom }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.box.minY < $1.box.minY }

        var messages: [FrameMessage] = []
        var groups: [[OCRLine]] = []
        var current: [OCRLine] = []
        var currentSide: MessageSide = .incoming

        func flush() {
            guard !current.isEmpty else { return }
            if let msg = makeMessage(current, side: currentSide) {
                messages.append(msg)
                groups.append(current)
            }
            current = []
        }

        for line in lines {
            let side = classify(line)
            if let prev = current.last {
                let lineHeight = Swift.max(prev.box.height, line.box.height)
                let gap = line.box.minY - prev.box.maxY
                let horizontalOverlap = Swift.min(prev.box.maxX, line.box.maxX) - Swift.max(prev.box.minX, line.box.minX)
                let sameBubble: Bool
                if let scanned = line.sameBubbleAsPrevious {
                    sameBubble = scanned
                } else {
                    sameBubble = gap < lineHeight * 0.75 && horizontalOverlap > -0.05
                }
                // A time-only line (e.g. "14:32 ✓✓") always belongs to the bubble above it.
                let isTimeOnly = Self.isTimeOnly(line.text)
                if !isTimeOnly && (side != currentSide || !sameBubble) {
                    flush()
                }
            }
            if current.isEmpty { currentSide = side }
            current.append(line)
        }
        flush()

        return (contactName(from: header), messages, groups)
    }

    // MARK: - Classification

    func classify(_ line: OCRLine) -> MessageSide {
        let centered = abs(line.box.midX - 0.5) < 0.06 && line.box.width < 0.6
        if let c = line.bubbleColor {
            if c.isWhatsAppGreen { return .outgoing }
            if centered && (Self.looksLikeDate(line.text) || line.box.width < 0.45) { return .system }
            return .incoming
        }
        if centered { return .system }
        let onRight = line.box.midX > 0.5
        return onRight == layout.outgoingOnRight ? .outgoing : .incoming
    }

    func makeMessage(_ lines: [OCRLine], side: MessageSide) -> FrameMessage? {
        var texts = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }
        var time: String?

        // WhatsApp prints the time (and read ticks) in the bubble's last line.
        if let last = texts.last {
            let (stripped, t) = Self.extractTime(from: last)
            if let t {
                time = t
                if stripped.isEmpty { texts.removeLast() } else { texts[texts.count - 1] = stripped }
            }
        }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let top = lines.map { $0.box.minY }.min() ?? 0
        let bottom = lines.map { $0.box.maxY }.max() ?? 1
        return FrameMessage(
            side: side,
            text: text,
            time: side == .system ? nil : time,
            cutOffTop: top - layout.chatTop < layout.edgeMargin,
            cutOffBottom: time == nil && layout.chatBottom - bottom < layout.edgeMargin * 2
        )
    }

    func contactName(from header: [OCRLine]) -> String? {
        // Skip the status bar (clock, carrier) and presence lines; the contact
        // name is the tallest remaining text in the header.
        let candidates = header.filter { line in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard line.box.minY > 0.03, t.count > 1 else { return false }
            if Self.isTimeOnly(t) { return false }
            let lowered = t.lowercased()
            let presence = ["online", "typing", "last seen", "tap here", "click here",
                            "מחובר", "מקליד", "הקלד", "נראה לאחרונה", "לחץ כאן", "הקש כאן"]
            return !presence.contains { lowered.contains($0) }
        }
        return candidates.max { $0.box.height < $1.box.height }?.text
    }

    // MARK: - Text helpers

    static let timePattern = #"(?:[01]?\d|2[0-3])[:.][0-5]\d(?:\s?(?:AM|PM|am|pm|לפנה״צ|אחה״צ|לפנה"צ|אחה"צ))?"#
    static let ticks = #"[\s✓✔√/\\]*"#
    static let edited = #"(?:Edited|edited|נערכה|נערך)?"#

    /// Removes a WhatsApp time stamp (and read ticks / "edited") from the
    /// start or end of a line. Returns the remaining text and the time.
    public static func extractTime(from line: String) -> (String, String?) {
        let patterns = [
            "\\s*\(edited)\\s*(\(timePattern))\(ticks)$",
            "^\(ticks)(\(timePattern))\\s*\(edited)\\s*"
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let time = ns.substring(with: m.range(at: 1))
                let rest = ns.replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespaces)
                return (rest, time)
            }
        }
        return (line, nil)
    }

    public static func isTimeOnly(_ s: String) -> Bool {
        let (rest, t) = extractTime(from: s.trimmingCharacters(in: .whitespaces))
        return t != nil && rest.isEmpty
    }

    static func looksLikeDate(_ s: String) -> Bool {
        let t = s.lowercased()
        let words = ["today", "yesterday", "היום", "אתמול", "יום ", "monday", "tuesday", "wednesday",
                     "thursday", "friday", "saturday", "sunday", "ראשון", "שני", "שלישי", "רביעי",
                     "חמישי", "שישי", "שבת"]
        if words.contains(where: { t.contains($0) }) { return true }
        return t.range(of: #"\d{1,2}[./]\d{1,2}[./]\d{2,4}"#, options: .regularExpression) != nil
            || t.range(of: #"\d{1,2}\s+\p{L}+\s+\d{4}"#, options: .regularExpression) != nil
    }
}
