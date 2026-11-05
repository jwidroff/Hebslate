import HebslateCore
import SwiftUI

/// The rebuilt conversation, laid out like WhatsApp, with the translated text.
/// Scroll up and down through the whole chat; tap a bubble to see the Hebrew.
struct ConversationView: View {
    let conversation: Conversation
    var onDelete: ((ChatMessage) -> Void)?

    @AppStorage(SettingsKey.showOriginal) private var showOriginal = false
    @State private var showJumpButtons = false

    private var isGroupChat: Bool {
        Set(conversation.messages.compactMap(\.sender)).count > 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 1).id("top")
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(message: message,
                                   isFirstInRun: isFirstInRun(index),
                                   showOriginal: showOriginal,
                                   isGroupChat: isGroupChat,
                                   onDelete: onDelete.map { delete in { delete(message) } })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(ChatTheme.wallpaper)
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 10) {
                    jumpButton("chevron.up") { withAnimation { proxy.scrollTo("top", anchor: .top) } }
                    jumpButton("chevron.down") { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .padding(16)
                .opacity(conversation.messages.count > 12 ? 1 : 0)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showOriginal) { Label("Show Hebrew under translation", systemImage: "character.bubble") }
                    ShareLink(item: conversation.transcript(includeOriginal: showOriginal)) {
                        Label("Share translation", systemImage: "square.and.arrow.up")
                    }
                    Button("Copy translation", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = conversation.transcript(includeOriginal: showOriginal)
                    }
                    NavigationLink(value: FramesDestination(conversationID: conversation.id)) {
                        Label("View frames used", systemImage: "photo.on.rectangle.angled")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FramesDestination.self) { FramesView(conversationID: $0.conversationID) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Avatar(name: conversation.title, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title).font(.headline).lineLimit(1)
                Text("Translated from Hebrew").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func isFirstInRun(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        let prev = conversation.messages[index - 1], cur = conversation.messages[index]
        return prev.side != cur.side || prev.isGapMarker || prev.sender != cur.sender
    }

    private func jumpButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 2, y: 1)
        }
        .tint(ChatTheme.metaText)
    }
}

/// Navigation value for pushing `FramesView` from the conversation's menu.
struct FramesDestination: Hashable {
    let conversationID: UUID
}

/// Circle with the contact's initial, like a placeholder profile photo.
struct Avatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(ChatTheme.senderColor(name).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(name.first.map(String.init) ?? "?")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
