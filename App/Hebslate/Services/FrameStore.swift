import Foundation

/// Saves the key frames a translation job read, so the user can open them
/// later from a finished conversation to see why a reading went wrong.
/// Frames live in their own per-conversation folder (named by the
/// conversation's id), independent of the conversation's own JSON file.
enum FrameStore {
    struct Frame: Identifiable, Sendable {
        var id: Int
        var time: Double
        var url: URL
    }

    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func directory(for conversationID: UUID) -> URL {
        root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    /// Encodes and writes every frame; safe to call off the main actor.
    static func save(_ frames: [KeyFrame], for conversationID: UUID) {
        guard !frames.isEmpty else { return }
        let dir = directory(for: conversationID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for frame in frames {
            guard let data = GoogleClient.jpegData(frame.image, maxHeight: 1280) else { continue }
            let name = String(format: "%05d_%.3f.jpg", frame.index, frame.time)
            try? data.write(to: dir.appendingPathComponent(name))
        }
    }

    /// Lists the frames saved for a conversation, oldest first. Empty for a
    /// conversation translated before this feature existed, or if the app's
    /// data was cleared since.
    static func load(for conversationID: UUID) -> [Frame] {
        let dir = directory(for: conversationID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Frame? in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count == 2, let index = Int(parts[0]), let time = Double(parts[1]) else { return nil }
            return Frame(id: index, time: time, url: url)
        }.sorted { $0.id < $1.id }
    }

    static func delete(for conversationID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: conversationID))
    }
}
