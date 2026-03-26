import SwiftUI

/// Floating AI assistant chat panel.
struct ChatPanelView: View {
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
                    withAnimation {
                        if let lastID = chatManager.messages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                    }
                }
            }

            Divider().foregroundStyle(Theme.border)

            // Input
            HStack(spacing: 8) {
                TextField("Ask anything...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }

                Button { sendMessage() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(inputText.isEmpty ? Theme.textTertiary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatManager.isTyping)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.sidebarBG)
        }
        .background(Theme.contentBG)
        .onAppear { inputFocused = true }
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
                    .textSelection(.enabled)
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
                    .textSelection(.enabled)
                Spacer(minLength: 20)
            } else {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 3)
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 12)
    }

    private func sendMessage() {
        let text = inputText
        inputText = ""
        chatManager.send(text)
    }
}

