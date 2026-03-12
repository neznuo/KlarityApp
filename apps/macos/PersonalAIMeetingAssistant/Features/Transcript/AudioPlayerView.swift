import SwiftUI
import AVFoundation

/// Persistent audio player — docked at the bottom of MeetingDetailView.
/// Receives seek commands from transcript row clicks via a Binding.
struct AudioPlayerView: View {
    let audioFilePath: String?
    @Binding var seekTarget: Double?   // seconds — set externally to seek

    @StateObject private var playerController = AudioPlayerController()

    var body: some View {
        HStack(spacing: 12) {
            // Play / Pause
            Button {
                playerController.togglePlayPause()
            } label: {
                Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(playerController.player == nil)

            // Current time label
            Text(timeLabel(playerController.currentTime))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50, alignment: .trailing)

            // Scrubber
            Slider(
                value: $playerController.currentTime,
                in: 0...max(playerController.duration, 1),
                onEditingChanged: { editing in
                    if !editing { playerController.seek(to: playerController.currentTime) }
                }
            )

            // Duration label
            Text(timeLabel(playerController.duration))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .onChange(of: audioFilePath) { _, newPath in
            guard let path = newPath else { return }
            playerController.load(path: path)
        }
        .onChange(of: seekTarget) { _, target in
            guard let secs = target else { return }
            playerController.seek(to: secs)
            playerController.play()
            seekTarget = nil
        }
        .onAppear {
            if let path = audioFilePath {
                playerController.load(path: path)
            }
        }
        .onDisappear {
            playerController.stop()
        }
    }

    private func timeLabel(_ secs: Double) -> String {
        let t = max(0, Int(secs))
        let m = t / 60; let s = t % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Controller

@MainActor
final class AudioPlayerController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    var player: AVAudioPlayer?
    private var displayLink: Timer?

    func load(path: String) {
        stop()
        // Try as a direct file path first, then as a URL string
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let u = URL(string: path) {
            url = u
        } else {
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            print("AudioPlayer load error: \(error)")
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        player?.play()
        isPlaying = true
        startPolling()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopPolling()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopPolling()
    }

    func seek(to seconds: Double) {
        player?.currentTime = seconds
        currentTime = seconds
    }

    private func startPolling() {
        displayLink = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying { self.isPlaying = false; self.stopPolling() }
            }
        }
    }

    private func stopPolling() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
