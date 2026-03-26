import SwiftUI

struct MenuBarView: View {
    @ObservedObject var meetingManager: MeetingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status header
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
                if meetingManager.state == .recording {
                    Spacer()
                    Text(formattedDuration)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Error banner
            if let error = meetingManager.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .lineLimit(3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
            }

            Divider()

            // Recording toggle
            Button(action: { meetingManager.toggleRecording() }) {
                Label(
                    meetingManager.state == .recording ? "Stop Recording" : "Start Recording",
                    systemImage: meetingManager.state == .recording ? "stop.circle.fill" : "record.circle"
                )
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(meetingManager.state == .processing)

            // Auto-detect toggle
            Toggle(isOn: $meetingManager.autoDetectEnabled) {
                Label("Auto-Detect Meetings", systemImage: "antenna.radiowaves.left.and.right")
            }

            if meetingManager.autoDetectEnabled {
                HStack(spacing: 4) {
                    Circle()
                        .fill(meetingManager.meetingDetector.state == .detected ? .red : .blue)
                        .frame(width: 6, height: 6)
                    Text(autoDetectStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            Divider()

            // Recent meetings
            if meetingManager.meetings.isEmpty {
                Text("No meetings yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal)
            } else {
                Text("Recent Meetings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ForEach(meetingManager.meetings.prefix(5)) { meeting in
                    Button {
                        openMeetingWindow(meeting)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title)
                                .lineLimit(1)
                            Text(meeting.formattedDuration)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            Button("Open NoteAI...") {
                openMainWindow()
            }
            .keyboardShortcut("o", modifiers: .command)

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit NoteAI") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch meetingManager.state {
        case .idle: return .green
        case .recording: return .red
        case .processing: return .yellow
        }
    }

    private var statusText: String {
        switch meetingManager.state {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .processing: return "Processing..."
        }
    }

    private var formattedDuration: String {
        let total = Int(meetingManager.recordingDuration)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var autoDetectStatusText: String {
        switch meetingManager.meetingDetector.state {
        case .monitoring: return "Monitoring for meetings..."
        case .detected:
            let app = meetingManager.meetingDetector.detectedApp ?? "Meeting"
            return "Recording \(app)"
        case .disabled: return ""
        }
    }

    private func openMeetingWindow(_ meeting: Meeting) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showMainWindow()
        }
    }

    private func openMainWindow() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showMainWindow()
        }
    }
}
