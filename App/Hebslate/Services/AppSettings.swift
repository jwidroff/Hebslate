import Foundation
import HebslateCore

/// Which engine reads the text out of each frame.
enum ReaderEngine: String, CaseIterable, Identifiable, Codable {
    case auto, onDevice, google, claude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .onDevice: "On-device (Apple Vision)"
        case .google: "Google Cloud Vision"
        case .claude: "Claude (cloud)"
        }
    }
}

/// Which engine translates Hebrew to English.
enum TranslatorEngine: String, CaseIterable, Identifiable, Codable {
    case auto, apple, google, claude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .apple: "Apple Translate (on-device)"
        case .google: "Google Translate"
        case .claude: "Claude (cloud)"
        }
    }
}

/// UserDefaults keys shared between `@AppStorage` in views and the pipeline.
enum SettingsKey {
    static let reader = "reader"
    static let translator = "translator"
    static let model = "claudeModel"
    static let keepFraction = "keepFraction"
    static let chatTop = "chatTop"
    static let chatBottom = "chatBottom"
    static let outgoingOnRight = "outgoingOnRight"
    static let showOriginal = "showOriginal"
}

enum ClaudeModels {
    static let all: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (best quality)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (faster, cheaper)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (fastest, cheapest)"),
    ]
    static let `default` = "claude-opus-5-5"
}

/// Read-only snapshot of the settings, taken when a job starts.
struct SettingsSnapshot: Sendable {
    var reader: ReaderEngine
    var translator: TranslatorEngine
    var model: String
    var apiKey: String?
    var googleKey: String?
    var keepFraction: Double
    var layout: LineGrouper.Layout

    static func current(_ d: UserDefaults = .standard) -> SettingsSnapshot {
        var layout = LineGrouper.Layout()
        if d.object(forKey: SettingsKey.chatTop) != nil { layout.chatTop = d.double(forKey: SettingsKey.chatTop) }
        if d.object(forKey: SettingsKey.chatBottom) != nil { layout.chatBottom = d.double(forKey: SettingsKey.chatBottom) }
        if d.object(forKey: SettingsKey.outgoingOnRight) != nil { layout.outgoingOnRight = d.bool(forKey: SettingsKey.outgoingOnRight) }
        // A key typed in Settings overrides the one built into the app.
        let key = nonEmpty(KeychainStore.read(KeychainStore.claudeAPIKey)) ?? BuiltInKeys.claude
        let googleKey = nonEmpty(KeychainStore.read(KeychainStore.googleAPIKey)) ?? BuiltInKeys.google
        return SettingsSnapshot(
            reader: ReaderEngine(rawValue: d.string(forKey: SettingsKey.reader) ?? "") ?? .auto,
            translator: TranslatorEngine(rawValue: d.string(forKey: SettingsKey.translator) ?? "") ?? .auto,
            model: d.string(forKey: SettingsKey.model) ?? ClaudeModels.default,
            apiKey: key,
            googleKey: googleKey,
            keepFraction: d.object(forKey: SettingsKey.keepFraction) == nil ? 0.45 : d.double(forKey: SettingsKey.keepFraction),
            layout: layout
        )
    }
}

/// API keys compiled into the app from Config/Secrets.xcconfig (via Info.plist).
enum BuiltInKeys {
    static var google: String? { value("GoogleAPIKey") }
    static var claude: String? { value("ClaudeAPIKey") }

    private static func value(_ key: String) -> String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: key) as? String)
    }
}

private func nonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
          !t.hasPrefix("$(") else { return nil }
    return t
}
