import SwiftUI

// MeetingDetailView is no longer used — NotionPageView replaces it.
// Kept as a thin redirect for any remaining references.
struct MeetingDetailView: View {
    @State var meeting: Meeting

    var body: some View {
        NotionPageView(meeting: meeting)
    }
}
