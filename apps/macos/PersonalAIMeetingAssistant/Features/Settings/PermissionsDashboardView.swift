import SwiftUI

struct PermissionsDashboardView: View {
    @ObservedObject var permVM: PermissionsViewModel
    @EnvironmentObject var appState: AppState
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            // Readiness summary
            HStack(spacing: 6) {
                Image(systemName: permVM.grantedCount == permVM.totalPermissions
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(permVM.grantedCount == permVM.totalPermissions
                        ? AppTheme.Colors.accentGreen
                        : AppTheme.Colors.accentOrange)
                Text(permVM.readinessText)
                    .font(compact ? AppTheme.Fonts.caption : AppTheme.Fonts.body)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }

            // Permission rows
            PermissionStatusRow(
                icon: "mic.fill",
                title: "Microphone",
                subtitle: compact ? "Required for recording meeting audio" : nil,
                status: permVM.hasMicAccess ? .granted : .denied,
                actionLabel: "Grant Access",
                action: { permVM.requestMicAccess() },
                compact: compact
            )

            PermissionStatusRow(
                icon: "speaker.wave.2.fill",
                title: "System Audio",
                subtitle: compact ? "Prompted on first recording" : "Permission is prompted when you start your first recording",
                status: systemAudioState,
                compact: compact
            )

            PermissionStatusRow(
                icon: "accessibility",
                title: "Accessibility",
                subtitle: compact ? "Required for call detection" : nil,
                status: permVM.hasAccessibilityAccess ? .granted : .denied,
                actionLabel: "Open System Settings",
                action: { permVM.requestAccessibility() },
                compact: compact
            )

            PermissionStatusRow(
                icon: "calendar",
                title: "Calendar",
                subtitle: compact ? "Connect in Calendar Sync section" : nil,
                status: permVM.hasCalendarAccess ? .granted : .denied,
                compact: compact
            )

            if compact {
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        permVM.resetPermissions()
                    } label: {
                        Label("Reset All", systemImage: "arrow.counterclockwise")
                            .font(AppTheme.Fonts.caption)
                    }
                    .help("Resets all macOS privacy permissions for Klarity and restarts the app.")
                }
                .padding(.top, 4)
            }
        }
    }

    private var systemAudioState: PermissionState {
        switch permVM.hasSystemAudioAccess {
        case .some(true):  return .granted
        case .some(false):  return .denied
        case .none:         return .unknown
        }
    }
}