import SwiftUI

enum ChatPanelPerformancePolicy {
    static let messageTextSelectionEnabled = false
    static let animatedAutoScrollEnabled = false
}

/// Floating AI assistant chat panel.
struct ChatPanelView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var chatManager: ChatManager
    var onClose: (() -> Void)?
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                Text("NoteAI Assistant")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { chatManager.clearChat() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                Button { onClose?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.sidebarBG)

            Divider().foregroundStyle(Theme.border)

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chatManager.messages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }

                        if chatManager.isTyping {
                            HStack(spacing: 6) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.accentColor)
                                Text("Thinking...")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .id("typing")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: chatManager.messages.count) { _, _ in
                    scrollToLatestMessage(using: proxy)
                }
            }

            Divider().foregroundStyle(Theme.border)

            // Input
            if let setupMessage = chatManager.setupMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("AI setup required", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(setupMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        Button {
                            openSettings()
                        } label: {
                            Label("Open AI Settings", systemImage: "gearshape")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            chatManager.refreshConfigurationPreflight()
                        } label: {
                            Label("Check Again", systemImage: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.sidebarBG)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask anything...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }

                Button { sendMessage() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(inputText.isEmpty ? Theme.textTertiary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatManager.isTyping || chatManager.setupMessage != nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.sidebarBG)
        }
        .background(Theme.contentBG)
        .onAppear {
            chatManager.refreshConfigurationPreflight()
            inputFocused = chatManager.setupMessage == nil
        }
    }

    private func chatBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .chatMessageTextSelection()
            } else if message.role == .system {
                Image(systemName: "gear")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 3)
                Text(message.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(8)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 8))
                    .chatMessageTextSelection()
                Spacer(minLength: 20)
            } else {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 3)
                assistantBubbleContent(message.content)
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 12)
    }

    private func assistantBubbleContent(_ content: String) -> some View {
        let sourceLinks = extractSourceLinks(from: content)
        return VStack(alignment: .leading, spacing: 8) {
            Text(content)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .chatMessageTextSelection()

            if !sourceLinks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sourceLinks, id: \.urlString) { link in
                        Button {
                            NotificationCenter.default.post(name: .navigateToSource, object: link.urlString)
                        } label: {
                            Text(link.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)
                assistantMessageCopyButton(content)
            }
        }
        .padding(10)
        .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button {
                copyAssistantMessageContent(content)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private func assistantMessageCopyButton(_ content: String) -> some View {
        Button {
            copyAssistantMessageContent(content)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Theme.contentBG.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy assistant response")
    }

    private func sendMessage() {
        let text = inputText
        inputText = ""
        chatManager.send(text)
    }

    private func scrollToLatestMessage(using proxy: ScrollViewProxy) {
        guard let lastID = chatManager.messages.last?.id else { return }

        if ChatPanelPerformancePolicy.animatedAutoScrollEnabled {
            withAnimation {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func copyAssistantMessageContent(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private func extractSourceLinks(from content: String) -> [SourceChip] {
        let pattern = #"\[([^\]]+)\]\((noteai://[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        var seen = Set<String>()
        return regex.matches(in: content, range: nsRange).compactMap { match in
            guard match.numberOfRanges == 3,
                  let labelRange = Range(match.range(at: 1), in: content),
                  let urlRange = Range(match.range(at: 2), in: content)
            else { return nil }
            let urlString = String(content[urlRange])
            guard seen.insert(urlString).inserted,
                  ChatSourceLink(urlString: urlString) != nil
            else { return nil }
            return SourceChip(label: String(content[labelRange]), urlString: urlString)
        }
    }

    private struct SourceChip {
        let label: String
        let urlString: String
    }
}

private extension View {
    @ViewBuilder
    func chatMessageTextSelection() -> some View {
        if ChatPanelPerformancePolicy.messageTextSelectionEnabled {
            textSelection(.enabled)
        } else {
            self
        }
    }
}
