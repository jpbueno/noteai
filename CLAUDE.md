# NoteAI - Claude Code Guide

## Project Overview

Meeting intelligence platform for macOS — SwiftUI menu bar app, on-device WhisperKit transcription, and local GRDB (SQLite) persistence.

The app supports: meeting recording/transcription, LLM summarization, notes, tasks, T5T reports, AI chat, TTS playback.

The web version was permanently retired in JPB-191. NoteAI is a macOS application; there is no supported web client, web API, web deployment, or Turso migration workflow. Reintroducing a web product requires a new explicit product decision and security review.

---

## macOS App (`NoteAI/`)

**Target**: macOS 14.2+ | **Swift**: 5.9 | **Bundle ID**: `com.noteai.app`

### Architecture: MVVM + Actor-Based Services + Deep Domain Modules

```
NoteAI/
  App/              # Entry point, AppDelegate, MeetingManager, MeetingCaptureWorkflow
  Audio/            # ProcessTap, ScreenCaptureKit, mic capture, ring buffer, TTS
  Transcription/    # WhisperKit engine (actor-based, hallucination filtering)
  Summarization/    # LLM abstraction, AI task parsing/formatting
  MeetingDetection/ # Auto-detect Teams/browser audio activity
  Storage/          # GRDB persistence, repositories, library operations, models
  Auth/             # Google OAuth 2.0 + PKCE, Keychain, API key management
  Delivery/         # Export (Markdown/JSON), Notion import, notifications
  UI/               # SwiftUI views organized by feature area
```

### Key Components
- **MeetingManager** (`App/MeetingManager.swift`) — UI-bound state orchestrator; delegates reusable workflow/search/AI parsing behavior to deeper modules
- **MeetingCaptureWorkflow** (`App/MeetingCaptureWorkflow.swift`) — Transcript text formatting, summary fallback, and meeting completion helpers
- **LibraryOperations** (`Storage/LibraryOperations.swift`) — Search, date-range selection, and T5T default title behavior
- **AITasks** (`Summarization/AITasks.swift`) — JSON extraction, meeting summary parsing, T5T parsing, and summary prompt formatting
- **Repositories** (`Storage/Repositories.swift`) — Protocol seams for meetings, notes, tasks, and T5T persistence
- **TranscriptionEngine** (`Transcription/TranscriptionEngine.swift`) — Actor, WhisperKit with hallucination filtering
- **SummarizationEngine** (`Summarization/SummarizationEngine.swift`) — Multi-provider LLM, template-based prompts
- **MeetingStore** (`Storage/MeetingStore.swift`) — GRDB persistence layer, CRUD for all models
- **ChatManager** (`UI/Chat/ChatManager.swift`) — Chat orchestrator with JSON action parsing
- **AudioCaptureManager** (`Audio/AudioCaptureManager.swift`) — Coordinates ProcessTap + ScreenCaptureKit + mic

### macOS Data Flow
1. Audio in: ProcessTap (macOS 14.2+) or ScreenCaptureKit fallback + Microphone
2. AudioBufferRing accumulates 7-second chunks, resampled to 16kHz mono
3. WhisperKit transcription with rolling context + hallucination filtering
4. LLM summarization (structured JSON: decisions, action items, topics, questions)
5. GRDB persistence, optional auto-export to vault directory

### macOS Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| WhisperKit | 0.9.0+ | On-device speech-to-text (Apple Neural Engine) |
| GRDB.swift | 6.24.0+ | SQLite persistence layer |

System frameworks: SwiftUI, AVFoundation, CoreAudio, ScreenCaptureKit, Security, Accelerate, Combine, UserNotifications, AppKit

### Build & Run (macOS)

```bash
# Build
xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -configuration Debug build

# Run
open .xcode-build/Build/Products/Debug/NoteAI.app

# Deploy locally
ditto ".xcode-build/Build/Products/Debug/NoteAI.app" "/Applications/NoteAI.app"

# Tests
xcodebuild -project NoteAI.xcodeproj -scheme NoteAI test
```

Project is managed via `project.yml` (XcodeGen). Regenerate Xcode project with `xcodegen generate` if project.yml changes.

---

## Domain Models

The native app uses Swift `Codable` models:

| Model | Key Fields |
|-------|------------|
| **Meeting** | id, title, date, duration, transcript: TranscriptSegment[], summary: MeetingSummary |
| **Note** | id, title, content (markdown), tags[], sourceMeetingID? |
| **TaskItem** | id, title, description, rawInput, status (pending/completed), sourceMeetingID? |
| **T5TReport** | id, title, periodStart/End, sections (insights/accountUpdates/futurePlans), status (draft/finalized) |
| **ChatMessage** | id, role (user/assistant/system), content, timestamp |

**MeetingSummary**: decisions[], actionItems[] (task, owner, deadline, isCompleted), topics[], openQuestions[]

**Meeting templates**: auto, general, standup, sales, oneOnOne, brainstorm

**LLM providers**: OpenRouter, Anthropic, OpenAI, NVIDIA

---

## Conventions

### Swift (macOS)
- Use `@MainActor` for UI-bound classes, `actor` for thread-safe services
- Models are `Codable` + `Identifiable`, stored as JSON in GRDB
- Use `@ObservedObject` / `@EnvironmentObject` for SwiftUI state binding
- Prefer `async/await` over Combine for new async work
- Secrets go in Keychain via `KeychainHelper`, never UserDefaults
- Put reusable workflow/search/AI parsing behavior in `MeetingCaptureWorkflow`, `LibraryOperations`, or `AITasks` instead of growing `MeetingManager`

### UI (macOS)
- Dark mode Notion-like palette (`UI/Theme.swift`)
- macOS: MenuBarExtra + Settings scene, modal sheets for creation/config

### Storage
- macOS: GRDB `DatabaseQueue`, JSON encoding for complex nested types

---

## Known Patterns & Gotchas

### macOS
- ProcessTap requires macOS 14.2+ and Screen Recording permission
- WhisperKit models download on first use — handle the loading state
- Hallucination filtering in TranscriptionEngine uses 25+ regex patterns — be careful modifying
- AudioBufferRing uses Accelerate.framework for RMS normalization — performance-sensitive
- Google OAuth uses a localhost HTTP server for callback — port conflicts possible
- API keys migrated from UserDefaults to Keychain — migration code in KeychainHelper

## Test Coverage
- macOS: `NoteAITests/` includes storage, architecture, AI coach, recording, helper, integration, and Teams call tests.
- Preserve `SharedTests/coach-admission-contract-v1.json`; native AI coach tests load this fixture.
