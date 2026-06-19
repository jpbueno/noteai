import SwiftUI

@main
struct NoteAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(meetingManager: appDelegate.meetingManager)
        } label: {
            MenuBarIcon(state: appDelegate.meetingManager.state)
        }

        Settings {
            SettingsView(authManager: appDelegate.authManager)
                .environmentObject(appDelegate.meetingManager)
        }
    }
}

struct MenuBarIcon: View {
    let state: MeetingManager.State

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "brain.head.profile")
        case .recording:
            Image(systemName: "record.circle")
                .symbolRenderingMode(.multicolor)
        case .processing:
            Image(systemName: "brain.head.profile")
                .symbolRenderingMode(.multicolor)
        }
    }
}
