import SwiftUI

// SummaryCardView is kept for compatibility but the summary
// is now rendered inline in NotionPageView. This is a simplified version.
struct SummaryCardView: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if summary.isEmpty {
                Text("No summary available")
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// Kept for backward compatibility
struct SummarySection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: Theme.h3Size, weight: .semibold))
            content()
        }
    }
}
