# NoteAI - Codex Guide

## Required Linear Workflow

Linear is the source of truth and second brain for NoteAI work.

Every Codex agent working in this repository must keep Linear in sync for meaningful work. This includes features, bugs, functionality tests, security findings/remediation, codebase architecture improvements, refactors, documentation, deployment/release work, product decisions, and follow-up tasks.

Before or during work:
- Use the `Jpbueno` Linear team.
- Use the `NoteAI Product Roadmap` project by default unless a more specific NoteAI project exists.
- Find the relevant existing issue, or create one before implementation/test work continues.
- Move active implementation or test work to `In Progress` or `In Review` instead of leaving it only in chat.

End-to-end Linear item handling:
- This is a general rule for every Linear item the user asks Codex to tackle; it is not limited to `JPB-24`, functionality test sessions, or any specific project-process issue.
- When the user asks Codex to tackle any Linear item, treat the request as permission to complete the item end-to-end unless the user explicitly limits scope or asks for planning only.
- Do not leave a completable item parked in `In Progress` waiting for the user to say "finish the remaining tasks/tests." Continue through implementation, relevant verification/tests, documentation updates, and Linear bookkeeping in the same session when feasible.
- If the work is completed and verification is satisfactory, move the Linear issue to `Done` without requiring an additional user prompt.
- If the item cannot be completed, keep it in the appropriate active state, explain the blocker, record completed work and verification results in Linear, and create or link follow-up issues for any deferred work.

Default main/deployment workflow:
- `main` is the source of truth for completed NoteAI work. Completed and tested work should not remain only on a Codex, feature, or temporary branch.
- Always commit and push important implementation, configuration, documentation, and process-rule updates to the GitHub repo before treating the work as complete.
- Before marking a Linear issue `Done`, verify the relevant changes are committed, pushed to `main`, and visible on the remote.
- Run the relevant local checks for the touched modules before pushing. For Swift/macOS changes, include `swift test` or the appropriate Xcode build/test when available. Run repository CI and hygiene checks for workflow or documentation changes.
- Push completed work to `main` unless the user explicitly asks for a PR-only flow. If branch protection blocks direct push, open the PR, merge it, and then verify `main`.
- After `main` updates, confirm the applicable GitHub Actions checks ran successfully.
- If tests, push, or CI fails, keep the Linear issue active, document the failure clearly in Linear and chat, and create or link follow-up issues instead of silently leaving the work on a branch.
- Delete obsolete local and remote branches only after confirming their useful commits are included in `main` by ancestry or patch equivalence.

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
  - for native distribution changes, the applicable build and app smoke checks pass.
- If no repository changes are required, the Linear update must explicitly say `No repository changes required` and explain why.
- If Linear updates are blocked by connector or credential handling, still complete the git, CI, merge, and applicable native verification path first, then provide the exact manual Linear update text for the user to paste.

Standing Linear anchor:
- `JPB-24` records this operating rule.
- `JPB-26` tracks the current functionality test session if no more specific test issue exists.

## Required Architecture & Security Primitives

All NoteAI improvements and new features managed in Linear must explicitly follow the relevant architecture and security primitives before implementation is treated as complete.

- For improvements, new features, refactors, architecture work, and codebase-shaping follow-ups, use the `improve-codebase-architecture` skill. Frame architecture decisions with its vocabulary: Module, Interface, Implementation, Depth, Seam, Adapter, Leverage, and Locality.
- For security findings/remediation, hardening, infrastructure, authentication, authorization, secrets, deployment, dependency, and operational security work, use the `security-auditor` skill.
- For JavaScript/TypeScript secure-by-default coding, explicit security best-practices guidance, or security reports, use the `security-best-practices` skill alongside `security-auditor`.
- Linear issues for improvements and new features must capture the architecture/security checks performed, verification commands/results, affected modules/files, accepted risks or deferred decisions, and linked follow-up issues for new risks or improvements.

## Project Overview

NoteAI 7 is a macOS meeting transcription and live AI Solutions Architect app, built with SwiftUI, on-device WhisperKit transcription, and local GRDB persistence.

The app retains meeting capture/transcription, transcript import, summaries, speaker context, meeting history/search/export, TTS, and live AI SA questions. Standalone notes, T5T, tasks, todos, and the general assistant are retired. Keep existing SQLite tables and rows untouched; do not restore their startup migrations or CRUD paths.

The web version was permanently retired in JPB-191. NoteAI is a macOS application; there is no supported web client, web API, web deployment, or Turso migration workflow. Reintroducing a web product requires a new explicit product decision and security review.

## Storage Source of Truth

Use `docs/storage-source-of-truth.md` as the canonical storage rule before adding, importing, repairing, or migrating NoteAI data.

- The macOS app currently uses local GRDB-backed SQLite through `NoteAI/Storage/MeetingStore.swift`. This is the correct production storage adapter for the native app until a deliberate profile-backed cloud sync migration replaces it.
- Codex must not manually write user data directly into `.sqlite` files or through ad hoc scripts unless the user explicitly requests a data repair or migration and the work includes backup, verification, and Linear documentation.
- App and assistant features must write through `MeetingStore` and the native repository abstractions.
- Google login does not make native data cloud-backed. Cross-device/profile storage requires a separate sync design.

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
  Storage/          # Meeting-only GRDB persistence and meeting/coach models
  Auth/             # Google OAuth 2.0 + PKCE, Keychain, API key management
  Delivery/         # Meeting export and notifications
  UI/               # SwiftUI views organized by feature area
```

### Key Components
- **MeetingManager** (`App/MeetingManager.swift`) — Central state orchestrator, coordinates all services
- **TranscriptionEngine** (`Transcription/TranscriptionEngine.swift`) — Actor, WhisperKit with hallucination filtering
- **SummarizationEngine** (`Summarization/SummarizationEngine.swift`) — Multi-provider LLM, template-based prompts
- **MeetingStore** (`Storage/MeetingStore.swift`) — GRDB persistence layer, CRUD for all models
- **LiveCoachSession** (`Summarization/LiveCoachSession.swift`) — Session-safe live AI SA orchestration
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
| **CoachInsight** | id, sessionID, content, evidence, lifecycle, role |

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
- macOS: Xcode scheme tests cover meeting persistence/export and archived-data preservation, recording/audio diagnostics, onboarding, Teams detection, local capture helper, meeting shell, summary parsing, and session-safe AI SA behavior. Persistence tests must use temporary stores rather than the live app database.
- Preserve `SharedTests/coach-admission-contract-v1.json`; native AI coach tests load this fixture.
