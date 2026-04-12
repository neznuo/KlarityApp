import SwiftUI

// MARK: - App Delegate

/// Handles system-level callbacks that SwiftUI doesn't expose as modifiers.
final class KlarityAppDelegate: NSObject, NSApplicationDelegate {
    /// Called when the user clicks the Dock icon while all windows are hidden/closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMainWindow()
        return true
    }
}

@main
struct KlarityApp: App {
    @NSApplicationDelegateAdaptor(KlarityAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var recordingManager = RecordingViewModel()
    @StateObject private var menuBarManager = MenuBarManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(recordingManager)
                .environmentObject(menuBarManager)
                .preferredColorScheme(appState.preferredColorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    recordingManager.recorder.cleanup()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(recordingManager)
                .environmentObject(menuBarManager)
                .preferredColorScheme(appState.preferredColorScheme)
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

    /// "system" | "light" | "dark" — persisted across launches.
    @Published var colorSchemePreference: String = UserDefaults.standard.string(forKey: "klarityColorScheme") ?? "system" {
        didSet { UserDefaults.standard.set(colorSchemePreference, forKey: "klarityColorScheme") }
    }
    var preferredColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    /// Set to true by the menu bar "New Recording" button to trigger the sheet in ContentView.
    @Published var triggerNewRecording: Bool = false

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