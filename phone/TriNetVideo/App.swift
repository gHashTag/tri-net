// App.swift — Entry point
import SwiftUI

@main
struct TriNetVideoApp: App {
    // Tee stderr into the in-app log before anything else runs, so the very
    // first audio/transport line is captured.
    init() { LogBus.shared.start(); NatDiagnostics.run() }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
        }
    }
}
