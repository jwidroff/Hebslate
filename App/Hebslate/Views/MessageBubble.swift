import HebslateCore
import SwiftUI
import UIKit

/// WhatsApp's colors, light and dark.
enum ChatTheme {
    static let wallpaper = Color(light: 0xEFEAE2, dark: 0x0B141A)
    static let outgoing = Color(light: 0xD9FDD3, dark: 0x005C4B)
    static let incoming = Color(light: 0xFFFFFF, dark: 0x202C33)
    static let systemPill = Color(light: 0xFFFFFF, dark: 0x182229)
    static let metaText = Color(light: 0x667781, dark: 0x8696A0)
    static let primaryText = Color(light: 0x111B21, dark: 0xE9EDEF)
    static let accent = Color(light: 0x008069, dark: 0x00A884)
    static let warning = Color(light: 0xFFF3C4, dark: 0x3B3518)

    /// Stable color per group-chat sender, like WhatsApp's colored names.
    static func senderColor(_ name: String) -> Color {
        let palette: [UInt32] = [0x1FA855, 0xD3396D, 0x5E47DE, 0xE26A00, 0x0A7CC1, 0xA0522D, 0x00897B, 0xB0369F]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Color(hex: palette[hash % palette.count])
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Rounded chat bubble with WhatsApp's little tail on the first bubble of a run.
struct BubbleShape: Shape {
    var tail: HorizontalEdge?
    static let tailWidth: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 8, t = Self.tailWidth, th: CGFloat = 10
        var b = rect
        if tail == .leading { b.origin.x += t; b.size.width -= t }
        if tail == .trailing { b.size.width -= t }

        var p = Path()
        if tail == .leading {
            p.move(to: CGPoint(x: b.minX - t, y: b.minY))
        } else {
            p.move(to: CGPoint(x: b.minX + r, y: b.minY))
        }
        if tail == .trailing {
            p.addLine(to: CGPoint(x: b.maxX + t, y: b.minY))
            p.addLine(to: CGPoint(x: b.maxX, y: b.minY + th))
        } else {
            p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.maxY), radius: r)
        }
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.minY), radius: r)
        if tail == .leading {
            p.addLine(to: CGPoint(x: b.minX, y: b.minY + th))
        } else {
            p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY), radius: r)
        }
        p.closeSubpath()
        return p
    }
}

/// One row of the rebuilt conversation.
struct MessageRow: View {
    let message: ChatMessage
    let isFirstInRun: Bool
    let showOriginal: Bool
    let isGroupChat: Bool
    var onDelete: (() -> Void)?

    @State private var revealOriginal = false

    var body: some View {
        if message.isGapMarker {
            pill {
                Label("Some messages may be missing here — the chat scrolled too fast", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            .padding(.vertical, 6)
            .contextMenu { deleteButton }
        } else if message.side == .system {
            pill {
                Text(message.translation ?? message.original)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ChatTheme.metaText)
            }
            .padding(.vertical, 6)
            .contextMenu { deleteButton }
        } else {
            bubbleRow
        }
    }

    private var isOutgoing: Bool { message.side == .outgoing }

    private var bubbleRow: some View {
        HStack(spacing: 0) {
            if isOutgoing { Spacer(minLength: 56) }
            bubble
            if !isOutgoing { Spacer(minLength: 56) }
        }
        .padding(.top, isFirstInRun ? 6 : 1)
        .padding(.horizontal, isFirstInRun ? 0 : BubbleShape.tailWidth)
    }

    private var bubble: some View {
        let tail: HorizontalEdge? = isFirstInRun ? (isOutgoing ? .trailing : .leading) : nil
        let showHebrew = showOriginal || revealOriginal

        return VStack(alignment: .leading, spacing: 3) {
            if isGroupChat, !isOutgoing, isFirstInRun, let sender = message.sender {
                Text(sender)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(message.senderColor.map(Color.init) ?? ChatTheme.senderColor(sender))
            }

            if message.isImage, let image = message.uiImage {
                ImageWithOverlays(image: image, overlays: message.imageOverlays)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let english = message.translation {
                Text(decorated(english))
                    .foregroundStyle(ChatTheme.primaryText)
                    .textSelection(.enabled)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ProgressView().controlSize(.mini)
                    hebrew(message.original).foregroundStyle(ChatTheme.metaText)
                }
            }

            if showHebrew, !message.isImage, message.translation != nil {
                Divider().opacity(0.4)
                hebrew(message.original)
                    .font(.callout)
                    .foregroundStyle(ChatTheme.metaText)
            }

            if let time = message.time {
                Text(time)
                    .font(.caption2)
                    .foregroundStyle(ChatTheme.metaText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .padding(tail == .leading ? .leading : .trailing, tail == nil ? 0 : BubbleShape.tailWidth)
        .background(isOutgoing ? ChatTheme.outgoing : ChatTheme.incoming, in: BubbleShape(tail: tail))
        .shadow(color: .black.opacity(0.08), radius: 0.5, y: 1)
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture { withAnimation(.snappy) { revealOriginal.toggle() } }
        .contextMenu {
            if let english = message.translation {
                Button("Copy translation", systemImage: "doc.on.doc") { UIPasteboard.general.string = english }
            }
            Button("Copy Hebrew", systemImage: "character.bubble") { UIPasteboard.general.string = message.original }
            deleteButton
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        if let onDelete {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private func decorated(_ s: String) -> String {
        (message.cutOffTop ? "… " : "") + s + (message.cutOffBottom ? " …" : "")
    }

    private func hebrew(_ s: String) -> some View {
        Text(decorated(s))
            .multilineTextAlignment(.leading)
            .environment(\.layoutDirection, .rightToLeft)
            .textSelection(.enabled)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(message.isGapMarker ? ChatTheme.warning : ChatTheme.systemPill,
                        in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 1)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}

private extension ChatMessage {
    var uiImage: UIImage? { imageData.flatMap(UIImage.init(data:)) }
}

/// A photo message with each translated line in a solid white tag, placed
/// where the original Hebrew sat (`overlay.box`, normalized to the image).
private struct ImageWithOverlays: View {
    let image: UIImage
    let overlays: [ImageOverlay]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().scaledToFit()
                ForEach(Array(overlays.enumerated()), id: \.offset) { _, overlay in
                    tag(for: overlay, in: geo.size)
                }
            }
        }
        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
        .frame(maxWidth: 260)
    }

    private func tag(for overlay: ImageOverlay, in size: CGSize) -> some View {
        let width = overlay.box.width * size.width, height = overlay.box.height * size.height
        return Group {
            if let text = overlay.translation {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .frame(minWidth: width, minHeight: height)
                    .background(Color.white)
            } else {
                ProgressView().controlSize(.mini).frame(width: width, height: height)
            }
        }
        .position(x: (overlay.box.x + overlay.box.width / 2) * size.width,
                  y: (overlay.box.y + overlay.box.height / 2) * size.height)
    }
}
