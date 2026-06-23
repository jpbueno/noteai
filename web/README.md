# NoteAI Web

Next.js 16 SPA for NoteAI local development and regression coverage.

The public Cloudflare Worker deployment was decommissioned in JPB-191 because NoteAI is currently distributed and used through the macOS app. Do not recreate a public web deployment without an explicit security review and new Linear issue.

## Architecture

```
src/
  app/
    page.tsx                 Main SPA shell and selection/layout orchestration
    api/                     Server routes for auth, data, AI, transcription, TTS
  components/                React views and editors
  components/extensions/     Tiptap extensions
  lib/
    types.ts                 Shared entity types
    db.ts                    Client REST wrapper
    server-db.ts             Turso HTTP persistence and schema
    repositories.ts          Typed persistence adapters over db.ts
    library.ts               Entity drafts, search, source selection, selection clearing
    hooks.ts                 Fetch/refresh hooks and recording state hook
    recording-workflow.ts    Recording completion, transcription fallback, summary fallback
    ai.ts                    LLM/transcription transport helpers
    ai-tasks.ts              Prompt construction and response parsing
    assistant-actions.ts     AI chat action parsing and execution
    audio.ts                 Browser recording and speech recognition
    tts.ts                   Text-to-speech playback helpers
    content-utils.ts         Markdown/HTML conversion
```

The UI components should stay thin. Put reusable meeting, note, task, T5T, recording, and AI behavior in `src/lib/*` modules before wiring it into React views.

## Local Development

```bash
npm install
npm run dev
```

Open http://localhost:3000.

## Environment

Create `.env.local`:

```bash
TURSO_DATABASE_URL=libsql://your-db.turso.io
TURSO_AUTH_TOKEN=your-turso-token
NOTEAI_AUTH_SECRET=any-random-string
GOOGLE_CLIENT_ID=your-google-oauth-client-id
GOOGLE_ALLOWED_EMAILS=you@example.com
NOTEAI_API_KEY_HASHES=base64-sha256-of-programmatic-api-key
```

API keys for LLM/TTS providers are stored in the app settings table and read server-side only.

## Validation

```bash
npm run lint
npx tsc --noEmit --pretty false
npm run build
```

For programmatic REST access, send `Authorization: Bearer <raw-key>` and store only the raw key's base64 SHA-256 digest in `NOTEAI_API_KEY_HASHES`.
