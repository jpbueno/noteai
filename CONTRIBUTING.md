# Contributing

## Development Setup

1. Install Xcode 15+ and Command Line Tools.
2. Open `NoteAI.xcodeproj` or build from CLI.
3. Use the `NoteAI` scheme for app development.
4. For web work, run `cd web && npm install`.

## Code Guidelines

- Keep changes focused and minimal.
- Prefer SwiftUI composition and clear state ownership.
- Avoid introducing plaintext secret storage.
- Add comments only where logic is non-obvious.
- Put reusable Swift workflow/search/AI parsing behavior in `MeetingCaptureWorkflow`, `LibraryOperations`, and `AITasks`.
- Put reusable web entity, recording, AI, and assistant-action behavior in `web/src/lib/*` modules instead of embedding it in React components.

## Validation Before PR

- Repository hygiene:
  - `node --test scripts/ci-coverage-parity.test.mjs scripts/repository-hygiene.test.mjs`
- Swift tests:
  - `swift test`
- Web lint/type/build:
  - `cd web && npm run lint`
  - `cd web && npx tsc --noEmit --pretty false`
  - `cd web && npm run build`
- Confirm no accidental artifacts are included.

## Repository Hygiene

Keep the repository professional and easy for other contributors to review:

- Commit source code, tests, docs, and reviewed configuration.
- Do not commit local meeting data, transcripts, databases, `.env*` files, logs, screenshots, temporary previews, generated decks, or build output.
- Use `scratch/` for local experiments and `output/` for generated reports or exports; both are ignored.
- Keep secrets in Keychain, GitHub secrets, Turso/Cloudflare secret stores, or local ignored env files.
- If a fixture is needed for a test, keep it minimal, anonymized, and explain why it belongs in Git.

## Commit Hygiene

- Use descriptive commit messages focused on intent.
- Keep security-sensitive changes explicit in PR descriptions.
- Do not commit local machine state, generated build output, or logs.
