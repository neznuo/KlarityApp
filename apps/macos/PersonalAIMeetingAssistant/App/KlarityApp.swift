import SwiftUI
import UserNotifications

// MARK: - App Delegate

/// Handles system-level callbacks that SwiftUI doesn't expose as modifiers.
final class KlarityAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called when the user clicks the Dock icon while all windows are hidden/closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMainWindow()
        return true
    }
    
    // Allows notifications to show even when app is focused
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge, .list])
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
@MainActor
final class AppState: ObservableObject {
    /// Shared reference so BackendProcessManager can call back into it.
    static weak var shared: AppState?

    @Published var backendReachable: Bool = false
    @Published var backendStartupError: String?
    @Published var backendVenvHealthy: Bool = false
    @Published var isCreatingBackend: Bool = false
    @Published var backendCreationStatus: String = ""
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

    let meetingDetector = MeetingDetectorService()

    private let backend = BackendProcessManager.shared
    private var healthPollTimer: Timer?

    /// True when the backend process is running AND the venv is healthy.
    var backendReady: Bool { backendReachable && backendVenvHealthy }

    init() {
        AppState.shared = self

        Task { @MainActor in
            // 1. Validate venv before attempting to start backend.
            backend.checkVenvHealth()
            self.backendVenvHealthy = backend.isVenvHealthy

            // 2. Only start backend if venv is healthy.
            if backend.isVenvHealthy {
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
            } else {
                self.backendStartupError = "Python backend environment is missing or broken. Go to Settings → Backend Environment to create it."
            }
            self.healthPollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.pollBackendHealth()
            }
        }
    }

    @MainActor
    func pollBackendHealth() {
        if !backend.isRunning {
            backendReachable = false
        } else {
            Task { await checkBackend() }
        }
    }

    @MainActor
    func checkBackend() async {
        backend.checkVenvHealth()
        backendVenvHealthy = backend.isVenvHealthy
        if backendVenvHealthy {
            backendReachable = await APIClient.shared.healthCheck()
            if backendReachable {
                await checkDependencies()
            }
        }
    }

    @MainActor
    func createBackendEnvironment() async {
        guard !isCreatingBackend else { return }
        isCreatingBackend = true
        defer { isCreatingBackend = false }

        // Mirror venv creation status into AppState so the UI updates live.
        let statusTask = Task {
            while !Task.isCancelled {
                self.backendCreationStatus = backend.venvCreationStatus
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        await backend.createLocalVenv()
        statusTask.cancel()
        self.backendCreationStatus = backend.venvCreationStatus

        backendVenvHealthy = backend.isVenvHealthy
        if backendVenvHealthy {
            backend.start()
            // Wait for backend to come up
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let reachable = await APIClient.shared.healthCheck()
                if reachable {
                    backendReachable = true
                    await checkDependencies()
                    return
                }
            }
            backendStartupError = backend.startupError ?? "Backend did not respond within 10 seconds."
        }
    }

    @MainActor
    func checkDependencies() async {
        dependencies = try? await APIClient.shared.fetchDependencies()
    }

    /// Call from applicationWillTerminate (or SwiftUI .onReceive of NSApplication.willTerminateNotification)
    @MainActor
    func shutdown() {
        healthPollTimer?.invalidate()
        healthPollTimer = nil
        backend.stop()
    }
}