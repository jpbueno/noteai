import SwiftUI

/// Right-hand panel shown during live recording. Mixes auto-generated
/// insights from the AI Solutions Architect with conversational chat
/// messages (user ↔ assistant). Mirrors web/src/components/CoachPanel.tsx.
struct CoachPanelView: View {
    let insights: [CoachInsight]
    let isAnalyzing: Bool
    let isReplying: Bool
    let onSend: (String) -> Void

    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle().fill(Theme.border).frame(height: 1)

            messagesArea

            Rectangle().fill(Theme.border).frame(height: 1)

            inputArea
        }
        .background(Theme.sidebarBG)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            Text("AI Solutions Architect")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(AICoachEngine.version)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5))
            Spacer(minLength: 0)
            if isAnalyzing {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Analyzing")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if insights.isEmpty {
                        emptyState
                    } else {
                        ForEach(insights) { item in
                            entryView(item)
                                .id(item.id)
                        }
                    }
                    if isReplying {
                        thinkingBubble.id("__thinking")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: insights.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: isReplying) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if isReplying {
                proxy.scrollTo("__thinking", anchor: .bottom)
            } else if let last = insights.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 24))
                .foregroundStyle(Theme.textTertiary.opacity(0.6))
            Text("AI Solutions Architect will provide real-time insights as the conversation progresses…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            Text("Or ask a question below to chat directly.")
                .font(.system(size: 10, weight: .medium))
                .italic()
                .foregroundStyle(Theme.textTertiary.opacity(0.85))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func entryView(_ insight: CoachInsight) -> some View {
        if insight.role == .user {
            userBubble(insight)
        } else if insight.role == .assistant {
            assistantBubble(insight)
        } else {
            insightCard(insight)
        }
    }

    private func userBubble(_ insight: CoachInsight) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 24)
            Text(insight.content)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                )
            Image(systemName: "person.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
        }
    }

    private func assistantBubble(_ insight: CoachInsight) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
            Text(insight.content)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.hoverBG.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
            Spacer(minLength: 24)
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Thinking…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.hoverBG.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
            Spacer()
        }
    }

    private func insightCard(_ insight: CoachInsight) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(color(for: insight.type))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: insight.type.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                    Text(insight.type.label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                }
                .foregroundStyle(color(for: insight.type))

                Text(insight.content)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.hoverBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Input

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask the SA a question…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))
                .focused($inputFocused)
                .disabled(isReplying)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        (input.trimmingCharacters(in: .whitespaces).isEmpty || isReplying)
                            ? Theme.textTertiary.opacity(0.35)
                            : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isReplying)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying else { return }
        onSend(trimmed)
        input = ""
    }

    // MARK: - Colors

    private func color(for type: CoachInsightType) -> Color {
        switch type {
        case .keyInsight: return Color(hex: "4A90E2")
        case .talkingPoint: return Color(hex: "3BB273")
        case .technicalAnswer: return Color.accentColor
        case .actionItem: return Color(hex: "E8974F")
        case .followUp: return Color(hex: "9B72E0")
        }
    }
}
