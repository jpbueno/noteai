# NoteAI

Meeting intelligence platform — captures, transcribes, and summarizes meetings with AI. Two clients sharing the same feature set:

1. **macOS native app** — SwiftUI menu bar app, on-device WhisperKit transcription, GRDB persistence
2. **Web app** — Next.js SPA, browser Web Audio + Speech Recognition, Turso (hosted SQLite) persistence

Both support: meeting recording/transcription, LLM summarization, notes, tasks, T5T reports, AI chat, TTS playback.

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
web/                      Web app source (Next.js + Turso)
  src/
    app/                  Pages, API routes
    components/           React components
    lib/                  Domain modules, hooks, audio, AI, typed repositories
  public/                 Static assets
NoteAI.xcodeproj/         Xcode project
Package.swift             Swift Package manifest
```

### Architecture Notes

The app keeps UI orchestration thin by pushing reusable behavior into deeper domain modules:

- **macOS**: `MeetingCaptureWorkflow` owns transcript formatting and meeting completion helpers; `LibraryOperations` owns search/range/default-title behavior; `AITasks` owns JSON extraction, prompt formatting, and summary/T5T parsing; repository protocols document the persistence seams around `MeetingStore`.
- **Web**: `recording-workflow.ts` owns recording completion and fallback behavior; `library.ts` owns entity drafts, search, source selection, and delete-selection rules; `ai-tasks.ts` owns prompt construction and response parsing; `assistant-actions.ts` owns AI action parsing/execution; `repositories.ts` provides typed persistence adapters over `db.ts`.

## Tech Stack

### macOS App
- Swift 5.9 + SwiftUI (macOS 14.2+)
- GRDB (SQLite persistence)
- WhisperKit (on-device transcription via Apple Neural Engine)
- ProcessTap / ScreenCaptureKit for system audio capture

### Web App
- Next.js 16 + React 19 + TypeScript 5
- Tailwind CSS 4
- Tiptap (rich text editor)
- Turso (hosted SQLite)
- Deployed on Cloudflare Workers via OpenNext

---

## macOS App

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

## Web App

### Local Development

```bash
cd web
npm install
npm run dev
```

Open http://localhost:3000.

### Environment Variables

Create `web/.env.local`:

```
TURSO_DATABASE_URL=libsql://your-db.turso.io
TURSO_AUTH_TOKEN=your-turso-token
NOTEAI_AUTH_SECRET=any-random-string
GOOGLE_CLIENT_ID=your-google-oauth-client-id
GOOGLE_ALLOWED_EMAILS=you@example.com
NOTEAI_API_KEY_HASHES=base64-sha256-of-programmatic-api-key
```

### Deploy to Cloudflare Workers

Production is deployed at: https://noteai-web.noteai-jp.workers.dev

```bash
cd web
npm run build:cf
npx wrangler deploy --env="" --keep-vars
```

Set production secrets on Cloudflare using interactive input:

```bash
npx wrangler secret put TURSO_DATABASE_URL --env=""
npx wrangler secret put TURSO_AUTH_TOKEN --env=""
npx wrangler secret put NOTEAI_AUTH_SECRET --env=""
npx wrangler secret put GOOGLE_CLIENT_ID --env=""
npx wrangler secret put GOOGLE_ALLOWED_EMAILS --env=""
npx wrangler secret put NOTEAI_API_KEY_HASHES --env=""
```

Preview deploys must use `--env preview` and preview-only Turso values. See `docs/security/cloudflare-turso-environment-separation.md`.

### API Access

The web app exposes a REST API for programmatic access (agents, scripts, etc.). Authenticate with a Bearer token whose SHA-256 digest is listed in `NOTEAI_API_KEY_HASHES`.

Generate a key locally, store only its base64 SHA-256 digest in `NOTEAI_API_KEY_HASHES`, and keep the raw key in your agent or script secret store:

```bash
printf '%s' 'your-long-random-api-key' | openssl dgst -sha256 -binary | openssl base64
```

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/data/notes` | List all notes |
| POST | `/api/data/notes` | Create/update a note |
| GET | `/api/data/tasks` | List all tasks |
| POST | `/api/data/tasks` | Create/update a task |
| GET | `/api/data/meetings` | List all meetings |
| GET | `/api/data/t5tReports` | List all T5T reports |
| POST | `/api/data/t5tReports` | Create/update a report |

All entity endpoints support `GET ?id=<id>` for single items and `DELETE ?id=<id>` for deletion.

---

## Security Notes

- **macOS**: LLM API keys stored in macOS Keychain, never UserDefaults
- **Web**: API keys stored server-side as Cloudflare Worker secrets, never exposed to the browser
- **Web**: Google OAuth with HMAC-signed session cookies
- **Web**: Bearer token auth for programmatic API access using server-side SHA-256 hashes
- Do not commit `.env*` files or build artifacts

## Validation

```bash
swift test
cd web
npm run lint
npx tsc --noEmit --pretty false
npm run build
```

See [docs/release-checklist.md](docs/release-checklist.md) for the full pre-release checklist, Cloudflare secret inventory, `/api/health` smoke check, and release notes template.
