import SwiftUI

@main
struct CurrentApp: App {
    @StateObject private var store = AppStore.shared
    init() { AppLog.shared.record(.app, .started, operation: .startup) }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(CurrentTheme.accent)
                .task { await store.restoreSession() }
        }
    }
}
