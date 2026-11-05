import Foundation
import HebslateCore

/// Google Cloud Vision (reads Hebrew text out of frames) and Google Cloud
/// Translation (Hebrew → English), both with one API key.
///
/// The key needs the "Cloud Vision API" and/or "Cloud Translation API" enabled
/// in its Google Cloud project. Requests send the app's bundle identifier, so
/// the key can be restricted to this iOS app in the Google Cloud console.
struct GoogleCloudClient {
    var apiKey: String

    enum GoogleError: LocalizedError {
        case missingKey
        case api(Int, String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                "Add your Google Cloud API key in Settings to use Google."
            case .api(let code, let message):
                "Google Cloud error \(code): \(message)"
            case .badResponse(let s):
                "Unexpected response from Google: \(s)"
            }
        }
    }

    // MARK: - Cloud Vision: text recognition

    private struct AnnotateResponse: Decodable {
        struct Response: Decodable {
            var fullTextAnnotation: FullText?
            var error: Status?
        }
        struct Status: Decodable { var code: Int?; var message: String? }
        struct FullText: Decodable { var pages: [Page]? }
        struct Page: Decodable { var width: Int?; var height: Int?; var blocks: [Block]? }
        struct Block: Decodable { var paragraphs: [Paragraph]? }
        struct Paragraph: Decodable { var words: [Word]? }
        struct Word: Decodable { var boundingBox: Poly?; var symbols: [Symbol]? }
        struct Poly: Decodable { var vertices: [Vertex]? }
        /// Google omits a coordinate when it is 0.
        struct Vertex: Decodable { var x: Int?; var y: Int? }
        struct Symbol: Decodable { var text: String?; var property: Property? }
        struct Property: Decodable { var detectedBreak: Break? }
        struct Break: Decodable { var type: String? }
        var responses: [Response]?
    }

    /// Reads a frame with Cloud Vision's document text detection and turns the
    /// result into chat messages using the same bubble analysis as on-device.
    func readFrame(_ frame: KeyFrame, layout: LineGrouper.Layout) async throws -> FrameReading {
        guard let jpeg = ClaudeClient.jpegData(frame.image, maxHeight: 2000) else {
            throw GoogleError.badResponse("could not encode frame")
        }
        let body: [String: Any] = [
            "requests": [[
                "image": ["content": jpeg.base64EncodedString()],
                "features": [["type": "DOCUMENT_TEXT_DETECTION"]],
                "imageContext": ["languageHints": ["he", "en"]],
            ]],
        ]
        let data = try await post("https://vision.googleapis.com/v1/images:annotate", body: body)
        let decoded = try JSONDecoder().decode(AnnotateResponse.self, from: data)
        guard let response = decoded.responses?.first else { throw GoogleError.badResponse("no responses") }
        if let error = response.error, let message = error.message {
            throw GoogleError.api(error.code ?? 0, message)
        }

        var lines: [RawTextLine] = []
        for page in response.fullTextAnnotation?.pages ?? [] {
            let w = Double(page.width ?? frame.image.width), h = Double(page.height ?? frame.image.height)
            guard w > 0, h > 0 else { continue }
            for block in page.blocks ?? [] {
                for paragraph in block.paragraphs ?? [] {
                    lines += Self.lines(in: paragraph, width: w, height: h)
                }
            }
        }
        return BubbleAnalyzer(layout: layout).reading(from: lines, frame: frame)
    }

    /// Rebuilds visual lines from a paragraph's words, using the line breaks
    /// Google detects after symbols.
    private static func lines(in paragraph: AnnotateResponse.Paragraph, width: Double, height: Double) -> [RawTextLine] {
        var result: [RawTextLine] = []
        var text = ""
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity

        func endLine() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, minX.isFinite {
                result.append(RawTextLine(text: trimmed, box: NormRect(x: minX / width, y: minY / height,
                                                                       width: (maxX - minX) / width,
                                                                       height: (maxY - minY) / height)))
            }
            text = ""
            minX = .infinity; minY = .infinity; maxX = -.infinity; maxY = -.infinity
        }

        for word in paragraph.words ?? [] {
            for v in word.boundingBox?.vertices ?? [] {
                let x = Double(v.x ?? 0), y = Double(v.y ?? 0)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            var lineEnds = false
            for symbol in word.symbols ?? [] {
                text += symbol.text ?? ""
                switch symbol.property?.detectedBreak?.type {
                case "SPACE", "SURE_SPACE": text += " "
                case "EOL_SURE_SPACE", "LINE_BREAK": lineEnds = true
                case "HYPHEN": text += "-"; lineEnds = true
                default: break
                }
            }
            if lineEnds { endLine() }
        }
        endLine()
        return result
    }

    // MARK: - Cloud Translation

    private struct TranslateResponse: Decodable {
        struct DataBlock: Decodable { var translations: [Item] }
        struct Item: Decodable { var translatedText: String }
        var data: DataBlock
    }

    /// Translates the messages from Hebrew to English (Basic / v2 API).
    func translate(_ items: [ChatMessage]) async throws -> [UUID: String] {
        var out: [UUID: String] = [:]
        // The API takes up to 128 strings per request.
        for start in stride(from: 0, to: items.count, by: 100) {
            let chunk = Array(items[start..<min(start + 100, items.count)])
            let body: [String: Any] = [
                "q": chunk.map(\.original),
                "source": "he",
                "target": "en",
                "format": "text",
            ]
            let data = try await post("https://translation.googleapis.com/language/translate/v2", body: body)
            let decoded = try JSONDecoder().decode(TranslateResponse.self, from: data)
            guard decoded.data.translations.count == chunk.count else {
                throw GoogleError.badResponse("expected \(chunk.count) translations, got \(decoded.data.translations.count)")
            }
            for (message, t) in zip(chunk, decoded.data.translations) { out[message.id] = t.translatedText }
        }
        return out
    }

    // MARK: - HTTP

    private func post(_ endpoint: String, body: [String: Any]) async throws -> Data {
        guard !apiKey.isEmpty else { throw GoogleError.missingKey }
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                if (status == 429 || status >= 500) && attempt < 4 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                throw GoogleError.api(status, Self.errorMessage(data))
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
