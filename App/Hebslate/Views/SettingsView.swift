import HebslateCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.keepFraction) private var keepFraction = 0.45
    @AppStorage(SettingsKey.chatTop) private var chatTop = LineGrouper.Layout().chatTop
    @AppStorage(SettingsKey.chatBottom) private var chatBottom = LineGrouper.Layout().chatBottom
    @AppStorage(SettingsKey.outgoingOnRight) private var outgoingOnRight = true
    @AppStorage(SettingsKey.showOriginal) private var showOriginal = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Read a new frame every \(Int(keepFraction * 100))% of a screen")
                    Slider(value: $keepFraction, in: 0.25...0.7, step: 0.05)
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Lower values read more frames: slower and costlier, but more forgiving if you scrolled quickly.")
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
                Text("WhatsApp layout")
            } footer: {
                Text("Only needed if reading picks up the contact header or the typing bar as messages. Bubble colors are used to tell your messages from theirs; the side setting is a fallback.")
            }

            Section("Display") {
                Toggle("Show Hebrew under each translation", isOn: $showOriginal)
            }
        }
        .navigationTitle("Settings")
    }
}
