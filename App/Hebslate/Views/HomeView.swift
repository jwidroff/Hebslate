import HebslateCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(ConversationStore.self) private var store
    @State private var pickedItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var job: TranslationJob?
    @State private var isLoadingVideo = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section { hero }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                Section("How to record a chat") {
                    Step(number: 1, text: "Add **Screen Recording** to Control Center (Settings › Control Center).")
                    Step(number: 2, text: "Open the WhatsApp chat and scroll to where you want to start.")
                    Step(number: 3, text: "Start recording, then scroll **slowly and steadily** through the conversation. Up or down both work.")
                    Step(number: 4, text: "Stop the recording and pick it here. Hebslate rebuilds the chat in English.")
                }

                if !store.conversations.isEmpty {
                    Section("Recent translations") {
                        ForEach(store.conversations) { conversation in
                            NavigationLink(value: conversation) { ConversationRow(conversation: conversation) }
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { store.conversations[$0] }
                            doomed.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Hebslate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(item: $job) { JobScreen(job: $0) }
            .navigationDestination(for: Conversation.self) { SavedConversationScreen(conversation: $0) }
            .overlay {
                if isLoadingVideo {
                    ProgressView("Loading recording…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await loadFromPhotos(item) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie]) { result in
                switch result {
                case .success(let url): importFile(url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("Couldn't open the recording", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .tint(ChatTheme.accent)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(ChatTheme.accent)
            Text("Translate a whole WhatsApp chat")
                .font(.title3.weight(.semibold))
            Text("Pick a screen recording of a Hebrew conversation. Hebslate reads every frame, removes the overlap, and rebuilds the full chat in English.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            PhotosPicker(selection: $pickedItem, matching: .videos, preferredItemEncoding: .current) {
                Label("Choose screen recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                showFileImporter = true
            } label: {
                Label("Import from Files", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 4)
    }

    // MARK: - Import

    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        isLoadingVideo = true
        defer { isLoadingVideo = false; pickedItem = nil }
        do {
            guard let file = try await item.loadTransferable(type: RecordingFile.self) else {
                errorMessage = "The selected item isn't a video."
                return
            }
            startJob(file.url, sourceAssetIdentifier: item.itemIdentifier)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            startJob(try RecordingFile.copyToTemp(url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startJob(_ url: URL, sourceAssetIdentifier: String? = nil) {
        job = TranslationJob(videoURL: url, sourceAssetIdentifier: sourceAssetIdentifier) { [store] conversation in
            store.save(conversation)
        }
    }
}

/// A screen recording copied out of the photo library into a temp file.
struct RecordingFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            RecordingFile(url: try copyToTemp(received.file))
        }
    }

    static func copyToTemp(_ source: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }
}

extension TranslationJob: Hashable {
    nonisolated static func == (a: TranslationJob, b: TranslationJob) -> Bool { a.id == b.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(ChatTheme.accent, in: Circle())
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: conversation.title, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(conversation.createdAt, format: .dateTime.day().month(.abbreviated))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        let last = conversation.messages.last { !$0.isGapMarker && $0.side != .system }
        return last.map { ($0.side == .outgoing ? "You: " : "") + ($0.translation ?? $0.original) } ?? "No messages"
    }
}

/// A conversation translated earlier, loaded from disk.
struct SavedConversationScreen: View {
    @Environment(ConversationStore.self) private var store
    @State var conversation: Conversation

    var body: some View {
        ConversationView(conversation: conversation,
                          onDelete: { message in
                              conversation.messages.removeAll { $0.id == message.id }
                              store.save(conversation)
                          },
                          onSourceDeleted: {
                              conversation.sourceAssetIdentifier = nil
                              store.save(conversation)
                          })
    }
}
