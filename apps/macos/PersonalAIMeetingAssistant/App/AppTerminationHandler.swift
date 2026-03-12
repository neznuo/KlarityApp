import SwiftUI
import AppKit

/// Listens for NSApplication.willTerminateNotification and
/// gracefully shuts down the embedded Python backend process.
struct AppTerminationHandler: ViewModifier {
    @EnvironmentObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            ) { _ in
                appState.shutdown()
            }
    }
}

extension View {
    func handleAppTermination() -> some View {
        modifier(AppTerminationHandler())
    }
}
