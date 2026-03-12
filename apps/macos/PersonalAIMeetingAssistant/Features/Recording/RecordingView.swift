import SwiftUI

/// Sheet-style recording flow: user enters a title, starts/pauses/stops recording.
struct RecordingView: View {
    /// Called with the new Meeting when recording stops.
    var onComplete: (Meeting) -> Void

    @StateObject private var vm = RecordingViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Status indicator
            ZStack {
                Circle()
                    .fill(vm.isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: vm.isRecording ? "waveform" : "mic")
                    .font(.system(size: 48))
                    .foregroundStyle(vm.isRecording ? Color.red : Color.gray)
                    .symbolEffect(.pulse, isActive: vm.isRecording)
            }

            if vm.isRecording || vm.isPaused {
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    Text(vm.recorder.formattedElapsed)
                        .font(.system(size: 52, weight: .light, design: .monospaced))
                        .foregroundStyle(vm.isPaused ? .secondary : .primary)
                }

                Text(vm.isPaused ? "Paused" : "Recording")
                    .font(.headline)
                    .foregroundStyle(vm.isPaused ? Color.secondary : Color.red)
            } else {
                // Title input and mode selection before starting
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Meeting Title")
                            .font(.headline)
                        TextField("e.g. Product Sync, 1:1 with Sarah", text: $vm.meetingTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recording Mode")
                            .font(.headline)
                        Picker("", selection: $vm.recordingMode) {
                            ForEach(RecordingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 320)
                    }
                }
            }

            // Controls
            HStack(spacing: 20) {
                if vm.isStopping {
                    ProgressView("Saving recording...")
                        .padding()
                } else if vm.isCreating {
                    ProgressView("Starting...")
                        .padding()
                } else if !vm.isRecording && !vm.isPaused {
                    Button {
                        Task { await vm.startNewMeeting() }
                    } label: {
                        Label("Start Recording", systemImage: "record.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(vm.meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                } else {
                    if vm.isRecording {
                        Button {
                            vm.pauseRecording()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            vm.resumeRecording()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        Task {
                            if let meeting = await vm.stopAndProcess() {
                                onComplete(meeting)
                            }
                        }
                    } label: {
                        Label("Stop & Process", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let err = vm.errorMessage {
                Text(err)
                    .foregroundStyle(Color.red)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 400)
    }
}
