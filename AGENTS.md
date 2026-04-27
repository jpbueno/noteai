# NoteAI - Codex Guide

## Required Linear Workflow

Linear is the source of truth and second brain for NoteAI work.

Every Codex agent working in this repository must keep Linear in sync for meaningful work. This includes features, bugs, functionality tests, security findings/remediation, codebase architecture improvements, refactors, documentation, deployment/release work, product decisions, and follow-up tasks.

Before or during work:
- Use the `Jpbueno` Linear team.
- Use the `NoteAI Product Roadmap` project by default unless a more specific NoteAI project exists.
- Find the relevant existing issue, or create one before implementation/test work continues.
- Move active implementation or test work to `In Progress` or `In Review` instead of leaving it only in chat.

After work:
- Update the relevant Linear issue with what changed, affected files/modules, verification commands/results, and remaining follow-ups.
- Create linked follow-up issues for discovered bugs, deferred risks, or new improvements.
- If the work spans several issues, add or update a worklog issue summarizing the session.

Delivery gate before `Done`:
- Do not move a NoteAI Linear issue to `Done` until repository delivery is complete.
- For any issue with repository changes, completion requires:
  - the intended changes are committed with the Linear issue ID in the commit message;
  - the branch is pushed to `origin`;
  - a pull request is opened and references the Linear issue ID;
  - required CI checks pass on the pull request;
  - the pull request is merged into `main`;
  - post-merge `main` checks are green, or no post-merge checks are applicable;
  - for web or deployment-impacting changes, the Cloudflare deploy workflow succeeds and the live app smoke check passes.
- If no repository changes are required, the Linear update must explicitly say `No repository changes required` and explain why.
- If Linear updates are blocked by connector or credential handling, still complete the git, CI, merge, and deployment path first, then provide the exact manual Linear update text for the user to paste.

Standing Linear anchor:
- `JPB-24` records this operating rule.
- `JPB-26` tracks the current functionality test session if no more specific test issue exists.

## Project Overview

Meeting intelligence platform — captures, transcribes, and summarizes meetings with AI. Two clients sharing the same feature set:

1. **macOS native app** — SwiftUI menu bar app, on-device WhisperKit transcription, GRDB (SQLite) persistence
2. **Web app** — Next.js 16 SPA, browser Web Audio + Speech Recognition, Turso (hosted SQLite) persistence

Both support: meeting recording/transcription, LLM summarization, notes, tasks, T5T reports, AI chat, TTS playback.

---

## macOS App (`NoteAI/`)

**Target**: macOS 14.2+ | **Swift**: 5.9 | **Bundle ID**: `com.noteai.app`

### Architecture: MVVM + Actor-Based Services

```
NoteAI/
  App/              # Entry point, AppDelegate, MeetingManager (central orchestrator)
  Audio/            # ProcessTap, ScreenCaptureKit, mic capture, ring buffer, TTS
  Transcription/    # WhisperKit engine (actor-based, hallucination filtering)
  Summarization/    # LLM abstraction (OpenRouter, Anthropic, OpenAI, NVIDIA)
  MeetingDetection/ # Auto-detect Teams/browser audio activity
  Storage/          # GRDB persistence, models (Meeting, Note, TaskItem, T5TReport, ChatMessage)
  Auth/             # Google OAuth 2.0 + PKCE, Keychain, API key management
  Delivery/         # Export (Markdown/JSON), Notion import, notifications
  UI/               # SwiftUI views organized by feature area
```

### Key Components
- **MeetingManager** (`App/MeetingManager.swift`) — Central state orchestrator (~650 lines), coordinates all services
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

## Web App (`web/`)

**Stack**: Next.js 16.2.1 | React 19 | TypeScript 5 | Tailwind CSS 4 | Tiptap | Turso

### Architecture: Single-Page Client App + API Routes

```
web/src/
  app/
    layout.tsx         # Root layout (dark theme, Geist fonts)
    page.tsx           # Main SPA shell — all UI state lives here
    globals.css        # Tailwind + dark theme vars + markdown styling
    api/
      chat/route.ts    # LLM chat proxy (OpenRouter, Anthropic, OpenAI, NVIDIA)
      data/[table]/route.ts  # Generic CRUD for all entity tables
      settings/route.ts      # Settings key-value store
      transcribe/route.ts    # Whisper transcription proxy
      tts/route.ts           # TTS audio generation proxy
  components/
    Sidebar.tsx        # Navigation, search, recording controls
    MeetingDetail.tsx  # Meeting viewer (summary/transcript/raw tabs)
    NoteEditor.tsx     # Tiptap rich text editor with markdown toggle
    TaskDetail.tsx     # Task editor with AI summarization
    T5TComposer.tsx    # T5T report builder with AI generation
    ChatPanel.tsx      # AI chat sidebar
    Settings.tsx       # 6-tab settings (AI, General, Export, Privacy, T5T, About)
    LiveTranscript.tsx # Real-time transcript during recording
    EditorToolbar.tsx  # Rich text formatting toolbar
    TTSPlayer.tsx      # Text-to-speech player
    extensions/
      ResizableImage.tsx  # Tiptap node extension for resizable images
  lib/
    types.ts           # All TypeScript interfaces (mirrors Swift models)
    db.ts              # Client-side API wrapper (REST calls to Next.js routes)
    server-db.ts       # Turso HTTP client (server-side only)
    hooks.ts           # Data fetching hooks (2s polling), recording, search
    ai.ts              # LLM integration (summarize, chat, transcribe)
    audio.ts           # Browser Web Audio API + Speech Recognition
    tts.ts             # TTS with chunking + prefetching
    content-utils.ts   # Markdown <-> HTML (marked + Turndown)
```

### Key Components
- **page.tsx** — SPA shell, manages selection state, layout (sidebar + content + chat panel)
- **Sidebar** — Navigation sections (T5T, Notes, Tasks, Meetings), search, record button
- **NoteEditor** — Tiptap editor with markdown source view, image drag-drop, tags
- **T5TComposer** — 3-section report builder (Insights, Account Updates, Future Plans) with source selection
- **Settings** — 6 tabs: AI provider/model/key, General, Export/Import, Privacy, T5T defaults, About

### Web Data Flow
1. Recording: Browser Web Audio API + SpeechRecognition → live transcript segments
2. On stop: audio blob → `/api/transcribe` (Whisper proxy) → full transcript
3. Summarization: transcript → `/api/chat` (LLM proxy) → structured JSON summary
4. Persistence: all data → `/api/data/[table]` → Turso SQLite (server-side)
5. Polling: `useRefreshable` hooks poll every 2s, `triggerRefresh()` for immediate updates

### Web Dependencies

| Package | Purpose |
|---------|---------|
| next 16.2.1 | App framework (App Router) |
| react 19.2.4 | UI framework |
| @tiptap/* | Rich text editor + extensions |
| marked | Markdown → HTML |
| turndown | HTML → Markdown |
| react-markdown + remark-gfm | Markdown rendering |
| lucide-react | Icons |
| uuid | ID generation |
| @tailwindcss/postcss | Styling |

### Build & Run (Web)

```bash
cd web

# Install
npm install

# Dev server
npm run dev

# Production build
npm run build && npm start
```

### Web Environment Variables
- `TURSO_DATABASE_URL` — Turso database URL
- `TURSO_AUTH_TOKEN` — Turso auth token

Deployed on **Vercel**. Cloudflare tunnel origins allowed for dev (`*.trycloudflare.com`).

---

## Shared Domain Models

Both platforms use the same data model (Swift `Codable` / TypeScript interfaces):

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

### TypeScript (Web)
- All components are `"use client"` — this is a client-rendered SPA
- Types defined in `lib/types.ts` — keep in sync with Swift models
- Data access via `lib/db.ts` wrapper → API routes → `lib/server-db.ts` → Turso
- External API calls (LLM, TTS, transcription) always proxied through API routes — never call from client
- Custom hooks in `lib/hooks.ts` for data fetching (2s polling pattern)
- Mutation pattern: call `db.*`, then `triggerRefresh()` for immediate UI update

### UI (Both platforms)
- Dark mode Notion-like palette (macOS: `UI/Theme.swift`, web: `globals.css` CSS vars)
- macOS: MenuBarExtra + Settings scene, modal sheets for creation/config
- Web: fixed sidebar + content area + optional chat panel, keyboard shortcuts (Cmd+Shift+R, Cmd+Shift+C, Cmd+K)

### Storage
- macOS: GRDB `DatabaseQueue`, JSON encoding for complex nested types
- Web: Turso HTTP v2 pipeline API, schema auto-created on first query, JSON columns for complex types

---

## Known Patterns & Gotchas

### macOS
- ProcessTap requires macOS 14.2+ and Screen Recording permission
- WhisperKit models download on first use — handle the loading state
- Hallucination filtering in TranscriptionEngine uses 25+ regex patterns — be careful modifying
- AudioBufferRing uses Accelerate.framework for RMS normalization — performance-sensitive
- Google OAuth uses a localhost HTTP server for callback — port conflicts possible
- API keys migrated from UserDefaults to Keychain — migration code in KeychainHelper

### Web
- Single `page.tsx` holds all app state — no route-based navigation
- Browser Speech Recognition is the primary transcription (no local Whisper) — quality varies by browser
- Turso is the only persistence — no IndexedDB fallback, no offline mode
- 2-second polling for data refresh — `triggerRefresh()` forces immediate update after mutations
- TTS uses chunked text (~250 chars) with 2-chunk prefetch for smooth playback
- API proxy pattern: all external calls (LLM, TTS, Whisper) go through `/api/*` routes

## Test Coverage
- macOS: minimal — `NoteAITests/MeetingStoreTests.swift` (CRUD + export formatting)
- Web: no tests yet
