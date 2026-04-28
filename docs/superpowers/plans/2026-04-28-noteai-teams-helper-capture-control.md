# NoteAI Teams Helper Capture Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the web Teams Desktop source to start/stop a visible local macOS helper recording session and persist the final helper transcript into the web app.

**Architecture:** Add a narrow `LocalCaptureControlling` Interface behind the localhost helper router. `MeetingManager` is the native capture Adapter; web recording chooses Browser Tab or Teams Desktop and keeps NoteAI Web as the persistence system of record.

**Tech Stack:** Swift 5.9, Network.framework, AVFoundation/ScreenCaptureKit/WhisperKit through existing capture modules, Next.js 16, React 19, TypeScript 5, Node test runner.

---

### Task 1: Helper Capture Protocol And Router Tests

**Files:**
- Modify: `NoteAI/LocalHelper/LocalCaptureHelperProtocol.swift`
- Modify: `NoteAI/LocalHelper/LocalCaptureHelperServer.swift`
- Modify: `NoteAITests/LocalCaptureHelperTests.swift`

- [ ] Add request/response Codable types for `/v1/capture/start` and `/v1/capture/stop`.
- [ ] Add a `LocalCaptureControlling` protocol with `snapshot`, `startCapture`, and `stopCapture`.
- [ ] Write failing tests proving unpaired capture start is rejected, paired capture start reaches a fake controller, and paired stop returns transcript JSON.
- [ ] Implement router delegation and keep loopback/CORS/token checks unchanged.

### Task 2: MeetingManager Capture Adapter

**Files:**
- Modify: `NoteAI/App/MeetingManager.swift`
- Create: `NoteAI/LocalHelper/MeetingManagerLocalCaptureController.swift`
- Modify: `NoteAI/App/AppDelegate.swift`

- [ ] Add helper-safe start/stop methods to `MeetingManager` that reuse current audio/transcription setup but skip the native naming prompt.
- [ ] Create `MeetingManagerLocalCaptureController` to expose the capture-control Interface.
- [ ] Update AppDelegate to pass the controller into `LocalCaptureHelperRouter`.
- [ ] Preserve visible state through existing `MeetingManager.state` and helper `recordingIndicator`.

### Task 3: Web Helper Capture Client

**Files:**
- Modify: `web/src/lib/local-helper.ts`
- Modify: `web/local-helper.test.mjs`

- [ ] Add TypeScript types and functions for `startLocalCaptureHelperCapture` and `stopLocalCaptureHelperCapture`.
- [ ] Test that both functions send the stored bearer token and correct JSON payload.
- [ ] Test that stop response transcript maps to web transcript segment shape.

### Task 4: Web Recording Lifecycle

**Files:**
- Modify: `web/src/lib/hooks.ts`
- Modify: `web/src/lib/recording-sources.ts`
- Modify: `web/teams-desktop-ui.test.mjs`

- [ ] Extend `useRecording.startRecording` and `stopRecording` to accept a source id.
- [ ] Keep Browser Tab on the current `AudioRecorder` path.
- [ ] Add Teams Desktop path that calls helper start/stop, persists returned transcript via `db.meetings`, and summarizes through existing `summarizeTranscript`.
- [ ] Enable Teams Desktop source only when helper is paired and `captureControl` is true.

### Task 5: Sidebar One-Click UX

**Files:**
- Modify: `web/src/components/Sidebar.tsx`
- Modify: `web/src/app/page.tsx`
- Modify: `web/src/components/Settings.tsx`

- [ ] Pass selected recording source into `guardedStartRecording`.
- [ ] When helper is unavailable, offer/open `noteai://capture-helper` instead of pretending capture is available.
- [ ] Keep visible recording state in the Sidebar and Live Transcript view.
- [ ] Keep Settings diagnostics and pairing path available.

### Task 6: Verification And Delivery

**Commands:**
- `npm run lint`
- `node --test *.test.mjs`
- `npm run build`
- `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -only-testing:NoteAITests/LocalCaptureHelperTests test`
- `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -configuration Debug build`

- [ ] Commit with `JPB-49` in the message.
- [ ] Push branch, open PR, wait for CI.
- [ ] Merge to `main`, confirm post-merge CI and Cloudflare deploy.
- [ ] Smoke check `https://noteai-web.noteai-jp.workers.dev/api/health`.
- [ ] Update Linear with scope, verification, and any follow-ups.
