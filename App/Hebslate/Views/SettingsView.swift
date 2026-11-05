import HebslateCore
import SwiftUI
import Translation

struct SettingsView: View {
    @AppStorage(SettingsKey.reader) private var reader: ReaderEngine = .auto
    @AppStorage(SettingsKey.translator) private var translator: TranslatorEngine = .auto
    @AppStorage(SettingsKey.model) private var model = ClaudeModels.default
    @AppStorage(SettingsKey.keepFraction) private var keepFraction = 0.45
    @AppStorage(SettingsKey.chatTop) private var chatTop = LineGrouper.Layout().chatTop
    @AppStorage(SettingsKey.chatBottom) private var chatBottom = LineGrouper.Layout().chatBottom
    @AppStorage(SettingsKey.outgoingOnRight) private var outgoingOnRight = true
    @AppStorage(SettingsKey.showOriginal) private var showOriginal = false

    @State private var apiKey = KeychainStore.read(KeychainStore.claudeAPIKey) ?? ""
    @State private var googleApiKey = KeychainStore.read(KeychainStore.googleAPIKey) ?? ""
    @State private var visionHebrew = VisionReader.supportsHebrew
    @State private var appleStatus: LanguageAvailability.Status?

    var body: some View {
        Form {
            Section {
                Picker("Read text with", selection: $reader) {
                    ForEach(ReaderEngine.allCases) { Text($0.label).tag($0) }
                }
                Picker("Translate with", selection: $translator) {
                    ForEach(TranslatorEngine.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("On-device Hebrew reading") {
                    status(visionHebrew ? "Available" : "Not on this iOS", ok: visionHebrew)
                }
                LabeledContent("Apple Translate Hebrew → English") {
                    switch appleStatus {
                    case .installed: status("Ready", ok: true)
                    case .supported: status("Downloads on first use", ok: true)
                    case .unsupported: status("Not available", ok: false)
                    default: ProgressView()
                    }
                }
            } header: {
                Text("Engines")
            } footer: {
                Text("Automatic reads on-device when this iPhone supports Hebrew text recognition, otherwise Claude if a key is set, otherwise Google if a key is set. It translates with Claude when a key is set (better with slang and context), otherwise Apple Translate on-device when supported, otherwise Google.")
            }

            Section {
                SecureField("sk-ant-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, value in
                        KeychainStore.write(value.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainStore.claudeAPIKey)
                    }
                Picker("Model", selection: $model) {
                    ForEach(ClaudeModels.all, id: \.id) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("Claude (optional)")
            } footer: {
                Text(DefaultAPIKeys.claude == nil
                     ? "Create an API key at console.anthropic.com. It is stored in the iOS Keychain on this device only. Frames and text are sent to Anthropic only when a Claude engine is in use."
                     : "A default key is built into this app and used whenever this field is left blank. Paste a key here to override it. Stored in the iOS Keychain on this device only.")
            }

            Section {
                SecureField("API key", text: $googleApiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: googleApiKey) { _, value in
                        KeychainStore.write(value.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainStore.googleAPIKey)
                    }
            } header: {
                Text("Google Cloud (optional)")
            } footer: {
                Text((DefaultAPIKeys.google == nil ? "" : "A default key is built into this app and used whenever this field is left blank. Paste a key here to override it. ") + "Create an API key in Google Cloud Console with the Cloud Vision API and Cloud Translation API enabled. It is stored in the iOS Keychain on this device only. Frames and text are sent to Google only when a Google engine is in use. Google Translate has no conversation context, so slang translates less reliably than with Claude.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Read a new frame every \(Int(keepFraction * 100))% of a screen")
                    Slider(value: $keepFraction, in: 0.25...0.7, step: 0.05)
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Lower values read more frames: slower and costlier with Claude, but more forgiving if you scrolled quickly.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Chat area starts at \(Int(chatTop * 100))% from the top")
                    Slider(value: $chatTop, in: 0.05...0.25, step: 0.005)
                }
                VStack(alignment: .leading) {
                    Text("Chat area ends at \(Int(chatBottom * 100))% from the top")
                    Slider(value: $chatBottom, in: 0.75...0.98, step: 0.005)
                }
                Toggle("My messages are on the right", isOn: $outgoingOnRight)
                Button("Reset layout") {
                    let d = LineGrouper.Layout()
                    chatTop = d.chatTop; chatBottom = d.chatBottom; outgoingOnRight = d.outgoingOnRight
                }
            } header: {
                Text("WhatsApp layout (on-device reader)")
            } footer: {
                Text("Only needed if on-device reading picks up the contact header or the typing bar as messages. Bubble colors are used to tell your messages from theirs; the side setting is a fallback.")
            }

            Section("Display") {
                Toggle("Show Hebrew under each translation", isOn: $showOriginal)
            }
        }
        .navigationTitle("Settings")
        .task {
            appleStatus = await LanguageAvailability().status(from: Locale.Language(identifier: "he"), to: Locale.Language(identifier: "en"))
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(ok ? .green : .secondary)
            .font(.subheadline)
    }
}
