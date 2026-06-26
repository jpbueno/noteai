import SwiftUI

struct TranscriptImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var transcript: String = ""

    let onImport: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import Teams Transcript")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Paste a Teams transcript to create a meeting summary without recording audio.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Title")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                TextField("Teams Transcript", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(10)
                    .background(Theme.sidebarBG, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                TextEditor(text: $transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.sidebarBG, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    .frame(minHeight: 260)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)

                Button {
                    onImport(title, transcript)
                    dismiss()
                } label: {
                    Label("Import & Summarize", systemImage: "text.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(Theme.contentBG)
    }
}
