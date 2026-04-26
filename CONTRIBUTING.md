# Contributing

## Development Setup

1. Install Xcode 15+ and Command Line Tools.
2. Open `NoteAI.xcodeproj` or build from CLI.
3. Use the `NoteAI` scheme for app development.

## Code Guidelines

- Keep changes focused and minimal.
- Prefer SwiftUI composition and clear state ownership.
- Avoid introducing plaintext secret storage.
- Add comments only where logic is non-obvious.
- Put reusable Swift workflow/search/AI parsing behavior in `MeetingCaptureWorkflow`, `LibraryOperations`, and `AITasks`.
- Put reusable web entity, recording, AI, and assistant-action behavior in `web/src/lib/*` modules instead of embedding it in React components.

## Validation Before PR

- Swift tests:
  - `swift test`
- Web lint/type/build:
  - `cd web && npm run lint`
  - `cd web && npx tsc --noEmit --pretty false`
  - `cd web && npm run build`
- Confirm no accidental artifacts are included.

## Commit Hygiene

- Use descriptive commit messages focused on intent.
- Keep security-sensitive changes explicit in PR descriptions.
- Do not commit local machine state, generated build output, or logs.
