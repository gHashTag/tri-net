// App.swift — Entry point
import SwiftUI

@main
struct TriNetVideoApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
        }
    }
}
