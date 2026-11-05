import CoreGraphics
import Foundation
import HebslateCore
import Vision

/// Reads a WhatsApp frame on-device with Apple Vision. Hebrew support depends
/// on the iOS version, so it is checked at runtime.
struct VisionReader {
    var layout: LineGrouper.Layout

    /// Hebrew recognition depends on the iOS version, so check at runtime.
    static var hebrewLanguageCode: String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return supported.first { $0.hasPrefix("he") || $0.hasPrefix("iw") }
    }

    static var supportsHebrew: Bool { hebrewLanguageCode != nil }

    enum ReadError: LocalizedError {
        case hebrewUnsupported
        var errorDescription: String? {
            "Apple's on-device text recognition can't read Hebrew on this iPhone. Choose Google or Claude as the reader in Settings."
        }
    }

    func read(_ frame: KeyFrame) throws -> FrameReading {
        guard let hebrew = Self.hebrewLanguageCode else { throw ReadError.hebrewUnsupported }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [hebrew, "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])

        let lines: [RawTextLine] = (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox   // normalized, origin bottom-left
            return RawTextLine(text: candidate.string, box: NormRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        return BubbleAnalyzer(layout: layout).reading(from: lines, frame: frame)
    }
}

/// A line of text and where it is on the frame, from any OCR engine.
struct RawTextLine: Sendable {
    var text: String
    /// Normalized to the frame, origin top-left.
    var box: NormRect
}

/// Turns OCR lines (from Apple Vision or Google Cloud Vision) into a frame's
/// chat messages. The pixel colors around each line tell us which bubble
/// (incoming / outgoing / system) it belongs to and where one bubble ends and
/// the next begins.
struct BubbleAnalyzer {
    var layout: LineGrouper.Layout

    func reading(from raw: [RawTextLine], frame: KeyFrame) -> FrameReading {
        let bitmap = Bitmap(frame.image)
        var lines: [OCRLine] = raw.map { line in
            OCRLine(text: line.text, box: line.box, bubbleColor: bitmap.flatMap { bubbleColor(around: line.box, in: $0) })
        }
        lines.sort { $0.box.minY < $1.box.minY }

        // Ask the pixels whether consecutive lines share a bubble.
        if let bitmap {
            for i in lines.indices.dropFirst() {
                lines[i].sameBubbleAsPrevious = sameBubble(lines[i - 1], lines[i], in: bitmap)
            }
        }

        // Frames that don't look like a WhatsApp chat (Control Center at the
        // start of a recording, the home screen, ...) are ignored.
        let chatLines = lines.filter { $0.box.midY > layout.chatTop && $0.box.midY < layout.chatBottom }
        let bubbleLines = chatLines.filter { $0.bubbleColor?.isWhatsAppBubble ?? true }
        guard !chatLines.isEmpty, Double(bubbleLines.count) / Double(chatLines.count) >= 0.5 else {
            return FrameReading(frameIndex: frame.index, timestamp: frame.time, messages: [])
        }

        let (name, messages) = LineGrouper(layout: layout).group(lines)
        return FrameReading(frameIndex: frame.index, timestamp: frame.time, contactName: name, messages: messages)
    }

    // MARK: - Pixel heuristics

    /// Samples the bubble color just left and right of the text (inside the
    /// bubble's padding) and prefers whichever looks like a WhatsApp bubble.
    private func bubbleColor(around box: NormRect, in bitmap: Bitmap) -> RGB? {
        let inset = 0.012
        let samples = [
            bitmap.color(x: box.minX - inset, y: box.midY),
            bitmap.color(x: box.maxX + inset, y: box.midY),
            bitmap.color(x: box.minX - inset, y: box.minY),
            bitmap.color(x: box.maxX + inset, y: box.maxY),
        ].compactMap { $0 }
        if let green = samples.first(where: \.isWhatsAppGreen) { return green }
        return samples.first(where: \.isWhatsAppBubble) ?? samples.first
    }

    /// Walks down the gap between two lines; if every pixel stays bubble
    /// colored, both lines are in the same bubble.
    private func sameBubble(_ a: OCRLine, _ b: OCRLine, in bitmap: Bitmap) -> Bool? {
        guard let color = b.bubbleColor else { return nil }
        let left = max(a.box.minX, b.box.minX), right = min(a.box.maxX, b.box.maxX)
        guard right > left else { return a.box.maxY >= b.box.minY ? true : nil }
        let x = left - 0.008 < 0 ? left : left - 0.008
        let top = a.box.maxY, bottom = b.box.minY
        guard bottom > top else { return true }
        let steps = max(3, Int((bottom - top) * Double(bitmap.height) / 2))
        for s in 0...steps {
            let y = top + (bottom - top) * Double(s) / Double(steps)
            guard let c = bitmap.color(x: x, y: y) else { return nil }
            if c.distance(to: color) > 30 { return false }
        }
        return true
    }
}

/// RGBA8 copy of a frame for fast color sampling.
struct Bitmap {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        data = buffer
    }

    /// Color at normalized coordinates (origin top-left).
    func color(x: Double, y: Double) -> RGB? {
        let px = Int(x * Double(width)), py = Int(y * Double(height))
        guard px >= 0, py >= 0, px < width, py < height else { return nil }
        let i = (py * width + px) * 4
        return RGB(Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
    }
}
