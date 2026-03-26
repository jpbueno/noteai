import SwiftUI

/// Full-screen login view shown when user is not authenticated.
struct LoginView: View {
    @ObservedObject var authManager: GoogleAuthManager

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Logo
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.textSecondary)

                Text("NoteAI")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Text("AI-powered meeting notes.\nRecord, transcribe, and summarize automatically.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 40)

                // Sign in button
                Button {
                    authManager.signIn()
                } label: {
                    HStack(spacing: 10) {
                        if authManager.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            // Google "G" icon approximation
                            ZStack {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 22, height: 22)
                                Text("G")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.red, .yellow, .green, .blue],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                        }
                        Text("Sign in with Google")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color(hex: "333333"), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "444444"), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(authManager.isLoading)

                // Skip option
                Button {
                    // Allow using without auth
                    UserDefaults.standard.set(true, forKey: "skippedAuth")
                    authManager.isAuthenticated = true
                } label: {
                    Text("Continue without signing in")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .underline()
                }
                .buttonStyle(.plain)

                // Error
                if let error = authManager.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            Spacer()

            // Footer
            Text("Your meeting data stays on your Mac. Audio is processed on-device.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBG)
    }
}
