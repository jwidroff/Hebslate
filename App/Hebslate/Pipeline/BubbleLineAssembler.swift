import CoreGraphics
import Foundation
import HebslateCore

/// Turns raw OCR lines (text + normalized box) from Cloud Vision into a
/// `FrameReading`, using the pixel colors around each line to tell bubbles
/// apart, and to tell a plain text bubble from a photo with Hebrew text
/// baked into it.
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
        // start of a recording, the home screen, ...) are ignored. A photo
        // bubble full of text (a meme, a screenshot) sits on busy pixels
        // rather than a flat WhatsApp color, so this only requires *some*
        // recognizable bubble-colored text, not a majority of it.
        let chatLines = lines.filter { $0.box.midY > layout.chatTop && $0.box.midY < layout.chatBottom }
        let bubbleLines = chatLines.filter { $0.bubbleColor?.isWhatsAppBubble ?? true }
        guard !chatLines.isEmpty, !bubbleLines.isEmpty,
              Double(bubbleLines.count) / Double(chatLines.count) >= 0.25 else {
            return FrameReading(frameIndex: frame.index, timestamp: frame.time, messages: [])
        }

        let (name, messages, groups) = LineGrouper(layout: layout).group(lines)
        let finalMessages = zip(messages, groups).map { message, group -> FrameMessage in
            var message = message
            var group = group
            if let bitmap, let sender = detectSender(message: message, group: group, bitmap: bitmap) {
                message.sender = sender.name
                message.senderColor = sender.color
                message.text = sender.bodyText
                group = Array(group.dropFirst())
            }
            guard message.side != .system, !group.isEmpty, looksLikeImage(group) else { return message }
            message.text = "[IMAGE HERE]"
            return message
        }
        return FrameReading(frameIndex: frame.index, timestamp: frame.time, contactName: name, messages: finalMessages)
    }

    // MARK: - Sender names (group chats)

    /// In a group chat, WhatsApp prints the sender's name above an incoming
    /// bubble's text, in a color distinct from the message body. Cloud
    /// Vision normally reports it as its own paragraph (the color change
    /// starts a new one), so it shows up as the group's first line.
    private func detectSender(message: FrameMessage, group: [OCRLine], bitmap: Bitmap) -> (name: String, color: RGB?, bodyText: String)? {
        guard message.side == .incoming, group.count > 1, let first = group.first,
              !LineGrouper.isTimeOnly(first.text) else { return nil }
        let name = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), name.count <= 40 else { return nil }

        let rest = Array(group.dropFirst())
        let body = bodyText(rest)
        guard !body.isEmpty else { return nil }

        guard let nameColor = textColor(in: first.box, background: first.bubbleColor, in: bitmap),
              let bodyColor = rest.lazy.compactMap({ textColor(in: $0.box, background: $0.bubbleColor, in: bitmap) }).first,
              nameColor.distance(to: bodyColor) > 40 else { return nil }

        return (name, nameColor, body)
    }

    /// Re-joins OCR lines into message text the same way `LineGrouper`
    /// does (strip a trailing time stamp off the last line), for use after
    /// peeling a detected sender-name line off the front of a group.
    private func bodyText(_ lines: [OCRLine]) -> String {
        var texts = lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let last = texts.last {
            let (stripped, _) = LineGrouper.extractTime(from: last)
            if stripped.isEmpty { texts.removeLast() } else { texts[texts.count - 1] = stripped }
        }
        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Estimates the color of the glyphs themselves (not the bubble behind
    /// them) by sampling a grid inside the line's box, discarding samples
    /// close to the background, and taking the median of what's left by
    /// luminance (more resistant to anti-aliased edge pixels than a mean).
    private func textColor(in box: NormRect, background: RGB?, in bitmap: Bitmap) -> RGB? {
        var ink: [RGB] = []
        let cols = 14, rows = 5
        for r in 0...rows {
            for c in 0...cols {
                let x = box.minX + box.width * Double(c) / Double(cols)
                let y = box.minY + box.height * Double(r) / Double(rows)
                guard let color = bitmap.color(x: x, y: y) else { continue }
                if let background, color.distance(to: background) < 45 { continue }
                ink.append(color)
            }
        }
        guard ink.count >= 3 else { return nil }
        let sorted = ink.sorted { $0.r + $0.g + $0.b < $1.r + $1.g + $1.b }
        return sorted[sorted.count / 2]
    }

    // MARK: - Image bubbles

    /// True when most of a bubble's lines sit on pixels that don't match any
    /// known WhatsApp bubble color — i.e. the text is baked into a photo
    /// rather than printed on a flat chat bubble. Such bubbles are shown as
    /// "[IMAGE HERE]" rather than translated, since reading text out of a
    /// photo (memes, screenshots) is unreliable and not what the OCR here is
    /// tuned for.
    private func looksLikeImage(_ group: [OCRLine]) -> Bool {
        let known = group.compactMap(\.bubbleColor)
        guard !known.isEmpty else { return false }
        let offBubble = known.filter { !$0.isWhatsAppBubble }.count
        return Double(offBubble) / Double(known.count) > 0.5
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
