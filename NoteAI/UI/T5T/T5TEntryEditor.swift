import SwiftUI

/// Inline editor for a single T5T entry (headline + explanation).
struct T5TEntryEditor: View {
    @Binding var entry: T5TEntry
    var onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Headline (action-oriented)", text: $entry.headline)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    ZStack(alignment: .topLeading) {
                        if entry.explanation.isEmpty {
                            Text("2-3 sentence explanation...")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.top, 2)
                        }
                        TextEditor(text: $entry.explanation)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 40, maxHeight: 80)
                    }
                }

                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isHovering ? Theme.hoverBG : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovering = $0 }
    }
}
