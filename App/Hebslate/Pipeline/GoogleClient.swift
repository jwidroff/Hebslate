import CoreGraphics
import Foundation
import HebslateCore

/// Thin Google Cloud client, authenticated with a plain API key (no OAuth or
/// service account needed). Used for two optional jobs, mirroring `ClaudeClient`:
///  * `readFrame` — Cloud Vision's DOCUMENT_TEXT_DETECTION finds the text lines,
///    which `BubbleLineAssembler` turns into messages using bubble colors, the
///    same way `VisionReader` does with Apple Vision's output;
///  * `translate` — Cloud Translation (v2) translates Hebrew to English.
///    Unlike Claude, this is a bare machine-translation endpoint: it has no
///    conversation context, so slang and ambiguous pronouns translate less
///    reliably than with Claude.
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
            case .missingKey: "Add your Google Cloud API key in Settings to use Google."
            case .http(403, let msg): "Google rejected the request (\(msg)). Check the API key and that the Cloud Vision and Cloud Translation APIs are enabled in Settings."
            case .http(let code, let msg): "Google API error \(code): \(msg)"
            case .badResponse(let s): "Unexpected response from Google: \(s)"
            }
        }
    }

    // MARK: - Frame reading (Cloud Vision)

    func readFrame(_ frame: KeyFrame) async throws -> FrameReading {
        guard let jpeg = ClaudeClient.jpegData(frame.image, maxHeight: 1600) else {
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
    /// words > symbols — but a paragraph can span several visual lines (a
    /// wrapped WhatsApp bubble is usually one paragraph with `LINE_BREAK`
    /// symbols inside it), unlike Apple Vision's one-observation-per-line
    /// output. Split each paragraph back into per-line (text, box) pairs at
    /// its `LINE_BREAK` symbols so `BubbleLineAssembler` sees the same
    /// per-visual-line granularity either reader produces.
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
                lines.append(contentsOf: visualLines(in: paragraph, width: width, height: height))
            }
        }
        return lines
    }

    /// Walks a paragraph's symbols, starting a new line at each `LINE_BREAK`,
    /// and computes each line's box from the union of its symbols' own boxes.
    private static func visualLines(in paragraph: [String: Any], width: Double, height: Double) -> [(text: String, box: NormRect)] {
        var result: [(text: String, box: NormRect)] = []
        var text = ""
        var xs: [Double] = [], ys: [Double] = []

        func flush() {
            defer { text = ""; xs = []; ys = [] }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            result.append((trimmed, NormRect(x: minX / width, y: minY / height, width: (maxX - minX) / width, height: (maxY - minY) / height)))
        }

        for word in (paragraph["words"] as? [[String: Any]]) ?? [] {
            for symbol in (word["symbols"] as? [[String: Any]]) ?? [] {
                text += (symbol["text"] as? String) ?? ""
                for v in ((symbol["boundingBox"] as? [String: Any])?["vertices"] as? [[String: Any]]) ?? [] {
                    if let x = (v["x"] as? NSNumber)?.doubleValue { xs.append(x) }
                    if let y = (v["y"] as? NSNumber)?.doubleValue { ys.append(y) }
                }
                switch (((symbol["property"] as? [String: Any])?["detectedBreak"] as? [String: Any])?["type"] as? String) ?? "" {
                case "LINE_BREAK": flush()
                case "SPACE", "EOL_SURE_SPACE": text += " "
                default: break
                }
            }
        }
        flush()
        return result
    }

    // MARK: - Translation (Cloud Translation v2)

    /// Translates `items`' original text into English. Returns no context to
    /// Google beyond the text itself (v2 is a bare translation endpoint).
    func translate(_ items: [ChatMessage]) async throws -> [UUID: String] {
        let pending = items.filter { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !pending.isEmpty else { return [:] }
        let body: [String: Any] = [
            "q": pending.map(\.original),
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
        var out: [UUID: String] = [:]
        for (item, translation) in zip(pending, translations) {
            if let text = translation["translatedText"] as? String { out[item.id] = text }
        }
        return out
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
}
