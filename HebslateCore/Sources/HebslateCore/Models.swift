import Foundation

/// Which side of the chat a bubble sits on.
public enum MessageSide: String, Codable, Sendable, Hashable {
    /// Sent by the other person (white / dark-gray bubble).
    case incoming
    /// Sent by the phone's owner (green bubble).
    case outgoing
    /// Centered pills such as "Today", "Yesterday", "12 March 2025",
    /// "Messages are end-to-end encrypted", "X joined", etc.
    case system
}

/// A patch of text to render over an image message, positioned relative to
/// the image itself (0...1, origin top-left), not the frame it came from.
/// `original` is the Hebrew OCR found at that spot; `translation` is filled
/// in by the translator, same as `ChatMessage.translation`.
public struct ImageOverlay: Codable, Sendable, Hashable {
    public var box: NormRect
    public var original: String
    public var translation: String?

    public init(box: NormRect, original: String, translation: String? = nil) {
        self.box = box
        self.original = original
        self.translation = translation
    }
}

/// A single message as seen in ONE frame of the screen recording.
///
/// Produced by OCR (Cloud Vision + bubble-color heuristics). `cutOffTop` /
/// `cutOffBottom` mean the bubble runs past the visible chat area, so `text`
/// is only part of the message. When the bubble is a photo with Hebrew text
/// baked into it, `imageData` holds the cropped photo and `imageOverlays`
/// locates each patch of text within it; `text` is still the joined OCR text
/// (for stitching and search), but the photo should be shown instead.
public struct FrameMessage: Codable, Sendable, Hashable {
    public var side: MessageSide
    public var text: String
    public var sender: String?
    /// The sender name's own text color, as rendered in the chat (not the
    /// bubble background), sampled so the app can show the name in the same
    /// color instead of inventing one.
    public var senderColor: RGB?
    public var time: String?
    public var cutOffTop: Bool
    public var cutOffBottom: Bool
    public var imageData: Data?
    public var imageOverlays: [ImageOverlay]

    public init(side: MessageSide,
                text: String,
                sender: String? = nil,
                senderColor: RGB? = nil,
                time: String? = nil,
                cutOffTop: Bool = false,
                cutOffBottom: Bool = false,
                imageData: Data? = nil,
                imageOverlays: [ImageOverlay] = []) {
        self.side = side
        self.text = text
        self.sender = sender
        self.senderColor = senderColor
        self.time = time
        self.cutOffTop = cutOffTop
        self.cutOffBottom = cutOffBottom
        self.imageData = imageData
        self.imageOverlays = imageOverlays
    }

    public var isPartial: Bool { cutOffTop || cutOffBottom }
}

/// All the messages read from one frame, top to bottom.
public struct FrameReading: Codable, Sendable {
    public var frameIndex: Int
    public var timestamp: Double
    public var contactName: String?
    public var messages: [FrameMessage]

    public init(frameIndex: Int, timestamp: Double, contactName: String? = nil, messages: [FrameMessage]) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.contactName = contactName
        self.messages = messages
    }
}

/// A message in the rebuilt, de-duplicated conversation.
public struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var side: MessageSide
    /// Original (Hebrew) text.
    public var original: String
    /// English translation, `nil` until translated. Reset to `nil` whenever
    /// `original` is replaced by a more complete reading.
    public var translation: String?
    public var sender: String?
    /// The sender name's own text color, sampled from the chat; see
    /// `FrameMessage.senderColor`.
    public var senderColor: RGB?
    public var time: String?
    /// True while we have only seen a cut-off part of this bubble
    /// (top of the bubble was above the visible area / bottom below it).
    public var cutOffTop: Bool
    public var cutOffBottom: Bool
    /// Marks a place where frames did not overlap (the user scrolled faster
    /// than the recording could capture), so messages may be missing here.
    public var isGapMarker: Bool
    /// A photo with Hebrew text baked into it, shown instead of a plain
    /// translated bubble; see `FrameMessage.imageData`.
    public var imageData: Data?
    public var imageOverlays: [ImageOverlay]

    public init(id: UUID = UUID(),
                side: MessageSide,
                original: String,
                translation: String? = nil,
                sender: String? = nil,
                senderColor: RGB? = nil,
                time: String? = nil,
                cutOffTop: Bool = false,
                cutOffBottom: Bool = false,
                isGapMarker: Bool = false,
                imageData: Data? = nil,
                imageOverlays: [ImageOverlay] = []) {
        self.id = id
        self.side = side
        self.original = original
        self.translation = translation
        self.sender = sender
        self.senderColor = senderColor
        self.time = time
        self.cutOffTop = cutOffTop
        self.cutOffBottom = cutOffBottom
        self.isGapMarker = isGapMarker
        self.imageData = imageData
        self.imageOverlays = imageOverlays
    }

    public init(_ m: FrameMessage) {
        self.init(side: m.side, original: m.text, sender: m.sender, senderColor: m.senderColor, time: m.time,
                  cutOffTop: m.cutOffTop, cutOffBottom: m.cutOffBottom,
                  imageData: m.imageData, imageOverlays: m.imageOverlays)
    }

    public var isPartial: Bool { cutOffTop || cutOffBottom }
    public var isImage: Bool { imageData != nil }

    public var needsTranslation: Bool {
        guard !isGapMarker else { return false }
        if !imageOverlays.isEmpty { return imageOverlays.contains { $0.translation == nil } }
        return translation == nil && !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func gap() -> ChatMessage {
        ChatMessage(side: .system, original: "", isGapMarker: true)
    }
}

/// A finished (or in-progress) translated conversation, persisted to disk.
public struct Conversation: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), messages: [ChatMessage]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.messages = messages
    }

    /// Plain-text transcript of the translation, for sharing.
    public func transcript(includeOriginal: Bool = false) -> String {
        var lines: [String] = ["Hebslate translation — \(title)", ""]
        for m in messages {
            if m.isGapMarker { lines.append("[…possibly missing messages…]"); continue }
            let english = m.translation ?? m.original
            let who: String
            switch m.side {
            case .system: lines.append("— \(english) —"); continue
            case .outgoing: who = "Me"
            case .incoming: who = m.sender ?? title
            }
            let time = m.time.map { " [\($0)]" } ?? ""
            lines.append("\(who)\(time): \(english)")
            if includeOriginal { lines.append("    (\(m.original))") }
        }
        return lines.joined(separator: "\n")
    }
}
