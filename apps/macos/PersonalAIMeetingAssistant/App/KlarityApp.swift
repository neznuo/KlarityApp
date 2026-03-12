import SwiftUI

@main
struct KlarityApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// MARK: - App State

/// Global application state — holds backend reachability and process handle.
final class AppState: ObservableObject {
    /// Shared reference so BackendProcessManager can call back into it.
    static weak var shared: AppState?

    @Published var backendReachable: Bool = false
    @Published var backendStartupError: String?
    @Published var dependencies: DependenciesResult?

    private let backend = BackendProcessManager.shared

    init() {
        AppState.shared = self

        // Start the embedded backend on launch, then verify it's reachable.
        Task { @MainActor in
            backend.start()
            // checkBackend is called by BackendProcessManager after the 2s warmup,
            // but also poll here as a fallback.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let reachable = await APIClient.shared.healthCheck()
                if reachable {
                    self.backendReachable = true
                    await self.checkDependencies()
                    return
                }
            }
            // If still not up after 10s, surface the startup error.
            self.backendStartupError = backend.startupError ?? "Backend did not respond within 10 seconds."
        }
    }

    @MainActor
    func checkBackend() async {
        backendReachable = await APIClient.shared.healthCheck()
        if backendReachable {
            await checkDependencies()
        }
    }

    @MainActor
    func checkDependencies() async {
        dependencies = try? await APIClient.shared.fetchDependencies()
    }

    /// Call from applicationWillTerminate (or SwiftUI .onReceive of NSApplication.willTerminateNotification)
    @MainActor
    func shutdown() {
        backend.stop()
    }
}
