import SwiftUI

/// Root navigation container.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: AppNavigationItem? = .meetings

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $selection)
        } detail: {
            // Main content area
            switch selection {
            case .meetings, .none:
                HomeView()
                    .navigationTitle("Meetings")
            case .contacts:
                PeopleView()
                    .navigationTitle("Contacts")
            case .settings:
                SettingsView()
                    .navigationTitle("Settings")
            default:
                // Placeholder for unimplemented sections: Upcoming, ActionItems, Later, Activity
                VStack(spacing: AppTheme.Metrics.paddingStandard) {
                    Image(systemName: "hammer.fill")
                        .font(.largeTitle)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                    Text("\(selection?.rawValue ?? "") is under construction.")
                        .font(AppTheme.Fonts.listTitle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Colors.background)
            }
        }
        // Cleanly stops the Python backend when the macOS app quits
        .handleAppTermination()
        // Surface backend startup failures to the user
        .alert(
            "Backend Failed to Start",
            isPresented: .constant(appState.backendStartupError != nil),
            actions: { Button("OK") { appState.backendStartupError = nil } },
            message: { Text(appState.backendStartupError ?? "") }
        )
    }
}

// MARK: - App Theme
/// Global typography and color tokens to guarantee design consistency.
struct AppTheme {
    struct Colors {
        static let background = Color(NSColor.windowBackgroundColor)
        static let sidebarBackground = Color(NSColor.underPageBackgroundColor)
        static let primaryText = Color.primary
        static let secondaryText = Color.secondary
        static let border = Color(nsColor: NSColor.separatorColor).opacity(0.3)
        static let brandPrimary = Color.blue
        static let accentGreen = Color.green
        static let accentOrange = Color.orange
        static let accentRed = Color.red
    }
    
    struct Fonts {
        static let header = Font.system(size: 24, weight: .bold, design: .default)
        static let listTitle = Font.system(size: 14, weight: .semibold, design: .default)
        static let body = Font.system(size: 13, weight: .regular, design: .default)
        static let caption = Font.system(size: 11, weight: .medium, design: .default)
        static let smallMono = Font.system(size: 10, weight: .medium, design: .monospaced)
    }
    
    struct Metrics {
        static let paddingStandard: CGFloat = 16
        static let paddingSmall: CGFloat = 8
        static let cornerRadius: CGFloat = 8
    }
}

// MARK: - App Navigation Sidebar
enum AppNavigationItem: String, CaseIterable, Identifiable {
    case meetings    = "Meetings"
    case upcoming    = "Upcoming"
    case actionItems = "Action Items"
    case later       = "Later"
    case activity    = "Activity"
    case contacts    = "Contacts"
    case settings    = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .meetings:    return "video"
        case .upcoming:    return "clock"
        case .actionItems: return "list.bullet.clipboard"
        case .later:       return "clock.arrow.circlepath"
        case .activity:    return "bell"
        case .contacts:    return "person.2"
        case .settings:    return "gear"
        }
    }
}

struct AppSidebar: View {
    @Binding var selection: AppNavigationItem?
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(AppNavigationItem.allCases, selection: $selection) { item in
            NavigationLink(value: item) {
                Label(item.rawValue, systemImage: item.icon)
                    .font(AppTheme.Fonts.listTitle)
                    .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Klarity Workspace")
        .safeAreaInset(edge: .bottom) {
            if !appState.backendReachable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Backend Offline")
                        .font(AppTheme.Fonts.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding()
                .background(AppTheme.Colors.sidebarBackground)
            }
        }
    }
}
