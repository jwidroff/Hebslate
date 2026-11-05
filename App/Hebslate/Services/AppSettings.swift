import Foundation
import HebslateCore

/// UserDefaults keys shared between `@AppStorage` in views and the pipeline.
enum SettingsKey {
    static let keepFraction = "keepFraction"
    static let chatTop = "chatTop"
    static let chatBottom = "chatBottom"
    static let outgoingOnRight = "outgoingOnRight"
    static let showOriginal = "showOriginal"
}

/// Read-only snapshot of the settings, taken when a job starts.
struct SettingsSnapshot: Sendable {
    var googleApiKey: String?
    var keepFraction: Double
    var layout: LineGrouper.Layout

    static func current(_ d: UserDefaults = .standard) -> SettingsSnapshot {
        var layout = LineGrouper.Layout()
        if d.object(forKey: SettingsKey.chatTop) != nil { layout.chatTop = d.double(forKey: SettingsKey.chatTop) }
        if d.object(forKey: SettingsKey.chatBottom) != nil { layout.chatBottom = d.double(forKey: SettingsKey.chatBottom) }
        if d.object(forKey: SettingsKey.outgoingOnRight) != nil { layout.outgoingOnRight = d.bool(forKey: SettingsKey.outgoingOnRight) }
        return SettingsSnapshot(
            googleApiKey: DefaultAPIKeys.google,
            keepFraction: d.object(forKey: SettingsKey.keepFraction) == nil ? 0.45 : d.double(forKey: SettingsKey.keepFraction),
            layout: layout
        )
    }
}
