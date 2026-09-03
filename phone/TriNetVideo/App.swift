// App.swift — Entry point
import SwiftUI

@main
struct TriNetVideoApp: App {
    @UIApplicationDelegateAdaptor(TriNetAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: StreamViewModel

    // Tee stderr into the in-app log before anything else runs, so the very
    // first audio/transport line is captured.
    init() {
        LogBus.shared.start()
        NatDiagnostics.run()
        let model = StreamViewModel()
        _viewModel = StateObject(wrappedValue: model)
        // PushKit can launch the process directly into the system incoming-call
        // UI. Attach before the first SwiftUI view appears so Answer always has
        // a media controller, including a cold launch.
        CallKitCoordinator.shared.attach(viewModel: model)
        #if DEBUG
        model.configureDebugE2E(arguments: ProcessInfo.processInfo.arguments)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HomeView(vm: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
