# NoteAI

NoteAI is a macOS app for recording meetings, transcribing audio, generating AI summaries, and creating T5T reports.

## Highlights

- Record and transcribe meetings (mic + app audio capture where permitted)
- Structured summaries with decisions, action items, topics, and open questions
- Notes and tasks linked to meetings
- T5T report generation from meetings, notes, and tasks
- Optional Google sign-in and Notion markdown import

## Tech Stack

- Swift + SwiftUI (macOS 14+)
- GRDB (SQLite persistence)
- WhisperKit (on-device transcription)
- Configurable LLM backends (OpenRouter, Anthropic, OpenAI, NVIDIA)

## Project Layout

- `NoteAI/` - application source code
- `NoteAITests/` - unit tests
- `NoteAI.xcodeproj/` - Xcode project
- `Package.swift` - Swift Package manifest for dependencies
- `generate_icon.swift` - app icon generation utility
- `simulate_meeting.swift` - local simulation utility
- `generate_previews.swift` - preview generation utility

## Build and Run (Xcode CLI)

```bash
xcodebuild -project "NoteAI.xcodeproj" -scheme "NoteAI" -configuration Debug -derivedDataPath ".xcode-build" build
open ".xcode-build/Build/Products/Debug/NoteAI.app"
```

## Deploy Local Build to /Applications

```bash
xcodebuild -project "NoteAI.xcodeproj" -scheme "NoteAI" -configuration Debug -derivedDataPath ".xcode-build" build
ditto ".xcode-build/Build/Products/Debug/NoteAI.app" "/Applications/NoteAI.app"
open -a "/Applications/NoteAI.app"
```

## Security Notes

- LLM API keys are stored in macOS Keychain.
- Legacy API keys previously stored in `UserDefaults` are migrated to Keychain on launch.
- OAuth tokens are stored in Keychain.
- Do not commit local build artifacts or generated runtime files.

See `SECURITY.md` for reporting and secure development guidance.
