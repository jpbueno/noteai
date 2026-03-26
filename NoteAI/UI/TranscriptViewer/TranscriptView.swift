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
struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(segments.count) segments")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(segments) { segment in
                            Text(segment.text)
                                .font(.system(size: Theme.bodySize))
                                .foregroundStyle(Theme.textPrimary)
                                .lineSpacing(4)
                                .padding(.vertical, 2)
                                .id(segment.id)
                        }
                    }
                    .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: segments.count) { _, _ in
                    if let last = segments.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Theme.contentBG)
    }
}
