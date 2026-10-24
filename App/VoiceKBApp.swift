import SwiftUI

@main
struct VoiceKBApp: App {
    @StateObject private var d = Dictation.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(d: d)
                .onOpenURL { d.handle(url: $0) }
                .onChange(of: phase) { _, p in if p == .active { Bridge.shared.start() } }
        }
    }
}
