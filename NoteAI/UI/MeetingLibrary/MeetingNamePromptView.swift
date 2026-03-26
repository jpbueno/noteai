import SwiftUI

/// Shown when the user stops recording. Lets them name the meeting before processing begins.
struct MeetingNamePromptView: View {
    @Binding var suggestedName: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textSecondary)

            Text("Name Your Meeting")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("This name will appear in the sidebar and is searchable.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            TextField("Meeting name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .onSubmit { save() }

            HStack(spacing: 12) {
                Button("Use Default") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)

                Button("Save & Process") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 380)
        .onAppear {
            name = suggestedName
        }
    }

    private func save() {
        onSave(name)
    }
}
