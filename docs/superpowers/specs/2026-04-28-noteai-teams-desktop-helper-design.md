# NoteAI Teams Desktop Capture Helper Design

Issue: JPB-49, "Design first-class macOS Teams meeting capture"
Date: 2026-04-28
Status: Draft for review

## Goal

Make the NoteAI web app the cockpit for recording while a local macOS helper performs native Microsoft Teams desktop capture. The web app remains the system of record for meetings, summaries, tasks, notes, and T5T reports. The helper is a native capture Adapter behind a small localhost Interface, not a second product with independent meeting storage.

## Non-Goals

- Do not implement raw audio streaming in the first milestone.
- Do not make browser-only capture responsible for native Teams desktop audio.
- Do not add hidden or background-only capture.
- Do not make the macOS helper the canonical meeting library.
- Do not require BlackHole or other loopback devices for the Teams Desktop source.

## Existing Evidence

The macOS app already has useful capture Modules:

- `NoteAI/Audio/AudioCaptureManager.swift` orchestrates ProcessTap, ScreenCaptureKit fallback, microphone capture, diagnostics, resampling, and 7 second audio chunks.
- `NoteAI/Audio/ProcessTapProvider.swift` wraps `AudioHardwareCreateProcessTap` for per-process audio capture on macOS 14.2+.
- `NoteAI/Audio/ScreenCaptureProvider.swift` captures app or system audio via ScreenCaptureKit.
- `NoteAI/Audio/MicrophoneCaptureManager.swift` handles local mic capture and device route changes.
- `NoteAI/MeetingDetection/MeetingDetector.swift` and `NoteAI/MeetingDetection/ProcessMonitor.swift` detect Teams/browser meeting apps.
- `NoteAI/Transcription/TranscriptionEngine.swift` provides on-device WhisperKit transcription.

The web app already has browser capture and diagnostics Modules:

- `web/src/lib/audio.ts` owns `AudioRecorder`, browser mic/tab/system capture attempts, SpeechRecognition, Whisper polling, and diagnostics callbacks.
- `web/src/lib/recording-diagnostics.ts` defines source/permission diagnostics used by live UI.
- `web/src/lib/hooks.ts` owns the web recording lifecycle and persists meetings through existing data repositories.
- `web/src/components/Sidebar.tsx` contains the recording entry point.
- `web/src/components/LiveTranscript.tsx` shows live recording state, source levels, warnings, and stop controls.
- `web/src/components/Settings.tsx` already includes a browser capture diagnostics panel.

## Recommended Approach

### Option A: Existing macOS app as the local helper, web as cockpit

Use the existing NoteAI macOS menu-bar app as the helper runtime, add a localhost transport Module, and put Teams-specific capture policy behind a `TeamsCaptureOrchestrator` Module.

This has the best locality and leverage: ProcessTap, ScreenCaptureKit, mic capture, Teams detection, diagnostics, and WhisperKit already live in one native app. The new Interface is narrow: web control/status in, status/transcript/events out.

### Option B: Separate helper app bundle

Create a smaller signed macOS helper app dedicated to localhost capture. This may be cleaner for distribution later, but it duplicates entitlement, permission, packaging, and update work before the product direction is proven.

### Option C: Web-only plus loopback device

Continue with browser capture, BlackHole, or tab sharing. This is not first-class for Teams desktop because browser APIs cannot reliably capture native Teams app audio on macOS.

Recommendation: Option A for the first implementation path. Split to Option B only if packaging or permission prompts become materially cleaner with a separate bundle.

## Architecture

### Modules and Seams

- `LocalCaptureHelperTransport`
  - Interface: localhost HTTP plus future SSE/WebSocket protocol.
  - Implementation: binds only to loopback, validates Origin, handles CORS/private-network requests, authenticates paired clients, emits JSON.
  - Locality: browser/network/security behavior stays out of capture code.

- `HelperPairingStore`
  - Interface: create pairing challenge, confirm one-time code, mint/revoke origin-bound tokens.
  - Implementation: Keychain-backed tokens with hashed token material and explicit trusted origins.
  - Locality: trust decisions stay out of web UI and capture adapters.

- `TeamsCaptureOrchestrator`
  - Interface: `status()`, future `start(sessionRequest)`, future `stop(sessionId)`.
  - Implementation: selects Teams ProcessTap when available, falls back to ScreenCaptureKit desktop/system audio, starts mic capture, forwards buffers to transcription.
  - Depth: callers do not need to know Teams bundle IDs, ProcessTap error modes, Screen Recording permission behavior, or fallback order.

- `CaptureDiagnosticsSnapshot`
  - Interface: shared JSON status vocabulary for helper/web.
  - Implementation: maps existing Swift `RecordingDiagnosticsSnapshot` and web `RecordingDiagnostics` into a cross-platform schema.
  - Leverage: same source/permission/status language can power Sidebar, Live Transcript, and Settings diagnostics.

- `WebRecordingSourceAdapter`
  - Interface: `detect()`, `start()`, `stop()`, `subscribe()`.
  - Implementations: existing browser `AudioRecorder` Adapter and future Teams Desktop helper Adapter.
  - Locality: `useRecording` should not accumulate helper-specific branches.

## Helper Protocol

Base origin:

- Preferred: `http://127.0.0.1:47391`
- Optional IPv6: `http://[::1]:47391`
- The helper must not bind to `0.0.0.0` or a LAN interface.
- The helper must reject requests with unexpected `Host` values.

Browser compatibility notes:

- Loopback HTTP origins such as `http://127.0.0.1` and `http://localhost` are treated as potentially trustworthy by modern browsers, but the web app should still expect browser-specific local network prompts.
- Chrome's Local Network Access direction adds browser mediation for public sites that connect to local or loopback servers. The helper should support CORS preflight and private-network headers where applicable, and the web UI should handle a browser-level local network permission denial as a first-class diagnostic.

Common response headers:

```http
Access-Control-Allow-Origin: <request Origin if allowlisted>
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Authorization, Content-Type, X-NoteAI-Client, X-NoteAI-Protocol
Access-Control-Allow-Private-Network: true
Cache-Control: no-store
Content-Type: application/json
```

The helper should allow only configured NoteAI web origins and local development origins:

- Production web origin or origins configured at build/runtime.
- `http://localhost:3000` and `http://127.0.0.1:3000` for local dev.
- No wildcard CORS.

### GET `/v1/health`

Purpose: unauthenticated detection with no sensitive diagnostics.

Response:

```json
{
  "protocolVersion": "2026-04-28",
  "helperVersion": "0.1.0",
  "appName": "NoteAI Capture Helper",
  "status": "ready",
  "pairingRequired": true,
  "capabilities": {
    "status": true,
    "pairing": true,
    "captureControl": false,
    "events": false,
    "audioStreaming": false
  }
}
```

Allowed without pairing:

- Product identity.
- Protocol version.
- Capability flags.
- Whether pairing is required.

Not allowed without pairing:

- Permission state.
- Teams process state.
- Audio levels.
- Transcript, meeting metadata, account data, or local usernames.

### POST `/v1/pair/request`

Purpose: ask the helper to show an explicit trust request.

Request:

```json
{
  "origin": "https://noteai.example",
  "clientName": "NoteAI Web",
  "clientNonce": "base64url-random-32-bytes"
}
```

Response:

```json
{
  "pairingSessionId": "uuid",
  "expiresAt": "2026-04-28T18:00:00Z",
  "codeLength": 6
}
```

Helper behavior:

- Show a native menu-bar popover or window with the requesting origin and a 6 digit code.
- Do not approve automatically.
- Expire the request after 2 minutes.
- Rate limit repeated requests per origin.

### POST `/v1/pair/confirm`

Purpose: exchange the user-entered code for an origin-bound bearer token.

Request:

```json
{
  "pairingSessionId": "uuid",
  "code": "123456",
  "clientNonce": "base64url-random-32-bytes"
}
```

Response:

```json
{
  "accessToken": "opaque-random-token",
  "tokenId": "uuid",
  "origin": "https://noteai.example",
  "expiresAt": null
}
```

Token rules:

- Store token material in browser storage only for the NoteAI origin.
- Store only a hash of token material in macOS Keychain.
- Bind token to the requesting Origin.
- Allow revocation from the helper UI.
- Never log tokens or pairing codes.

### GET `/v1/status`

Purpose: paired diagnostics for web source selection and Settings.

Authentication:

```http
Authorization: Bearer <accessToken>
```

Response:

```json
{
  "protocolVersion": "2026-04-28",
  "helperVersion": "0.1.0",
  "captureState": "idle",
  "recordingIndicator": "visible-idle",
  "permissions": {
    "microphone": { "status": "granted" },
    "screenRecording": { "status": "denied", "action": "open-system-settings" },
    "processTap": { "status": "available", "requiresMacOS": "14.2" }
  },
  "teams": {
    "detected": true,
    "bundleId": "com.microsoft.teams2",
    "pid": 12345,
    "displayName": "Microsoft Teams",
    "frontmost": false,
    "audioActivity": "unknown"
  },
  "sources": {
    "microphone": {
      "status": "available",
      "level": 0,
      "reason": null
    },
    "teamsAudio": {
      "status": "notProbed",
      "adapter": "processTap",
      "level": 0,
      "reason": "Audio levels are available only during an explicit test or active recording."
    },
    "desktopAudioFallback": {
      "status": "blocked",
      "adapter": "screenCaptureKit",
      "level": 0,
      "reason": "Screen Recording permission is denied."
    }
  },
  "diagnostics": [
    {
      "severity": "warning",
      "code": "screen-recording-denied",
      "message": "Grant Screen Recording to capture Teams desktop audio."
    }
  ]
}
```

M1 status should not start audio capture. `teamsAudio.status` can be `notProbed` until an explicit test capture or real recording exists.

### Future POST `/v1/capture/start`

Purpose: start an explicit Teams Desktop capture session from the web app.

M1 behavior: return `501 Not Implemented` or `409 Capability Disabled` with a clear JSON error.

Future request:

```json
{
  "source": "teamsDesktop",
  "webMeetingId": "uuid",
  "title": "Meeting title from web",
  "transcriptionMode": "localWhisperKit",
  "includeMicrophone": true,
  "allowDesktopAudioFallback": true
}
```

Future response:

```json
{
  "sessionId": "uuid",
  "captureState": "starting",
  "eventUrl": "/v1/events?sessionId=uuid"
}
```

### Future POST `/v1/capture/stop`

Purpose: stop the active helper session.

Future response:

```json
{
  "sessionId": "uuid",
  "captureState": "stopping",
  "finalTranscriptAvailable": true
}
```

### Future GET `/v1/events`

Preferred future transport: SSE first, WebSocket only if bidirectional streaming becomes necessary.

Event types:

- `heartbeat`
- `status.snapshot`
- `capture.started`
- `capture.recovering`
- `capture.stopped`
- `diagnostic.changed`
- `transcript.segment`
- `transcript.finalized`
- `error`

Raw audio should remain out of the default protocol. If a later milestone needs audio transfer, it should be a separate explicit capability with its own user-facing consent, size limits, and retention rules.

## Pairing and Trust Model

Trust is between one web Origin and one local helper install.

Rules:

- The helper accepts traffic only on loopback.
- CORS is allowlist-only.
- Privileged endpoints require a bearer token.
- Tokens are origin-bound.
- Pairing requires a native visible approval surface.
- The helper shows the exact requesting origin before the user enters the code in the browser.
- The helper UI exposes paired origins and a revoke button.
- Capture start requires an explicit web action and a helper-visible recording indicator.
- The helper must not begin mic, ProcessTap, or ScreenCaptureKit capture from `/v1/health` or unpaired requests.

Threats addressed:

- Malicious public website probing localhost: unauthenticated health returns minimal information; status/capture require origin-bound token.
- DNS rebinding or Host confusion: bind to loopback and validate Host.
- CSRF-style local helper calls: state-changing endpoints require bearer token and Origin validation.
- Token leakage in logs: tokens are opaque, never logged, and stored hashed in Keychain.
- Hidden capture: native indicator plus explicit control required before any capture.

Accepted risk:

- Loopback HTTP is not encrypted. For this product, local-only binding plus Origin validation, bearer tokens, and no LAN exposure are acceptable for the first milestone. Revisit TLS only if browser policy or enterprise deployment requires it.

## Source Selection UX

### Sidebar Entry Point

Replace the single default `Start Recording` behavior with a compact source selector:

- `Browser / Tab`
  - Existing behavior: browser mic, optional tab audio, SpeechRecognition, Whisper polling.
- `Teams Desktop`
  - New helper-backed source.

The default can remain Browser / Tab until the helper is paired and Teams is detected. Once paired, remember the last selected source.

### Teams Desktop Source States

Show a concise status row under the source selector:

- Helper: `Not found`, `Connected`, `Needs pairing`, `Version unsupported`, `Blocked by browser`.
- Trust: `Paired` or `Pair helper`.
- Teams: `Not running`, `Running`, `Likely in meeting`, `Unknown`.
- Mic: `Granted`, `Denied`, `Unknown`, `Unavailable`.
- Teams audio: `Ready`, `Needs Screen Recording`, `ProcessTap unavailable`, `Fallback ready`, `Not probed`.

Buttons:

- `Pair` appears when helper is detected but unpaired.
- `Open Helper` appears when the helper is installed but needs native attention.
- `Start Recording` remains disabled until the helper is paired and minimum permissions are acceptable.
- `Use Browser / Tab Instead` remains available as fallback.

### Live Transcript

When Teams Desktop recording is active in a future milestone:

- Header source label: `Teams Desktop`.
- Status pills: Helper, Teams, Mic, Teams audio.
- Stop button stops the helper session and then lets the web finalize the meeting.
- Warnings remain visible but should not cover transcript content.

### Settings Diagnostics

Add a Teams Desktop helper section near current recording diagnostics:

- Helper detected/version/protocol.
- Pairing state and revoke button.
- Permission diagnostics.
- Teams detection.
- A future explicit test capture button. This should be separate from M1 unless needed for review.

## Capture Lifecycle

### M1 Lifecycle

1. User opens NoteAI web.
2. Web probes `/v1/health` on loopback with a short timeout.
3. Sidebar shows Teams Desktop source.
4. If helper is reachable and unpaired, web offers pairing.
5. After pairing, web calls `/v1/status`.
6. Web renders diagnostics.
7. Pressing Record for Teams Desktop is either disabled or returns a clear "coming next" diagnostic.

No audio capture, transcription, or meeting persistence changes occur in M1.

### Future Recording Lifecycle

1. User selects Teams Desktop.
2. Web confirms helper is paired and compatible.
3. User presses Record in web.
4. Web creates or reserves a pending meeting ID.
5. Web sends `/v1/capture/start`.
6. Helper switches to visibly recording state before starting capture.
7. Helper starts mic capture.
8. Helper starts Teams ProcessTap if Teams is detected and macOS supports it.
9. If ProcessTap fails, helper falls back to ScreenCaptureKit desktop/system audio.
10. Helper forwards audio chunks to local WhisperKit transcription.
11. Helper emits transcript/status events to the web.
12. Web keeps live transcript and source diagnostics current.
13. User presses Stop in web or helper.
14. Helper stops capture, finalizes transcript events, and returns to idle.
15. Web persists the meeting through existing web repositories and runs existing summary/task/T5T flows.

## Diagnostic States

Use stable codes so web UI, logs, and Linear follow-ups can refer to the same states.

Helper connection:

- `helper-not-found`
- `helper-connected`
- `helper-unpaired`
- `helper-paired`
- `helper-version-unsupported`
- `helper-browser-blocked`
- `helper-request-timeout`

Permissions:

- `microphone-granted`
- `microphone-denied`
- `microphone-not-determined`
- `screen-recording-granted`
- `screen-recording-denied`
- `process-tap-available`
- `process-tap-requires-macos-14-2`
- `process-tap-unavailable`

Teams:

- `teams-not-running`
- `teams-running`
- `teams-active`
- `teams-audio-unknown`
- `teams-audio-silent`
- `teams-audio-active`

Sources:

- `mic-available`
- `mic-capturing`
- `mic-silent`
- `mic-unavailable`
- `teams-audio-not-probed`
- `teams-audio-process-tap-ready`
- `teams-audio-process-tap-capturing`
- `desktop-audio-fallback-ready`
- `desktop-audio-fallback-capturing`
- `desktop-audio-blocked`

Capture:

- `capture-idle`
- `capture-starting`
- `capture-recording`
- `capture-recovering`
- `capture-stopping`
- `capture-stopped`
- `capture-error`

## Failure and Recovery Behavior

- Helper missing: show Teams Desktop as unavailable with install/open helper guidance; Browser / Tab remains available.
- Browser blocks local access: show `helper-browser-blocked` with instructions to allow local network/loopback access and retry.
- Pairing denied or expired: return to unpaired state; do not show permission diagnostics.
- Token revoked: clear browser token and prompt to pair again.
- Helper version too old: disable Teams Desktop start and show required protocol version.
- Teams not running: show warning; future start may allow "record anyway" only after explicit confirmation.
- Microphone denied: block default Teams Desktop recording unless the user explicitly chooses a future Teams-audio-only mode.
- Screen Recording denied: Teams audio cannot be captured through ProcessTap/SCK; show System Settings action and keep Browser / Tab fallback.
- ProcessTap fails: future capture falls back to ScreenCaptureKit and emits a warning.
- ScreenCaptureKit fails after ProcessTap fails: continue mic-only only if the user confirms; otherwise fail capture start.
- Teams audio silent: keep recording but show warning after a threshold such as 15 seconds of silence.
- Mic device changes: existing macOS mic route recovery should continue; status events should show recover/recovered.
- Helper disconnects during recording: web enters reconnecting state, keeps current transcript in memory, and attempts status reconnect. If reconnect fails, web asks user to stop from helper or recover before finalizing.
- Web tab closes during helper recording: helper continues only if already visibly recording, retains a short local session buffer, and exposes current session status when web reconnects. Auto-stop after a configurable idle timeout is a follow-up decision.

## Security and Privacy Requirements

- Helper must bind only to loopback.
- No wildcard CORS.
- No privileged diagnostics before pairing.
- No capture from health/status endpoints.
- No capture without visible native recording state.
- No raw audio retention by default.
- No transcript, token, pairing code, or audio content in logs.
- Pairing and capture actions should be auditable in helper logs without sensitive content.
- The helper should support revoking paired origins.
- The helper should rate limit pairing and capture start attempts.
- The web app should treat helper responses as untrusted JSON and validate status shape before rendering.
- The web app should render diagnostics as text through React, not HTML injection.
- Future audio or transcript events must use explicit session IDs and reject stale events from previous sessions.

## Milestone Plan

### M1: Helper Detection and Diagnostics Only

Purpose: prove the cockpit/helper seam safely without recording audio.

Decision: M1 includes minimal pairing because `/v1/status` exposes local permission and Teams diagnostics. If review chooses to defer pairing, M1 must be reduced to `/v1/health` plus web detection only, with privileged status delayed to the next milestone.

Deliverables:

- macOS helper localhost transport in the existing NoteAI app.
- `GET /v1/health`.
- Minimal pairing flow with native visible approval and an origin-bound token.
- `GET /v1/status` after pairing with permissions, Teams detection, and non-capturing source diagnostics.
- Web helper detection Module with timeout and browser-blocked handling.
- Sidebar Teams Desktop source visible.
- Settings diagnostics for helper connection/pairing/status.
- Clear "capture control not enabled yet" behavior for Teams Desktop Record.

Verification:

- Swift build/test for helper status Modules.
- Web lint, typecheck, and build.
- Manual browser check for helper not installed, helper unpaired, paired status, and browser local access denial if reproducible.
- Linear update with affected files, architecture/security checks, accepted risks, and no-audio-streaming confirmation.

### M2: Capture Control Skeleton

Purpose: prove safe start/stop control without full transcript integration.

Deliverables:

- `/v1/capture/start` and `/v1/capture/stop`.
- Visible helper recording indicator.
- Capture state events.
- Start/stop from web.
- No hidden capture; no raw audio streaming.

### M3: Native Teams Capture Diagnostics

Purpose: validate actual Teams/mic audio capture and fallback behavior.

Deliverables:

- Wire `TeamsCaptureOrchestrator` to ProcessTap, ScreenCaptureKit fallback, and mic capture.
- Emit source levels and adapter choice.
- Explicit failure paths for missing permissions and silent audio.
- Optional manual test capture in Settings.

### M4: Local Transcription Events and Web Persistence

Purpose: make Teams Desktop useful end to end.

Deliverables:

- Helper local WhisperKit transcript events.
- Web live transcript updates from helper.
- Stop/finalize flow that persists to existing web meeting storage.
- Existing summarization, tasks, notes, and T5T flows remain unchanged after meeting creation.

### M5: Recovery, Packaging, and Release Readiness

Purpose: harden the product surface.

Deliverables:

- Reconnect/replay behavior.
- Helper install/update path.
- Pairing revoke UI.
- More complete diagnostics and support logs without sensitive content.
- CI/build/release checks and Cloudflare live smoke check for web-facing changes.

## Review Questions

1. Do we agree that M1 should include minimal pairing so privileged diagnostics are not exposed to arbitrary sites?
2. Should future Teams Desktop recording require mic permission, or allow explicit Teams-audio-only capture?
3. Should raw audio ever leave the helper, or should the default and preferred model be transcript/status events only?
4. Should the helper remain inside the existing NoteAI macOS app for the first release, or should packaging push us to a separate helper app sooner?

## References

- MDN Secure Contexts: https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts
- Chrome Local Network Access: https://developer.chrome.com/blog/local-network-access
- WICG Local Network Access draft: https://wicg.github.io/local-network-access/
