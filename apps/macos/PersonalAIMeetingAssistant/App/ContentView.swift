import AppKit
import SwiftUI

// MARK: - Window lifecycle manager

/// Singleton that holds a strong reference to the main window and its hide-on-close
/// delegate. By keeping these references here nothing can accidentally be deallocated.
final class WindowManager: NSObject {
    static let shared = WindowManager()
    private override init() {}

    private(set) weak var mainWindow: NSWindow?
    private var hideOnCloseDelegate: HideOnCloseDelegate?

    /// Call once when the NSWindow for ContentView first becomes available.
    func capture(_ window: NSWindow) {
        guard mainWindow == nil else { return }
        mainWindow = window
        let d = HideOnCloseDelegate()
        d.next = window.delegate          // chain existing SwiftUI delegate
        window.delegate = d
        hideOnCloseDelegate = d           // keep strong reference so ARC doesn't drop it
    }

    /// Bring the main window to the front. Works whether the window is hidden or visible.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Intercepts the window close button: hides the window instead of destroying it.
/// The window stays alive in NSApp.windows so WindowManager can always reopen it.
final class HideOnCloseDelegate: NSObject, NSWindowDelegate {
    weak var next: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)   // hide, don't close
        return false
    }

    // Forward everything else to SwiftUI's original delegate.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (next?.responds(to: aSelector) ?? false)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if !super.responds(to: aSelector), next?.responds(to: aSelector) == true { return next }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Invisible NSView that fires once when the SwiftUI window is ready and registers it
/// with WindowManager.
private struct WindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.captured == false else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            WindowManager.shared.capture(window)
            context.coordinator.captured = true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var captured = false }
}

/// Root navigation container.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var menuBarManager: MenuBarManager
    @State private var selection: AppNavigationItem? = .meetings
    @State private var showingRecording = false
    @AppStorage("klarityShowMenuBar") private var showMenuBarItem: Bool = true

    private var isActivelyRecording: Bool {
        recordingVM.isRecording || recordingVM.isPaused ||
        recordingVM.isPreparing || recordingVM.isStopping
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $selection)
        } detail: {
            switch selection {
            case .meetings, .none:
                HomeView()
                    .navigationTitle("Meetings")
            case .contacts:
                PeopleView()
                    .navigationTitle("Contacts")
            case .actionItems:
                ActionItemsView()
                    .navigationTitle("Action Items")
            case .settings:
                SettingsView()
                    .navigationTitle("Settings")
            default:
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
        // Register this window with WindowManager (installs hide-on-close delegate)
        .background(WindowCapture())
        // ── Recording pill floats at the top of the window ───────────────────
        .safeAreaInset(edge: .top, spacing: 0) {
            if isActivelyRecording {
                HStack {
                    Spacer()
                    RecordingStatusPill()
                        .environmentObject(recordingVM)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(AppTheme.Colors.background.opacity(0.01)) // hit-test passthrough
            }
        }
        // ── Global toolbar: New Recording ────────────────────────────────────
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingRecording = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill").font(.system(size: 11))
                        Text("New Recording").font(AppTheme.Fonts.listTitle)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(isActivelyRecording
                                ? AppTheme.Colors.brandPrimary.opacity(0.4)
                                : AppTheme.Colors.brandPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                }
                .buttonStyle(.borderless)
                .disabled(isActivelyRecording)
                .help(isActivelyRecording ? "A recording is already in progress" : "Start a new meeting recording")
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showingRecording) {
            RecordingView()
                .environmentObject(recordingVM)
        }
        // Triggered by the menu bar "New Recording" button.
        // WindowManager.showMainWindow() is called first by the menu bar action,
        // so by the time this fires the window is already coming to front.
        .onChange(of: appState.triggerNewRecording) { _, shouldTrigger in
            if shouldTrigger {
                showingRecording = true
                appState.triggerNewRecording = false
            }
        }
        // ── Menu bar setup ────────────────────────────────────────────────────
        .task {
            menuBarManager.setup(appState: appState, recordingVM: recordingVM)
        }
        // Re-install / uninstall when the Settings toggle changes
        .onChange(of: showMenuBarItem) { _, show in
            if show { menuBarManager.install(appState: appState, recordingVM: recordingVM) }
            else    { menuBarManager.uninstall() }
        }
        // Keep menu bar icon in sync with recording state
        .onChange(of: recordingVM.isRecording) { _, _ in
            menuBarManager.updateIcon(isRecording: recordingVM.isRecording, isPaused: recordingVM.isPaused)
        }
        .onChange(of: recordingVM.isPaused) { _, _ in
            menuBarManager.updateIcon(isRecording: recordingVM.isRecording, isPaused: recordingVM.isPaused)
        }
        .handleAppTermination()
        .alert(
            "Backend Failed to Start",
            isPresented: .constant(appState.backendStartupError != nil),
            actions: { Button("OK") { appState.backendStartupError = nil } },
            message: { Text(appState.backendStartupError ?? "") }
        )
    }
}

// MARK: - Recording Status Pill

/// Floating pill shown at the top of the app whenever a recording is active.
/// Matches the Krisp-style mockup: ● timer | ⏸ ⏹ | 🎤
/// Adapts automatically to light and dark mode via system colors.
struct RecordingStatusPill: View {
    @EnvironmentObject var vm: RecordingViewModel
    @State private var hasWaitedLongEnough = false

    var body: some View {
        HStack(spacing: 0) {

            // ● Red dot + timer ───────────────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.isPaused ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(vm.recorder.formattedElapsed)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .frame(minWidth: 60, alignment: .leading)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)

            // Divider ─────────────────────────────────────────────────────────
            divider

            // ⏸ Pause / Resume ────────────────────────────────────────────────
            if vm.isPreparing || vm.isStopping {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 36, height: 36)
            } else {
                Button {
                    vm.isRecording ? vm.pauseRecording() : vm.resumeRecording()
                } label: {
                    Image(systemName: vm.isPaused ? "play.fill" : "pause")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                // ⏹ Stop ──────────────────────────────────────────────────────
                Button {
                    Task { await vm.stopAndProcess() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.primaryText)
                            .frame(width: 30, height: 30)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.cardSurface)
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }

            // Divider ─────────────────────────────────────────────────────────
            divider

            // 🔊🎤 Audio source indicators ─────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(audioSourceColor(isActive: vm.hasSysAudio))
                    .help(vm.hasSysAudio ? "System audio: Active" : "System audio: Waiting\u{2026}")

                Image(systemName: "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(audioSourceColor(isActive: vm.hasMicAudio))
                    .help(vm.hasMicAudio ? "Microphone: Active" : "Microphone: Waiting\u{2026}")
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 44)
        .background(
            Capsule()
                .fill(AppTheme.Colors.cardSurface)
                .shadow(color: AppTheme.Colors.shadow.opacity(2), radius: 12, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.Colors.subtleBorder, lineWidth: 0.5)
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                hasWaitedLongEnough = true
            }
        }
    }

    private func audioSourceColor(isActive: Bool) -> Color {
        if isActive { return AppTheme.Colors.accentGreen }
        if hasWaitedLongEnough { return AppTheme.Colors.accentRed }
        return AppTheme.Colors.tertiaryText
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.Colors.border)
            .frame(width: 1, height: 22)
            .padding(.horizontal, 6)
    }
}

// MARK: - App Theme
/// Krisp/Wispr-inspired design system.
/// Every color uses an NSColor semantic that automatically adapts to light and dark mode.
/// The brand purple (#614EFA) is intentionally fixed — it reads well on both backgrounds.
struct AppTheme {

    struct Colors {
        // ── Surfaces ─────────────────────────────────────────────────────────
        /// Main window chrome — light: ~#F7F7F8 | dark: ~#1E1E1E
        static let background       = Color(NSColor.windowBackgroundColor)
        /// Cards and content panes — light: #FFFFFF | dark: ~#2C2C2E
        static let cardSurface      = Color(NSColor.textBackgroundColor)
        /// Sidebar background — slightly darker than content
        static let sidebarBackground = Color(NSColor.underPageBackgroundColor)
        /// Text fields and input controls
        static let inputBackground  = Color(NSColor.controlBackgroundColor)
        /// Subtle hover / selection fill
        static let hoverFill        = Color(NSColor.controlColor)

        // ── Text ─────────────────────────────────────────────────────────────
        static let primaryText      = Color(NSColor.labelColor)
        static let secondaryText    = Color(NSColor.secondaryLabelColor)
        static let tertiaryText     = Color(NSColor.tertiaryLabelColor)

        // ── Borders ──────────────────────────────────────────────────────────
        static let border           = Color(NSColor.separatorColor)
        static let subtleBorder     = Color(NSColor.separatorColor).opacity(0.4)

        // ── Brand — #614EFA (Krisp primary) ─────────────────────────────────
        static let brandPrimary     = Color(red: 0.380, green: 0.306, blue: 0.980)
        static let brandLight       = Color(red: 0.380, green: 0.306, blue: 0.980, opacity: 0.10)
        static let brandMid         = Color(red: 0.380, green: 0.306, blue: 0.980, opacity: 0.18)

        // ── Status ───────────────────────────────────────────────────────────
        static let accentGreen      = Color(red: 0.071, green: 0.718, blue: 0.416) // #12B76A
        static let accentOrange     = Color(red: 0.969, green: 0.565, blue: 0.035) // #F79009
        static let accentRed        = Color(red: 0.941, green: 0.267, blue: 0.220) // #F04438

        // ── Legacy aliases (keeps existing code compiling) ───────────────────
        static let cardBackground   = cardSurface
        static let brandSecondary   = brandLight
        static let elevatedCard     = cardSurface
        static let shadow           = Color.black.opacity(0.05)
    }

    struct Fonts {
        static let header       = Font.system(size: 22, weight: .bold)
        static let title        = Font.system(size: 15, weight: .semibold)
        static let listTitle    = Font.system(size: 13, weight: .semibold)
        static let body         = Font.system(size: 13, weight: .regular)
        static let caption      = Font.system(size: 11, weight: .medium)
        static let smallMono    = Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    struct Metrics {
        static let paddingStandard: CGFloat = 16
        static let paddingSmall:    CGFloat = 8
        static let cornerRadius:    CGFloat = 8
        static let cardRadius:      CGFloat = 12
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
                    .font(AppTheme.Fonts.body)
                    .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 45, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1.5)
                    Text("Klarity")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                Divider().opacity(0.6)
            }
            .background(AppTheme.Colors.sidebarBackground)
        }
        .safeAreaInset(edge: .bottom) {
            if !appState.backendReachable {
                HStack(spacing: 7) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                    Text("Backend Offline")
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.sidebarBackground)
            }
        }
    }
}
