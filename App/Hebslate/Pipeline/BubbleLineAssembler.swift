import CoreGraphics
import Foundation
import HebslateCore

/// Turns raw OCR lines (text + normalized box) from Cloud Vision into a
/// `FrameReading`, using the pixel colors around each line to tell bubbles
/// apart.
struct BubbleLineAssembler {
    var layout: LineGrouper.Layout

    func assemble(_ rawLines: [(text: String, box: NormRect)], frame: KeyFrame) -> FrameReading {
        let bitmap = Bitmap(frame.image)
        var lines: [OCRLine] = rawLines.map { raw in
            OCRLine(text: raw.text, box: raw.box, bubbleColor: bitmap.flatMap { bubbleColor(around: raw.box, in: $0) })
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
        let w = image.width
        let h = image.height
        width = w
        height = h
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
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
