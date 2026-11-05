import Foundation
import HebslateCore
import Observation

/// Runs the whole pipeline for one screen recording and publishes the
/// conversation as it is rebuilt, so the chat appears while it's processed:
///
///   video ─▶ key frames ─▶ read each frame ─▶ stitch (dedupe) ─▶ translate new lines
@MainActor
@Observable
final class TranslationJob: Identifiable {

    enum Phase: Equatable {
        case extracting(Double)
        case reading(done: Int, total: Int)
        case translating(done: Int, total: Int)
        case finished
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .finished, .failed: false
            default: true
            }
        }
    }

    let id = UUID()
    let videoURL: URL
    private(set) var phase: Phase = .extracting(0)
    private(set) var conversation: Conversation
    private(set) var framesUsed = 0
    private(set) var notice: String?

    private var stitcher = ConversationStitcher()
    private let settings: SettingsSnapshot
    private var task: Task<Void, Never>?
    private let onFinish: (Conversation) -> Void

    init(videoURL: URL, settings: SettingsSnapshot = .current(), onFinish: @escaping (Conversation) -> Void) {
        self.videoURL = videoURL
        self.settings = settings
        self.onFinish = onFinish
        self.conversation = Conversation(title: "Translating…", messages: [])
    }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        if phase.isRunning { phase = .failed("Cancelled") }
    }

    // MARK: - Pipeline

    private func run() async {
        do {
            guard let key = settings.googleApiKey, !key.isEmpty else { throw GoogleClient.GoogleError.missingKey }
            let client = GoogleClient(apiKey: key, layout: settings.layout)

            // 1. Key frames
            let extractor = FrameExtractor(keepFraction: settings.keepFraction, layout: settings.layout)
            let frames = try await extractor.keyFrames(from: videoURL) { p in
                Task { @MainActor [weak self] in
                    // Late progress updates must not overwrite a later phase.
                    guard let self, case .extracting = self.phase else { return }
                    self.phase = .extracting(p)
                }
            }
            framesUsed = frames.count
            guard !frames.isEmpty else { throw JobError.noFrames }

            // 2. Read + stitch, in order, publishing as we go.
            phase = .reading(done: 0, total: frames.count)
            try await readAll(frames, with: client)
            guard !stitcher.messages.isEmpty else { throw JobError.noMessages }

            // 3. Translate only what hasn't been translated yet.
            try await translate(with: client)
            finish()
        } catch is CancellationError {
            phase = .failed("Cancelled")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads frames with the cloud engine, up to 4 requests in flight, but
    /// stitches strictly in order.
    private func readAll(_ frames: [KeyFrame], with client: GoogleClient) async throws {
        var done = 0
        var results: [Int: FrameReading] = [:]
        var next = 0
        try await withThrowingTaskGroup(of: (Int, FrameReading).self) { group in
            var launched = 0
            while launched < min(4, frames.count) {
                let i = launched, frame = frames[i]
                group.addTask { (i, try await client.readFrame(frame)) }
                launched += 1
            }
            while let (i, reading) = try await group.next() {
                results[i] = reading
                while let r = results.removeValue(forKey: next) {
                    absorb(r)
                    next += 1
                }
                done += 1
                phase = .reading(done: done, total: frames.count)
                if launched < frames.count {
                    let li = launched, frame = frames[li]
                    group.addTask { (li, try await client.readFrame(frame)) }
                    launched += 1
                }
            }
        }
    }

    private func absorb(_ reading: FrameReading) {
        let result = stitcher.add(reading)
        if !result.foundOverlap && !stitcher.messages.isEmpty && reading.messages.count > 0 {
            notice = "Some parts scrolled by too fast to capture. Scroll a little slower next time."
        }
        publish()
    }

    private func publish() {
        conversation.messages = stitcher.messages
        conversation.title = stitcher.contactName ?? "WhatsApp chat"
    }

    private func finish() {
        publish()
        phase = .finished
        onFinish(conversation)
    }

    // MARK: - Translation

    private func translate(with client: GoogleClient) async throws {
        let pending = stitcher.untranslated
        var done = 0
        phase = .translating(done: 0, total: pending.count)

        for chunkStart in stride(from: 0, to: pending.count, by: 40) {
            try Task.checkCancellation()
            let chunk = Array(pending[chunkStart..<min(chunkStart + 40, pending.count)])
            let result = try await client.translate(chunk)
            stitcher.applyTranslations(result.messages)
            stitcher.applyOverlayTranslations(result.overlays)
            done += chunk.count
            phase = .translating(done: done, total: pending.count)
            publish()
        }
    }

    // MARK: - Editing

    func delete(_ message: ChatMessage) {
        stitcher.remove(id: message.id)
        publish()
        if phase == .finished { onFinish(conversation) }
    }

    enum JobError: LocalizedError {
        case noFrames, noMessages
        var errorDescription: String? {
            switch self {
            case .noFrames: "Couldn't read any frames from that video."
            case .noMessages: "No WhatsApp messages were found in the recording. Make sure the chat fills the screen while recording."
            }
        }
    }
}
