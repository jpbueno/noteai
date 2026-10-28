import AppKit
import SwiftUI

enum ReadAloudTextResolver {
    static func textToRead(fallback: String, selectedText: () -> String? = currentSelectedText) -> String {
        normalized(selectedText()) ?? fallback
    }

    static func selectedText(in text: String, range: NSRange) -> String? {
        let nsText = text as NSString
        guard range.length > 0, NSMaxRange(range) <= nsText.length else { return nil }
        return normalized(nsText.substring(with: range))
    }

    private static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func currentSelectedText() -> String? {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let selected = selectedText(in: textView.string, range: textView.selectedRange()) {
            return selected
        }

        return RichMarkdownEditor.selectedText()
    }
}

/// Floating playback bar shown when TTS is active. Shows play/pause, stop, progress, and voice name.
struct TTSPlayerView: View {
    @ObservedObject var tts: TextToSpeechService

    var body: some View {
        if tts.state != .idle {
            HStack(spacing: 12) {
                if tts.state == .loading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating speech...")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button {
                        tts.togglePlayPause()
                    } label: {
                        Image(systemName: tts.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tts.state == .playing ? "Pause speech" : "Resume speech")
                    .help(tts.state == .playing ? "Pause speech" : "Resume speech")

                    ProgressView(value: tts.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                        .tint(.accentColor)

                    Text(tts.selectedVoice.capitalized)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                Button {
                    tts.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop speech")
                .help("Stop speech")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 8)
        }

        if let error = tts.error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                Spacer()
                Button("Dismiss") { tts.error = nil }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 4)
        }
    }
}

/// An in-memory draft for listening to pasted text through the configured AI voice.
struct ReadToMeView: View {
    @Environment(\.commandCenterLayout) private var layout
    @Binding var text: String
    @ObservedObject var tts: TextToSpeechService
    @AppStorage("ttsVoice") private var voice = "nova"

    private var isBusy: Bool { tts.state != .idle }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Read to Me")
                        .font(.system(size: layout.titleFontSize, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Paste text, choose a voice, and listen.")
                        .font(.system(size: layout.bodyFontSize))
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 12) {
                    Button("Paste") {
                        if let pastedText = NSPasteboard.general.string(forType: .string) {
                            text = pastedText
                        }
                    }
                    .disabled(isBusy)
                    Button("Clear") {
                        text = ""
                        tts.error = nil
                    }
                    .disabled(text.isEmpty || isBusy)
                    Spacer()
                    Picker("Voice", selection: $voice) {
                        ForEach(TextToSpeechService.voices, id: \.self) { voice in
                            Text(voice.capitalized).tag(voice)
                        }
                    }
                    .frame(width: 170)
                    .disabled(isBusy)
                }
                .buttonStyle(.bordered)

                TextEditor(text: $text)
                    .font(.system(size: layout.bodyFontSize))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 280)
                    .background(Theme.notionSurfaceBG, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    .accessibilityLabel("Text to read")
                    .disabled(isBusy)

                HStack {
                    Button {
                        tts.speak(text)
                    } label: {
                        Label("Read to Me", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    Spacer()
                    Text("\(text.count.formatted()) characters")
                        .font(.system(size: layout.smallFontSize))
                        .foregroundStyle(Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(tts.connectionDescription)
                    Text("AI-generated voice. Text is sent for speech only when you press Read to Me. Your draft is kept only for this app session.")
                }
                .font(.system(size: layout.smallFontSize))
                .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.notionWindowBG)
    }
}

/// A simple "Read Aloud" button to place in page headers.
struct ReadAloudButton: View {
    @ObservedObject var tts: TextToSpeechService
    let text: String

    var body: some View {
        Button {
            if tts.state != .idle {
                tts.stop()
            } else {
                tts.speak(ReadAloudTextResolver.textToRead(fallback: text))
            }
        } label: {
            Label(
                tts.state != .idle ? "Stop" : "Read Aloud",
                systemImage: tts.state != .idle ? "stop.circle" : "speaker.wave.2"
            )
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(tts.state != .idle ? Color.orange : Theme.textSecondary)
    }
}
