import SwiftUI

@main
struct SineApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}
