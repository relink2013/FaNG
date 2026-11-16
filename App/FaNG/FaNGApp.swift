import SwiftUI

@main struct FaNGApp: App {
    init() {
        // Live changes for as long as the app runs (on macOS it keeps running with its window closed).
        LiveUpdates.shared.refresh()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
