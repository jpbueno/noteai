import SwiftUI

/// Presentation adapter for the compatibility timeline exposed by MeetingManager.
/// Auto insights and chat remain separate after this seam.
struct CoachPanelPresentation {
    let activeInsights: [CoachInsight]
    let historyInsights: [CoachInsight]
    let chatMessages: [CoachInsight]
    let autoInsightCount: Int

    init(entries: [CoachInsight]) {
        let autoInsights = entries.filter { $0.role == nil }

        activeInsights = autoInsights
            .filter { $0.lifecycle == .active }
            .sorted(by: Self.activeInsightOrder)
        historyInsights = autoInsights
            .filter { $0.lifecycle != .active }
            .sorted(by: Self.newestFirst)
        chatMessages = entries
            .filter { $0.role != nil }
            .sorted(by: Self.oldestFirst)
        autoInsightCount = autoInsights.count
    }

    static func primaryEvidence(for insight: CoachInsight) -> CoachEvidenceReference? {
        guard insight.role == nil, insight.basis == .transcript else { return nil }
        return insight.evidence.first
    }

    private static func activeInsightOrder(_ lhs: CoachInsight, _ rhs: CoachInsight) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return newestFirst(lhs, rhs)
    }

    private static func newestFirst(_ lhs: CoachInsight, _ rhs: CoachInsight) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func oldestFirst(_ lhs: CoachInsight, _ rhs: CoachInsight) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum CoachPanelScrollTarget: Hashable {
    case chatSection
    case message(UUID)
    case thinking
}

struct CoachPanelScrollRequest: Equatable {
    let sequence: Int
    let target: CoachPanelScrollTarget
}

/// Keeps chat follow-scrolling scoped to an exchange the user explicitly started.
struct CoachPanelChatScrollState {
    private(set) var isFollowingSubmittedExchange = false
    private(set) var latestRequest: CoachPanelScrollRequest?
    private var sequence = 0

    @discardableResult
    mutating func submitQuestion() -> CoachPanelScrollRequest {
        isFollowingSubmittedExchange = true
        return request(.chatSection)
    }

    @discardableResult
    mutating func chatMessagesChanged(to messages: [CoachInsight]) -> CoachPanelScrollRequest? {
        guard let message = messages.last else { return nil }

        let scrollRequest = request(.message(message.id))
        if message.role == .assistant {
            isFollowingSubmittedExchange = false
        }
        return scrollRequest
    }

    @discardableResult
    mutating func replyStateChanged(isReplying: Bool) -> CoachPanelScrollRequest? {
        guard isFollowingSubmittedExchange, isReplying else { return nil }
        return request(.thinking)
    }

    private mutating func request(_ target: CoachPanelScrollTarget) -> CoachPanelScrollRequest {
        sequence += 1
        let request = CoachPanelScrollRequest(sequence: sequence, target: target)
        latestRequest = request
        return request
    }
}

/// Right-hand working panel shown during live recording.
struct CoachPanelView: View {
    let insights: [CoachInsight]
    let isAnalyzing: Bool
    let isReplying: Bool
    let onSend: (String) -> Void
    let onSetLifecycle: (UUID, CoachInsightLifecycle) -> Void
    let onShowSource: (CoachEvidenceReference) -> Void

    @State private var input: String = ""
    @State private var chatScrollState = CoachPanelChatScrollState()
    @FocusState private var inputFocused: Bool

    private var presentation: CoachPanelPresentation {
        CoachPanelPresentation(entries: insights)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle().fill(Theme.border).frame(height: 1)

            contentArea

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
                ProgressView()
                    .controlSize(.mini)
                    .help("Analyzing transcript")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private var contentArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    liveGuidanceSection

                    if !presentation.historyInsights.isEmpty {
                        sectionDivider
                        historySection
                    }

                    sectionDivider
                    chatSection
                }
                .padding(.vertical, 6)
            }
            .onChange(of: presentation.chatMessages.map(\.id)) { _, _ in
                chatScrollState.chatMessagesChanged(to: presentation.chatMessages)
            }
            .onChange(of: isReplying) { _, newValue in
                chatScrollState.replyStateChanged(isReplying: newValue)
            }
            .onChange(of: chatScrollState.latestRequest) { _, request in
                guard let request else { return }
                scrollToChat(request, using: proxy)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToChat(_ request: CoachPanelScrollRequest, using proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(
                request.target,
                anchor: request.target == .chatSection ? .top : .bottom
            )
        }
    }

    private var liveGuidanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Live guidance",
                systemImage: "bolt.fill",
                count: presentation.activeInsights.count
            )

            if presentation.activeInsights.isEmpty {
                sectionEmptyState(isAnalyzing ? "Reviewing the latest transcript..." : "No active guidance")
            } else {
                ForEach(presentation.activeInsights) { insight in
                    insightRow(insight, isActive: true)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Insight history",
                systemImage: "clock.arrow.circlepath",
                count: presentation.historyInsights.count
            )

            ForEach(presentation.historyInsights) { insight in
                insightRow(insight, isActive: false)
            }
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Chat", systemImage: "bubble.left.and.bubble.right", count: nil)

            if presentation.chatMessages.isEmpty && !isReplying {
                sectionEmptyState("No chat yet")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation.chatMessages) { message in
                        chatEntry(message)
                            .id(CoachPanelScrollTarget.message(message.id))
                    }

                    if isReplying {
                        thinkingBubble
                            .id(CoachPanelScrollTarget.thinking)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .id(CoachPanelScrollTarget.chatSection)
    }

    private func sectionHeader(_ title: String, systemImage: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(Theme.sectionHeader)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func sectionEmptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }

    // MARK: - Insight Rows

    private func insightRow(_ insight: CoachInsight, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(color(for: insight.type))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: insight.type.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                    Text(insight.type.label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                    Spacer(minLength: 0)
                    if insight.priority == .critical {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .help("Critical guidance")
                    }
                }
                .foregroundStyle(color(for: insight.type))

                Text(insight.content)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 7) {
                    if let evidence = CoachPanelPresentation.primaryEvidence(for: insight) {
                        sourceButton(evidence)
                    }

                    Spacer(minLength: 0)

                    if isActive {
                        lifecycleButton(
                            insight,
                            lifecycle: .resolved,
                            systemImage: "checkmark.circle",
                            help: "Resolve insight"
                        )
                        lifecycleButton(
                            insight,
                            lifecycle: .dismissed,
                            systemImage: "xmark",
                            help: "Dismiss insight"
                        )
                    } else {
                        Text(lifecycleLabel(insight.lifecycle))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        lifecycleButton(
                            insight,
                            lifecycle: .active,
                            systemImage: "arrow.counterclockwise",
                            help: "Reactivate insight"
                        )
                    }
                }
                .frame(minHeight: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.7))
                .frame(height: 0.5)
                .padding(.leading, 22)
        }
    }

    private func sourceButton(_ evidence: CoachEvidenceReference) -> some View {
        Button {
            onShowSource(evidence)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.quote")
                    .font(.system(size: 9, weight: .semibold))
                Text(formatEvidenceTime(evidence.startTime))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .frame(height: 20)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Show transcript source at \(formatEvidenceTime(evidence.startTime))")
    }

    private func lifecycleButton(
        _ insight: CoachInsight,
        lifecycle: CoachInsightLifecycle,
        systemImage: String,
        help: String
    ) -> some View {
        Button {
            onSetLifecycle(insight.id, lifecycle)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Chat

    @ViewBuilder
    private func chatEntry(_ message: CoachInsight) -> some View {
        if message.role == .user {
            userBubble(message)
        } else {
            assistantBubble(message)
        }
    }

    private func userBubble(_ message: CoachInsight) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 24)
            Text(message.content)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
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

    private func assistantBubble(_ message: CoachInsight) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
            Text(message.content)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
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
                Text("Thinking...")
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

    // MARK: - Input

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask the SA a question...", text: $input, axis: .vertical)
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
            .help("Send message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying else { return }
        chatScrollState.submitQuestion()
        onSend(trimmed)
        input = ""
    }

    // MARK: - Presentation

    private func lifecycleLabel(_ lifecycle: CoachInsightLifecycle) -> String {
        switch lifecycle {
        case .active: return "Active"
        case .dismissed: return "Dismissed"
        case .resolved: return "Resolved"
        case .expired: return "Expired"
        }
    }

    private func formatEvidenceTime(_ seconds: Float) -> String {
        let totalSeconds = max(0, Int(seconds))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

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
