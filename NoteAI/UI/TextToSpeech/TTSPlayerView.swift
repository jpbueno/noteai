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
