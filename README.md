# NoteAI

Meeting intelligence app for macOS — SwiftUI menu bar app, on-device WhisperKit transcription, and local GRDB persistence.

Features include: meeting recording/transcription, LLM summarization, notes, tasks, T5T reports, AI chat, TTS playback.

The web version was permanently retired in JPB-191. NoteAI is a macOS application; there is no supported web client, web API, web deployment, or Turso migration workflow. Reintroducing a web product requires a new explicit product decision and security review.

## Features

- Record and transcribe meetings (mic + system audio capture)
- Structured AI summaries with decisions, action items, topics, and open questions
- Rich text notes with markdown, tags, and meeting linking
- Task management with AI summarization
- T5T (Top 5 Things) report generation from meetings, notes, and tasks
- AI chat sidebar for querying meeting content
- Text-to-speech playback
- Configurable LLM backends (OpenRouter, Anthropic, OpenAI, NVIDIA)

## Project Layout

```
NoteAI/                   macOS app source (SwiftUI + GRDB + WhisperKit)
  App/                    App entry, MeetingManager, meeting capture workflow
  Storage/                GRDB store, typed repositories, library operations
  Summarization/          LLM provider clients and AI task parsing/formatting
NoteAITests/              macOS unit tests
NoteAI.xcodeproj/         Xcode project
Package.swift             Swift Package manifest
docs/                     Architecture, CI, release, storage, and security runbooks
SharedTests/              Fixtures used by native tests
tools/work_activity/      Work activity tooling and approval automation
scripts/                  Repository CI and hygiene checks
```

### Architecture Notes

The app keeps UI orchestration thin by pushing reusable behavior into deeper domain modules:

- **macOS**: `MeetingCaptureWorkflow` owns transcript formatting and meeting completion helpers; `LibraryOperations` owns search/range/default-title behavior; `AITasks` owns JSON extraction, prompt formatting, and summary/T5T parsing; repository protocols document the persistence seams around `MeetingStore`.

## Tech Stack

### macOS App
- Swift 5.9 + SwiftUI (macOS 14.2+)
- GRDB (SQLite persistence)
- WhisperKit (on-device transcription via Apple Neural Engine)
- ProcessTap / ScreenCaptureKit for system audio capture

---

## macOS App

Live recording shows speaker labels without asking you to identify speakers. After the meeting, edit speaker details in the transcript and regenerate the summary to use the updated context.

### Build & Run

```bash
xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -configuration Debug build
open .xcode-build/Build/Products/Debug/NoteAI.app
```

### Deploy to /Applications

```bash
xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -configuration Debug build
ditto ".xcode-build/Build/Products/Debug/NoteAI.app" "/Applications/NoteAI.app"
```

### Requirements
- macOS 14.2+
- Screen Recording permission (for system audio capture)
- Microphone permission

---

## Security Notes

- **macOS**: LLM API keys stored in macOS Keychain, never UserDefaults
- Do not commit `.env*` files or build artifacts

## Repository Hygiene

This repository should contain source, tests, docs, and reviewed configuration only. Keep local exports and experiments outside Git:

- `output/` is for generated reports, decks, QR cards, and other throwaway exports.
- `scratch/` is for local investigation artifacts, screenshots, previews, and temporary analysis output.
- `.xcode-build/`, `.build/`, `DerivedData/`, logs, local databases, and `.env*` files are ignored.

Run the lightweight hygiene check before sharing a cleanup PR:

```bash
node --test scripts/repository-hygiene.test.mjs
```

## Validation

```bash
swift test
node --test scripts/ci-coverage-parity.test.mjs scripts/repository-hygiene.test.mjs
```

See [docs/release-checklist.md](docs/release-checklist.md) for the full pre-release checklist and release notes template.
