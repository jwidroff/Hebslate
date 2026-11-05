import SwiftUI

/// Shows the key frames a translation was read from, so if a message looks
/// wrong, scrambled or missing, the user can check what the recording
/// actually showed at that point.
struct FramesView: View {
    let conversationID: UUID

    @State private var frames: [FrameStore.Frame] = []
    @State private var selected: FrameStore.Frame?

    var body: some View {
        Group {
            if frames.isEmpty {
                ContentUnavailableView(
                    "No Frames Saved",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Frames aren't kept for translations made before this feature, or if app data was cleared since.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(frames) { frame in
                            Button { selected = frame } label: { thumbnail(frame) }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .navigationTitle("Frames Used")
        .navigationBarTitleDisplayMode(.inline)
        .task { frames = FrameStore.load(for: conversationID) }
        .fullScreenCover(item: $selected) { frame in
            FrameDetailView(frames: frames, initial: frame)
        }
    }

    private func thumbnail(_ frame: FrameStore.Frame) -> some View {
        VStack(spacing: 3) {
            AsyncImage(url: frame.url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(height: 90)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(timeLabel(frame.time))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Full-screen, swipeable view of one frame at a time, starting at the one tapped.
private struct FrameDetailView: View {
    let frames: [FrameStore.Frame]
    let initial: FrameStore.Frame
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(frames.enumerated()), id: \.offset) { i, frame in
                    ZStack {
                        Color.black
                        AsyncImage(url: frame.url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { index = frames.firstIndex { $0.id == initial.id } ?? 0 }
    }

    private var title: String {
        guard frames.indices.contains(index) else { return "" }
        return "Frame \(frames[index].id) • \(timeLabel(frames[index].time))"
    }
}

private func timeLabel(_ seconds: Double) -> String {
    let m = Int(seconds) / 60, s = Int(seconds) % 60
    return String(format: "%d:%02d", m, s)
}
