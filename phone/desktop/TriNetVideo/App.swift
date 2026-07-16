// App.swift — Entry point
import SwiftUI

@main
struct TriNetVideoApp: App {
    @StateObject var call = CallManager()

    var body: some Scene {
        WindowGroup {
            CallView()
                .environmentObject(call)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
    }
}
