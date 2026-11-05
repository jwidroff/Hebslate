import CoreGraphics
import Foundation
import HebslateCore
import ImageIO
import UniformTypeIdentifiers

/// Thin Claude Messages API client (raw HTTPS; there is no official Swift SDK).
///
/// Used for two optional jobs:
///  * `readFrame` — transcribe one frame into structured messages when
///    on-device Hebrew OCR isn't available or you prefer Claude's accuracy;
///  * `translate` — translate the stitched, not-yet-translated messages with
///    the surrounding conversation as context.
struct ClaudeClient {
    var apiKey: String
    var model: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2026-10-21"
    /// Server-side refusal fallback ("default" routing) for models that support it.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5"]

    enum ClaudeError: LocalizedError {
        case missingKey
        case http(Int, String)
        case refusal
        case truncated
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add your Claude API key in Settings to use Claude."
            case .http(401, _): "Claude rejected the API key. Check it in Settings."
            case .http(let code, let msg): "Claude API error \(code): \(msg)"
            case .refusal: "Claude declined to process this content."
            case .truncated: "Claude's answer was cut off. Try again."
            case .badResponse(let s): "Unexpected response from Claude: \(s)"
            }
        }
    }

    // MARK: - Frame reading

    private struct FrameJSON: Decodable {
        struct Msg: Decodable {
            var side: String
            var sender: String
            var text: String
            var time: String
            var cut_off_top: Bool
            var cut_off_bottom: Bool
        }
        var is_chat_screen: Bool
        var contact_name: String
        var messages: [Msg]
    }

    private static let frameSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "is_chat_screen": ["type": "boolean"],
            "contact_name": ["type": "string"],
            "messages": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "side": ["type": "string", "enum": ["incoming", "outgoing", "system"]],
                        "sender": ["type": "string"],
                        "text": ["type": "string"],
                        "time": ["type": "string"],
                        "cut_off_top": ["type": "boolean"],
                        "cut_off_bottom": ["type": "boolean"],
                    ],
                    "required": ["side", "sender", "text", "time", "cut_off_top", "cut_off_bottom"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["is_chat_screen", "contact_name", "messages"],
        "additionalProperties": false,
    ]

    private static let frameSystemPrompt = """
    You transcribe screenshots of WhatsApp conversations so they can be stitched \
    together and translated later. Transcribe; do not translate.

    For the screenshot, return every chat bubble that is visible, in order from top to bottom:
    - side: "outgoing" for the phone owner's bubbles (green), "incoming" for the other \
    person's bubbles (white or dark gray), "system" for centered pills such as dates \
    ("היום", "אתמול", "12 במרץ 2025"), encryption notices or "X added Y".
    - text: the bubble's text exactly as written, in its original language, keeping \
    emoji and line breaks. Leave out the time stamp, read ticks, "edited"/"נערכה" labels \
    and the gray quoted preview of a reply. For media without a caption write a short \
    English placeholder in brackets, such as [Photo], [Video], [Sticker], [GIF], \
    [Voice message 0:14], [Document: name.pdf], [Deleted message].
    - sender: in group chats, the colored sender name at the top of an incoming bubble; otherwise "".
    - time: the bubble's time stamp as shown (for example "21:05"), or "".
    - cut_off_top / cut_off_bottom: true when the bubble continues past the top or bottom \
    edge of the visible chat area (hidden behind the header or the typing bar), so only \
    part of its text is visible. Transcribe just the visible part.

    contact_name: the chat or group name in the header, or "".
    Ignore the status bar, the header, the typing bar and the keyboard. If the image is not \
    a WhatsApp chat (for example Control Center or the home screen), set is_chat_screen to \
    false and return no messages.
    """

    func readFrame(_ frame: KeyFrame) async throws -> FrameReading {
        guard let jpeg = Self.jpegData(frame.image, maxHeight: 1600) else {
            throw ClaudeError.badResponse("could not encode frame")
        }
        let content: [[String: Any]] = [
            ["type": "image",
             "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ["type": "text", "text": "Transcribe this WhatsApp screenshot."],
        ]
        let json = try await send(system: Self.frameSystemPrompt, content: content,
                                  schema: Self.frameSchema, effort: "low")
        let parsed = try JSONDecoder().decode(FrameJSON.self, from: Data(json.utf8))
        guard parsed.is_chat_screen else {
            return FrameReading(frameIndex: frame.index, timestamp: frame.time, messages: [])
        }
        let messages = parsed.messages.map { m in
            FrameMessage(side: MessageSide(rawValue: m.side) ?? .incoming,
                         text: m.text,
                         sender: m.sender.isEmpty ? nil : m.sender,
                         time: m.time.isEmpty ? nil : m.time,
                         cutOffTop: m.cut_off_top,
                         cutOffBottom: m.cut_off_bottom)
        }
        return FrameReading(frameIndex: frame.index, timestamp: frame.time,
                            contactName: parsed.contact_name.isEmpty ? nil : parsed.contact_name,
                            messages: messages)
    }

    // MARK: - Translation

    private struct TranslationJSON: Decodable {
        struct Item: Decodable { var id: String; var english: String }
        var translations: [Item]
    }

    private static let translationSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "translations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["id": ["type": "string"], "english": ["type": "string"]],
                    "required": ["id", "english"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["translations"],
        "additionalProperties": false,
    ]

    private static let translationSystemPrompt = """
    You translate WhatsApp conversations from Hebrew into natural, conversational English, \
    the way a bilingual friend would. Keep the tone (casual, slang, terse, warm), emoji, \
    names and numbers. Translate idioms and abbreviations by meaning (for example \
    "סבבה" → "Cool", "בע״ה" → "God willing", "תכלס" → "Bottom line"). Text that is \
    already English or a bracketed placeholder like [Photo] stays as is. If a message is \
    marked partial, translate just the visible fragment and add "…" where it is cut.

    You get earlier messages for context and the messages to translate, each with an id. \
    Return one translation for every id you were asked to translate, and nothing else.
    """

    /// Translates `items` (with ids) using `context` (already-translated earlier messages).
    func translate(_ items: [ChatMessage], context: [ChatMessage], contactName: String) async throws -> [UUID: String] {
        guard !items.isEmpty else { return [:] }
        var ids: [String: UUID] = [:]
        func who(_ m: ChatMessage) -> String {
            switch m.side {
            case .outgoing: "Me"
            case .incoming: m.sender ?? (contactName.isEmpty ? "Them" : contactName)
            case .system: "System"
            }
        }
        var lines = ["Chat with: \(contactName.isEmpty ? "unknown" : contactName)", ""]
        if !context.isEmpty {
            lines.append("Earlier messages (context only, do not translate):")
            for m in context { lines.append("\(who(m)): \(m.original)") }
            lines.append("")
        }
        lines.append("Translate these messages:")
        for (i, m) in items.enumerated() {
            let id = "m\(i + 1)"
            ids[id] = m.id
            let partial = m.isPartial ? " (partial)" : ""
            lines.append("[\(id)] \(who(m))\(partial): \(m.original)")
        }

        let json = try await send(system: Self.translationSystemPrompt,
                                  content: [["type": "text", "text": lines.joined(separator: "\n")]],
                                  schema: Self.translationSchema, effort: "medium")
        let parsed = try JSONDecoder().decode(TranslationJSON.self, from: Data(json.utf8))
        var out: [UUID: String] = [:]
        for t in parsed.translations {
            if let uuid = ids[t.id] { out[uuid] = t.english }
        }
        return out
    }

    // MARK: - HTTP

    /// Sends one request with structured JSON output and returns the JSON text.
    private func send(system: String, content: [[String: Any]], schema: [String: Any], effort: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
        ]
        let useFallback = Self.fallbackModels.contains(model)
        if useFallback { body["fallbacks"] = "default" }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if useFallback { request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Retry rate limits, overloads and network hiccups with backoff.
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return try Self.extractText(data) }
                let retryable = status == 408 || status == 409 || status == 429 || status >= 500
                if retryable && attempt < 4 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                throw ClaudeError.http(status, Self.errorMessage(data))
            } catch let error as URLError where attempt < 4 && error.code != .cancelled {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
    }

    private static func extractText(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse("not JSON")
        }
        let stop = obj["stop_reason"] as? String
        if stop == "refusal" { throw ClaudeError.refusal }
        if stop == "max_tokens" { throw ClaudeError.truncated }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClaudeError.badResponse("no text") }
        return text
    }

    private static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }

    // MARK: - Image encoding

    static func jpegData(_ image: CGImage, maxHeight: Int) -> Data? {
        var source = image
        if image.height > maxHeight {
            let scale = Double(maxHeight) / Double(image.height)
            let w = Int(Double(image.width) * scale), h = maxHeight
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            source = scaled
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, source, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
