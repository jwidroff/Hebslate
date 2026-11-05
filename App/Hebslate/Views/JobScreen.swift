import HebslateCore
import SwiftUI
import Translation

/// Shows the conversation being rebuilt live while the recording is processed.
struct JobScreen: View {
    let job: TranslationJob
    @State private var appleConfig: TranslationSession.Configuration?
    @State private var noticeDismissed = false

    var body: some View {
        ConversationView(conversation: job.conversation,
                         onDelete: job.phase == .finished ? { (m: ChatMessage) in job.delete(m) } : nil)
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .translationTask(appleConfig) { session in
                await job.translateWithApple(session)
            }
            .onChange(of: job.phase, initial: true) { _, phase in
                if phase == .awaitingAppleTranslation && appleConfig == nil {
                    appleConfig = TranslationSession.Configuration(source: Locale.Language(identifier: "he"),
                                                                   target: Locale.Language(identifier: "en"))
                }
            }
            .onAppear { job.start() }
            .onDisappear { if job.phase.isRunning { job.cancel() } }
    }

    @ViewBuilder
    private var banner: some View {
        switch job.phase {
        case .extracting(let p):
            StatusBanner(title: "Finding the frames that show new messages…", progress: p, onCancel: job.cancel)
        case .reading(let done, let total):
            StatusBanner(title: "Reading messages — frame \(done) of \(total)",
                         progress: total == 0 ? nil : Double(done) / Double(total), onCancel: job.cancel)
        case .translating(let done, let total):
            StatusBanner(title: "Translating \(total) new lines…",
                         progress: total == 0 ? nil : Double(done) / Double(total), onCancel: job.cancel)
        case .awaitingAppleTranslation:
            StatusBanner(title: "Preparing Apple Translate…", progress: nil, onCancel: job.cancel)
        case .failed(let message):
            StatusBanner(title: message, isError: true)
        case .finished:
            if let notice = job.notice, !noticeDismissed {
                StatusBanner(title: notice, isWarning: true) { noticeDismissed = true }
            }
        }
    }
}

struct StatusBanner: View {
    let title: String
    var progress: Double?
    var isError = false
    var isWarning = false
    var onCancel: (() -> Void)?

    init(title: String, progress: Double? = nil, isError: Bool = false, isWarning: Bool = false, onCancel: (() -> Void)? = nil) {
        self.title = title
        self.progress = progress
        self.isError = isError
        self.isWarning = isWarning
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if isError {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                } else if isWarning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let onCancel {
                    Button(isWarning ? "OK" : "Cancel", action: onCancel).font(.subheadline.weight(.semibold))
                }
            }
            if let progress {
                ProgressView(value: progress).tint(ChatTheme.accent)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}
