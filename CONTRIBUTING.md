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

## Validation Before PR

- Build succeeds:
  - `xcodebuild -project "NoteAI.xcodeproj" -scheme "NoteAI" -configuration Debug -derivedDataPath ".xcode-build" build`
- Run tests:
  - `xcodebuild -project "NoteAI.xcodeproj" -scheme "NoteAI" -configuration Debug -derivedDataPath ".xcode-build" test`
- Confirm no accidental artifacts are included.

## Commit Hygiene

- Use descriptive commit messages focused on intent.
- Keep security-sensitive changes explicit in PR descriptions.
- Do not commit local machine state, generated build output, or logs.
