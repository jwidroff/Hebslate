import SwiftUI

@main
struct HebslateApp: App {
    @State private var store = ConversationStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
        }
    }
}
