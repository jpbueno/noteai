import SwiftUI

// TranscriptView is no longer used standalone — transcript is rendered
// inline in NotionPageView. Kept for compatibility.
struct TranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(segments) { segment in
                HStack(alignment: .top, spacing: 0) {
                    if let speaker = segment.speaker {
                        Text("\(speaker): ").bold() + Text(segment.text)
                    } else {
                        Text(segment.text)
                    }
                }
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
                .padding(.vertical, 4)
            }
        }
    }
}

/// Live transcript during active recording — Notion dark style.
/// Shows a split pane with the transcript on the left and the AI Solutions
/// Architect coach panel on the right (when enabled).
struct LiveTranscriptView: View {
    @ObservedObject var meetingManager: MeetingManager
    @State private var coachWidth: CGFloat = 300
    private static let coachWidthKey = "aiCoachPanelWidth"

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(spacing: 0) {
                transcriptArea

                if meetingManager.coachEnabled {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1)
                    resizeHandle
                    CoachPanelView(
                        insights: meetingManager.coachInsights,
                        isAnalyzing: meetingManager.coachAnalyzing,
                        isReplying: meetingManager.coachReplying,
                        onSend: { meetingManager.sendCoachMessage($0) }
                    )
                    .frame(width: coachWidth)
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            footerStats
        }
        .background(Theme.contentBG)
        .onAppear {
            let saved = UserDefaults.standard.double(forKey: Self.coachWidthKey)
            if saved >= 220 && saved <= 700 {
                coachWidth = CGFloat(saved)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: "E03E3E"))
                    .frame(width: 10, height: 10)
                Text("Recording")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            Text(formatDuration(meetingManager.recordingDuration))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: "E03E3E"))

            RecordingDiagnosticsCompactView(snapshot: meetingManager.recordingDiagnostics)

            Spacer()

            Button {
                meetingManager.toggleCoach()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                    Text("AI Solutions Architect")
                        .font(.system(size: 12, weight: .medium))
                    if !meetingManager.coachInsights.isEmpty {
                        Text("\(meetingManager.coachInsights.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                }
                .foregroundStyle(meetingManager.coachEnabled ? Color.accentColor : Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (meetingManager.coachEnabled ? Color.accentColor.opacity(0.15) : Theme.hoverBG),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(meetingManager.coachEnabled ? Color.accentColor.opacity(0.4) : Theme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button {
                meetingManager.stopRecording()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Stop")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(hex: "E03E3E"), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let segments = meetingManager.currentTranscript
                    if segments.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "mic")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.textTertiary)
                            Text("Listening… transcript will appear here in real time.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(segments) { segment in
                            HStack(alignment: .top, spacing: 10) {
                                Text(segment.formattedTimestamp)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 46, alignment: .trailing)
                                    .padding(.top, 2)
                                Text(segment.text)
                                    .font(.system(size: Theme.bodySize))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                            .id(segment.id)
                        }
                    }
                }
                .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: meetingManager.currentTranscript.count) { _, _ in
                if let last = meetingManager.currentTranscript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 3)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // Drag LEFT expands coach panel (negative dx grows width)
                        let newWidth = coachWidth - value.translation.width
                        coachWidth = max(220, min(700, newWidth))
                    }
                    .onEnded { _ in
                        UserDefaults.standard.set(Double(coachWidth), forKey: Self.coachWidthKey)
                    }
            )
    }

    private var footerStats: some View {
        HStack(spacing: 16) {
            Text("\(meetingManager.currentTranscript.count) segments")
            Text(formatDuration(meetingManager.recordingDuration))
            ForEach(meetingManager.recordingDiagnostics.warnings.prefix(2), id: \.self) { warning in
                Text(warning)
                    .foregroundStyle(Color(hex: "FFA94D"))
            }
            if meetingManager.coachEnabled && !meetingManager.coachInsights.isEmpty {
                Text("\(meetingManager.coachInsights.count) insights")
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

struct RecordingDiagnosticsCompactView: View {
    let snapshot: RecordingDiagnosticsSnapshot

    var body: some View {
        HStack(spacing: 10) {
            RecordingLevelPill(
                title: "Mic",
                icon: "mic.fill",
                diagnostic: snapshot.microphone
            )
            RecordingLevelPill(
                title: "System",
                icon: "speaker.wave.2.fill",
                diagnostic: snapshot.systemAudio
            )
            if !snapshot.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "FFA94D"))
                    .help(snapshot.warnings.joined(separator: "\n"))
            }
        }
    }
}

struct RecordingLevelPill: View {
    let title: String
    let icon: String
    let diagnostic: RecordingSourceDiagnostic

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 10, weight: .medium))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule()
                        .fill(diagnostic.status.isCapturing ? Color.accentColor : Theme.textTertiary)
                        .frame(width: max(4, geometry.size.width * diagnostic.level.meterValue))
                }
            }
            .frame(width: 42, height: 5)
        }
        .foregroundStyle(diagnostic.status.isCapturing ? Theme.textSecondary : Theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(diagnostic.status.isCapturing ? Theme.border : Color(hex: "FFA94D").opacity(0.35), lineWidth: 1)
        )
        .help(diagnostic.status.diagnosticDescription)
    }
}
