import CoreGraphics
import Foundation
import HebslateCore
import ImageIO
import UniformTypeIdentifiers

/// Thin Google Cloud client, authenticated with a plain API key (no OAuth or
/// service account needed). Used for two jobs:
///  * `readFrame` — Cloud Vision's DOCUMENT_TEXT_DETECTION finds the text lines,
///    which `BubbleLineAssembler` turns into messages using bubble colors;
///  * `translate` — Cloud Translation (v2) translates Hebrew to English. It is
///    a bare machine-translation endpoint with no conversation context, so
///    slang and ambiguous pronouns translate less reliably than a model would.
///
/// The API key must have the Cloud Vision API and Cloud Translation API
/// enabled in Google Cloud Console.
struct GoogleClient {
    var apiKey: String
    var layout: LineGrouper.Layout

    private static let visionEndpoint = URL(string: "https://vision.googleapis.com/v1/images:annotate")!
    private static let translateEndpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")!

    enum GoogleError: LocalizedError {
        case missingKey
        case http(Int, String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: "No Google Cloud API key is configured for this build."
            case .http(403, let msg): "Google rejected the request (\(msg)). Check that the API key is valid and that the Cloud Vision and Cloud Translation APIs are enabled for it."
            case .http(let code, let msg): "Google API error \(code): \(msg)"
            case .badResponse(let s): "Unexpected response from Google: \(s)"
            }
        }
    }

    // MARK: - Frame reading (Cloud Vision)

    func readFrame(_ frame: KeyFrame) async throws -> FrameReading {
        guard let jpeg = Self.jpegData(frame.image, maxHeight: 1600) else {
            throw GoogleError.badResponse("could not encode frame")
        }
        let body: [String: Any] = [
            "requests": [[
                "image": ["content": jpeg.base64EncodedString()],
                "features": [["type": "DOCUMENT_TEXT_DETECTION"]],
                "imageContext": ["languageHints": ["he", "en"]],
            ] as [String: Any]],
        ]
        let data = try await send(Self.visionEndpoint, body: body)
        let rawLines = try Self.parseLines(data)
        return BubbleLineAssembler(layout: layout).assemble(rawLines, frame: frame)
    }

    /// Cloud Vision groups recognized text as pages > blocks > paragraphs >
    /// words > symbols, and a wrapped WhatsApp bubble is normally one
    /// paragraph with `LINE_BREAK` symbols inside it. Keep each paragraph as
    /// one (text, box) unit — internal line breaks become "\n" rather than
    /// a new unit — so `BubbleLineAssembler` never has to re-decide whether
    /// two wrapped lines of the same bubble belong together; that was the
    /// main source of one bubble getting split into several messages.
    private static func parseLines(_ data: Data) throws -> [(text: String, box: NormRect)] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = obj["responses"] as? [[String: Any]], let first = responses.first else {
            throw GoogleError.badResponse("not JSON")
        }
        if let error = first["error"] as? [String: Any] {
            throw GoogleError.http((error["code"] as? Int) ?? 0, (error["message"] as? String) ?? "unknown error")
        }
        guard let full = first["fullTextAnnotation"] as? [String: Any],
              let pages = full["pages"] as? [[String: Any]],
              let page = pages.first,
              let width = (page["width"] as? NSNumber)?.doubleValue,
              let height = (page["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return []   // no text found in this frame
        }

        var lines: [(text: String, box: NormRect)] = []
        for block in (page["blocks"] as? [[String: Any]]) ?? [] {
            for paragraph in (block["paragraphs"] as? [[String: Any]]) ?? [] {
                if let line = paragraphLine(in: paragraph, width: width, height: height) { lines.append(line) }
            }
        }
        return lines
    }

    /// Walks a paragraph's symbols into one piece of text (inserting "\n" at
    /// each `LINE_BREAK` instead of starting a new unit), with a box from
    /// the union of every symbol's own box.
    private static func paragraphLine(in paragraph: [String: Any], width: Double, height: Double) -> (text: String, box: NormRect)? {
        var text = ""
        var xs: [Double] = [], ys: [Double] = []

        for word in (paragraph["words"] as? [[String: Any]]) ?? [] {
            for symbol in (word["symbols"] as? [[String: Any]]) ?? [] {
                text += (symbol["text"] as? String) ?? ""
                for v in ((symbol["boundingBox"] as? [String: Any])?["vertices"] as? [[String: Any]]) ?? [] {
                    if let x = (v["x"] as? NSNumber)?.doubleValue { xs.append(x) }
                    if let y = (v["y"] as? NSNumber)?.doubleValue { ys.append(y) }
                }
                switch (((symbol["property"] as? [String: Any])?["detectedBreak"] as? [String: Any])?["type"] as? String) ?? "" {
                case "LINE_BREAK": text += "\n"
                case "SPACE", "EOL_SURE_SPACE": text += " "
                default: break
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return (trimmed, NormRect(x: minX / width, y: minY / height, width: (maxX - minX) / width, height: (maxY - minY) / height))
    }

    // MARK: - Translation (Cloud Translation v2)

    /// Translations for a batch of messages: whole-bubble text for plain
    /// messages, and one entry per overlay (index-aligned to
    /// `ChatMessage.imageOverlays`) for image messages.
    struct TranslationResult: Sendable {
        var messages: [UUID: String] = [:]
        var overlays: [UUID: [String]] = [:]
    }

    /// Translates `items` into English: each plain message's text, and each
    /// image message's overlay texts individually (so an overlay's
    /// translation is never a fragment split out of a merged string).
    /// Returns no context to Google beyond the text itself (v2 is a bare
    /// translation endpoint).
    func translate(_ items: [ChatMessage]) async throws -> TranslationResult {
        enum Target { case message(UUID), overlay(UUID, Int) }
        var targets: [Target] = []
        var texts: [String] = []
        for item in items {
            if item.imageOverlays.isEmpty {
                let text = item.original.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                targets.append(.message(item.id)); texts.append(item.original)
            } else {
                for (i, overlay) in item.imageOverlays.enumerated() {
                    guard !overlay.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    targets.append(.overlay(item.id, i)); texts.append(overlay.original)
                }
            }
        }
        guard !texts.isEmpty else { return TranslationResult() }
        let body: [String: Any] = [
            "q": texts,
            "source": "iw",
            "target": "en",
            "format": "text",
        ]
        let data = try await send(Self.translateEndpoint, body: body)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = obj["data"] as? [String: Any],
              let translations = dataObj["translations"] as? [[String: Any]] else {
            throw GoogleError.badResponse("not JSON")
        }
        var result = TranslationResult()
        var overlayBuckets: [UUID: [Int: String]] = [:]
        for (target, translation) in zip(targets, translations) {
            guard let text = translation["translatedText"] as? String else { continue }
            switch target {
            case .message(let id): result.messages[id] = text
            case .overlay(let id, let index): overlayBuckets[id, default: [:]][index] = text
            }
        }
        for (id, bucket) in overlayBuckets {
            let count = (bucket.keys.max() ?? -1) + 1
            result.overlays[id] = (0..<count).map { bucket[$0] ?? "" }
        }
        return result
    }

    // MARK: - HTTP

    private func send(_ endpoint: URL, body: [String: Any]) async throws -> Data {
        guard !apiKey.isEmpty else { throw GoogleError.missingKey }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                let retryable = status == 408 || status == 429 || status >= 500
                if retryable && attempt < 4 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                throw GoogleError.http(status, Self.errorMessage(data))
            } catch let error as URLError where attempt < 4 && error.code != .cancelled {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
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
