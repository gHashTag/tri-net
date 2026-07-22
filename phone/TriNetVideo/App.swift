// App.swift — Entry point
import SwiftUI

@main
struct TriNetVideoApp: App {
    @UIApplicationDelegateAdaptor(TriNetAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = StreamViewModel()

    // Tee stderr into the in-app log before anything else runs, so the very
    // first audio/transport line is captured.
    init() { LogBus.shared.start() }

    var body: some Scene {
        WindowGroup {
            HomeView(vm: viewModel)
                .preferredColorScheme(.dark)
                .onAppear {
                    CallKitCoordinator.shared.attach(viewModel: viewModel)
                }
        }
    }
}
