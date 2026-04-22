import AppKit
import SwiftUI

// MARK: - MenuBarManager

/// Manages a native NSStatusItem + NSPopover for the Klarity menu bar presence.
/// Using NSStatusItem directly (rather than SwiftUI MenuBarExtra) avoids a Swift
/// @SceneBuilder type-inference crash when conditionally including the menu bar scene,
/// and gives full programmatic show/hide control without requiring an app restart.
@MainActor
final class MenuBarManager: ObservableObject {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    private var reminderPopover: NSPopover?
    private var notificationTask: Task<Void, Never>?
    private weak var recordingVM: RecordingViewModel?

    // MARK: Lifecycle

    /// Call once after appState and recordingVM are ready (from ContentView.task).
    func setup(appState: AppState, recordingVM: RecordingViewModel) {
        self.recordingVM = recordingVM
        let shouldShow = UserDefaults.standard.object(forKey: "klarityShowMenuBar") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "klarityShowMenuBar")
        if shouldShow {
            install(appState: appState, recordingVM: recordingVM)
        }
        
        // Listen for reminder triggers
        notificationTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: NSNotification.Name("KlarityShowReminder")) {
                let isTest = notification.userInfo?["isTest"] as? Bool ?? false
                let isActive = self?.recordingVM?.isRecording == true || self?.recordingVM?.isPaused == true
                
                // Only show if it's a test, or an actual active recording
                if isActive || isTest {
                    let mins = notification.userInfo?["minutes"] as? Int ?? 30
                    await self?.showReminder(minutes: mins)
                }
            }
        }
    }

    func install(appState: AppState, recordingVM: RecordingViewModel) {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon(to: item, isRecording: false, isPaused: false)

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 260, height: 320)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: MenuBarContentView()
                .environmentObject(appState)
                .environmentObject(recordingVM)
                .environmentObject(self)
        )
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))

        self.statusItem = item
        self.popover = pop
    }

    func uninstall() {
        popover?.performClose(nil)
        reminderPopover?.performClose(nil)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover = nil
        reminderPopover = nil
        notificationTask?.cancel()
    }

    func openMainWindow() {
        popover?.performClose(nil)
        reminderPopover?.performClose(nil)
        WindowManager.shared.showMainWindow()
    }

    /// Call when recording state changes to update the menu bar icon.
    func updateIcon(isRecording: Bool, isPaused: Bool) {
        guard let item = statusItem else { return }
        applyIcon(to: item, isRecording: isRecording, isPaused: isPaused)
    }

    // MARK: Private

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let pop = popover, let button = statusItem?.button else { return }
        
        // Close reminder if it's up
        if reminderPopover?.isShown == true {
            reminderPopover?.performClose(nil)
        }
        
        if pop.isShown {
            pop.performClose(sender)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func applyIcon(to item: NSStatusItem, isRecording: Bool, isPaused: Bool) {
        let name = isRecording ? "waveform" : isPaused ? "pause.circle.fill" : "mic.fill"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Klarity")
        img?.isTemplate = true   // auto-adapts to light/dark menu bar tint
        item.button?.image = img
    }
    
    private func showReminder(minutes: Int) {
        // If the main menu is already open, do not disrupt it
        if popover?.isShown == true { return }
        guard let button = statusItem?.button else { return }
        
        if reminderPopover == nil {
            let pop = NSPopover()
            pop.behavior = .transient
            self.reminderPopover = pop
        }
        
        let root = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(Color.orange)
                    .font(.system(size: 14))
                Text("Recording Active")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(NSColor.labelColor))
            }
            Text("You have been recording for \(minutes) minutes. Remember to stop when finished.")
                .font(.system(size: 12))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            
            HStack(spacing: 12) {
                Button("Stop Recording") {
                    self.reminderPopover?.performClose(nil)
                    Task { [weak self] in await self?.recordingVM?.stopAndProcess() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.red)

                Button("Dismiss") {
                    self.reminderPopover?.performClose(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.blue)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 240)
        
        reminderPopover?.contentViewController = NSHostingController(rootView: root)
        reminderPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSSound(named: "Glass")?.play()
    }
}

// MARK: - Menu Bar Content View

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var menuBarManager: MenuBarManager
    @AppStorage("klarityShowMenuBar") private var showMenuBarItem: Bool = true

    private var isActivelyRecording: Bool {
        recordingVM.isRecording || recordingVM.isPaused ||
        recordingVM.isPreparing || recordingVM.isStopping
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            HStack(spacing: 9) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
                Text("Klarity")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.primaryText)
                Spacer()
                if !appState.backendReachable {
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("Offline").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.5)

            // ── Recording controls (when active) ──────────────────────────────
            if isActivelyRecording {
                MenuBarRecordingSection()
                    .environmentObject(recordingVM)
                Divider().opacity(0.5)
            }

            // ── Actions ───────────────────────────────────────────────────────
            VStack(spacing: 2) {
                menuRow(
                    icon: "mic.fill",
                    label: "New Recording",
                    color: isActivelyRecording ? AppTheme.Colors.brandPrimary.opacity(0.4) : AppTheme.Colors.brandPrimary,
                    disabled: isActivelyRecording
                ) {
                    // Show the window first, then trigger the sheet once it's on screen
                    menuBarManager.openMainWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        appState.triggerNewRecording = true
                    }
                }

                menuRow(icon: "arrow.up.forward.app", label: "Open Klarity",
                        color: AppTheme.Colors.primaryText) {
                    menuBarManager.openMainWindow()
                }
            }
            .padding(.vertical, 6)

            Divider().opacity(0.5)

            VStack(spacing: 2) {
                menuRow(icon: "menubar.rectangle", label: "Hide from Menu Bar",
                        color: AppTheme.Colors.secondaryText) {
                    showMenuBarItem = false
                    menuBarManager.uninstall()
                }
                menuRow(icon: "power", label: "Quit Klarity",
                        color: AppTheme.Colors.accentRed) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 260)
        .background(AppTheme.Colors.cardSurface)
    }

    private func menuRow(icon: String, label: String, color: Color,
                         disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(disabled ? color.opacity(0.4) : color)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(disabled ? AppTheme.Colors.tertiaryText : AppTheme.Colors.primaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .disabled(disabled)
    }
}

// MARK: - Recording Section

struct MenuBarRecordingSection: View {
    @EnvironmentObject var vm: RecordingViewModel
    @State private var hasWaitedLongEnough = false

    var body: some View {
        VStack(spacing: 8) {
            if let title = vm.currentMeeting?.title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            // Pill — same visual as the in-app RecordingStatusPill
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(vm.isPaused ? Color.orange : Color.red)
                        .frame(width: 8, height: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(vm.recorder.formattedElapsed)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AppTheme.Colors.primaryText)
                            .frame(minWidth: 52, alignment: .leading)
                    }
                }
                .padding(.leading, 14).padding(.trailing, 8)

                Rectangle().fill(AppTheme.Colors.border).frame(width: 1, height: 18).padding(.horizontal, 4)

                if vm.isPreparing || vm.isStopping {
                    ProgressView().scaleEffect(0.6).frame(width: 32, height: 32)
                } else {
                    Button {
                        vm.isRecording ? vm.pauseRecording() : vm.resumeRecording()
                    } label: {
                        Image(systemName: vm.isPaused ? "play.fill" : "pause")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.primaryText)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await vm.stopAndProcess() }
                    } label: {
                        ZStack {
                            Circle().fill(AppTheme.Colors.primaryText).frame(width: 28, height: 28)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9)).foregroundStyle(AppTheme.Colors.cardSurface)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }

                Rectangle().fill(AppTheme.Colors.border).frame(width: 1, height: 18).padding(.horizontal, 4)

                // 🔊🎤 Audio source indicators
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(audioSourceColor(isActive: vm.hasSysAudio))
                        .help(vm.hasSysAudio ? "System audio: Active" : "System audio: Waiting\u{2026}")

                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(audioSourceColor(isActive: vm.hasMicAudio))
                        .help(vm.hasMicAudio ? "Microphone: Active" : "Microphone: Waiting\u{2026}")
                }
                .padding(.trailing, 14)

                Spacer(minLength: 0)
            }
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 21)
                    .fill(AppTheme.Colors.hoverFill)
                    .overlay(RoundedRectangle(cornerRadius: 21)
                        .stroke(AppTheme.Colors.subtleBorder, lineWidth: 0.5))
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
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
}

// MARK: - Button Style

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AppTheme.Colors.hoverFill : Color.clear)
            .cornerRadius(6)
    }
}
