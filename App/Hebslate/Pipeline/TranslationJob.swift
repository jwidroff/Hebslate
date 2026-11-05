import Foundation
import HebslateCore
import Observation
import Translation

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
        /// Waiting for the view to hand us an Apple `TranslationSession`.
        case awaitingAppleTranslation
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
    private var translatorChoice: TranslatorEngine = .claude
    private let onFinish: (Conversation) -> Void

    init(videoURL: URL, settings: SettingsSnapshot = .current(), onFinish: @escaping (Conversation) -> Void) {
        self.videoURL = videoURL
        self.settings = settings
        self.onFinish = onFinish
        self.conversation = Conversation(title: "New translation", messages: [])
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
            let reader = try resolveReader()
            translatorChoice = try await resolveTranslator()

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
            try await readAll(frames, with: reader)
            guard !stitcher.messages.isEmpty else { throw JobError.noMessages }

            // 3. Translate only what hasn't been translated yet.
            switch translatorChoice {
            case .apple, .auto:
                phase = .awaitingAppleTranslation   // JobScreen hands us a TranslationSession
            case .claude:
                try await translateWithClaude()
                finish()
            case .google:
                try await translateWithGoogle()
                finish()
            }
        } catch is CancellationError {
            phase = .failed("Cancelled")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private enum Reader { case vision(VisionReader), google(GoogleCloudClient), claude(ClaudeClient) }

    private func resolveReader() throws -> Reader {
        switch settings.reader {
        case .onDevice:
            guard VisionReader.supportsHebrew else { throw VisionReader.ReadError.hebrewUnsupported }
            return .vision(VisionReader(layout: settings.layout))
        case .google:
            guard let key = settings.googleKey else { throw GoogleCloudClient.GoogleError.missingKey }
            return .google(GoogleCloudClient(apiKey: key))
        case .claude:
            guard let key = settings.apiKey else { throw ClaudeClient.ClaudeError.missingKey }
            return .claude(ClaudeClient(apiKey: key, model: settings.model))
        case .auto:
            if VisionReader.supportsHebrew { return .vision(VisionReader(layout: settings.layout)) }
            if let key = settings.googleKey { return .google(GoogleCloudClient(apiKey: key)) }
            if let key = settings.apiKey { return .claude(ClaudeClient(apiKey: key, model: settings.model)) }
            throw JobError.noReader
        }
    }

    private func resolveTranslator() async throws -> TranslatorEngine {
        let appleStatus = await LanguageAvailability().status(from: Locale.Language(identifier: "he"), to: Locale.Language(identifier: "en"))
        switch settings.translator {
        case .apple:
            guard appleStatus != .unsupported else { throw JobError.appleTranslationUnsupported }
            return .apple
        case .google:
            guard settings.googleKey != nil else { throw GoogleCloudClient.GoogleError.missingKey }
            return .google
        case .claude:
            guard settings.apiKey != nil else { throw ClaudeClient.ClaudeError.missingKey }
            return .claude
        case .auto:
            // Google when its key is set, then Claude (sees the whole
            // conversation, better with slang), then Apple on-device.
            if settings.googleKey != nil { return .google }
            if settings.apiKey != nil { return .claude }
            if appleStatus != .unsupported { return .apple }
            throw JobError.noTranslator
        }
    }

    private func readAll(_ frames: [KeyFrame], with reader: Reader) async throws {
        var done = 0
        switch reader {
        case .vision(let vision):
            for frame in frames {
                try Task.checkCancellation()
                let reading = try await Task.detached(priority: .userInitiated) { try vision.read(frame) }.value
                absorb(reading)
                done += 1
                phase = .reading(done: done, total: frames.count)
            }
        case .google(let client):
            let layout = settings.layout
            try await readInParallel(frames) { frame in try await client.readFrame(frame, layout: layout) }
        case .claude(let client):
            try await readInParallel(frames) { frame in try await client.readFrame(frame) }
        }
    }

    /// Reads up to 4 frames at once over the network, but stitches strictly in order.
    private func readInParallel(_ frames: [KeyFrame],
                                read: @escaping @Sendable (KeyFrame) async throws -> FrameReading) async throws {
        var done = 0
        var results: [Int: FrameReading] = [:]
        var next = 0
        try await withThrowingTaskGroup(of: (Int, FrameReading).self) { group in
            var launched = 0
            while launched < min(4, frames.count) {
                let i = launched, frame = frames[i]
                group.addTask { (i, try await read(frame)) }
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
                    group.addTask { (li, try await read(frame)) }
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

    private func translateWithClaude() async throws {
        guard let key = settings.apiKey else { throw ClaudeClient.ClaudeError.missingKey }
        let client = ClaudeClient(apiKey: key, model: settings.model)
        let pending = stitcher.untranslated
        var done = 0
        phase = .translating(done: 0, total: pending.count)

        for chunkStart in stride(from: 0, to: pending.count, by: 40) {
            try Task.checkCancellation()
            let chunk = Array(pending[chunkStart..<min(chunkStart + 40, pending.count)])
            // Give Claude the ~20 messages before this chunk as context.
            let firstIndex = stitcher.messages.firstIndex { $0.id == chunk[0].id } ?? 0
            let context = stitcher.messages[max(0, firstIndex - 20)..<firstIndex].filter { !$0.isGapMarker }
            let translations = try await client.translate(chunk, context: Array(context),
                                                          contactName: stitcher.contactName ?? "")
            stitcher.applyTranslations(translations)
            done += chunk.count
            phase = .translating(done: done, total: pending.count)
            publish()
        }
    }

    private func translateWithGoogle() async throws {
        guard let key = settings.googleKey else { throw GoogleCloudClient.GoogleError.missingKey }
        let client = GoogleCloudClient(apiKey: key)
        let pending = stitcher.untranslated
        phase = .translating(done: 0, total: pending.count)
        var done = 0
        for chunkStart in stride(from: 0, to: pending.count, by: 100) {
            try Task.checkCancellation()
            let chunk = Array(pending[chunkStart..<min(chunkStart + 100, pending.count)])
            stitcher.applyTranslations(try await client.translate(chunk))
            done += chunk.count
            phase = .translating(done: done, total: pending.count)
            publish()
        }
    }

    /// Called by the view from `.translationTask` once Apple's session is ready.
    func translateWithApple(_ session: TranslationSession) async {
        guard phase == .awaitingAppleTranslation else { return }
        let pending = stitcher.untranslated
        phase = .translating(done: 0, total: pending.count)
        do {
            try await session.prepareTranslation()   // prompts to download Hebrew if needed
            var done = 0
            for chunkStart in stride(from: 0, to: pending.count, by: 25) {
                let chunk = pending[chunkStart..<min(chunkStart + 25, pending.count)]
                let requests = chunk.map { TranslationSession.Request(sourceText: $0.original, clientIdentifier: $0.id.uuidString) }
                let responses = try await session.translations(from: requests)
                var map: [UUID: String] = [:]
                for r in responses {
                    if let idString = r.clientIdentifier, let id = UUID(uuidString: idString) { map[id] = r.targetText }
                }
                stitcher.applyTranslations(map)
                done += chunk.count
                phase = .translating(done: done, total: pending.count)
                publish()
            }
            finish()
        } catch {
            phase = .failed("Apple Translate failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Editing

    func delete(_ message: ChatMessage) {
        stitcher.remove(id: message.id)
        publish()
        if phase == .finished { onFinish(conversation) }
    }

    enum JobError: LocalizedError {
        case noFrames, noMessages, noReader, noTranslator, appleTranslationUnsupported
        var errorDescription: String? {
            switch self {
            case .noFrames: "Couldn't read any frames from that video."
            case .noMessages: "No WhatsApp messages were found in the recording. Make sure the chat fills the screen while recording."
            case .noReader: "Apple can't read Hebrew text on this iPhone. Add a Google Cloud (or Claude) API key in Settings to read the recording."
            case .noTranslator: "Apple Translate doesn't support Hebrew on this iPhone. Add a Google Cloud (or Claude) API key in Settings to translate."
            case .appleTranslationUnsupported: "Apple Translate doesn't support Hebrew → English on this iPhone. Switch the translator to Google or Claude in Settings."
            }
        }
    }
}
