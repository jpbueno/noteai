# NoteAI Teams Helper Capture Control Design

## Goal

Make the web app's **Teams Desktop** recording source start and stop a transparent local macOS helper recording session. The flow must be one-click after pairing, but never hidden: the helper/native app must expose a visible recording state, use macOS permissions, and refuse unpaired or non-loopback control.

## Scope

This milestone enables local helper capture control and web persistence from the final helper transcript. It does not implement raw audio streaming to the browser. The helper remains the native capture Adapter; the web app remains the cockpit and system of record.

## Architecture

Add a `LocalCaptureControlling` Interface inside `NoteAI/LocalHelper`. `LocalCaptureHelperRouter` owns HTTP authorization and delegates capture start/stop/status to this Interface. `MeetingManager` becomes the concrete Adapter for native capture by exposing helper-safe start/stop methods that reuse `AudioCaptureManager`, `TranscriptionEngine`, existing permission diagnostics, and visible app state.

The web app uses `web/src/lib/local-helper.ts` to start/stop helper capture with the stored pairing token. `useRecording` learns a `source` argument. Browser Tab keeps its current path; Teams Desktop uses helper start/stop, shows live visible recording state, and persists the final returned transcript through existing `db.meetings` and `summarizeTranscript`.

## Protocol Changes

`GET /v1/health` sets `capabilities.captureControl = true` once the helper has a capture controller.

`GET /v1/status` includes current `captureState` and `recordingIndicator`. When recording through the helper, these must be `recording` and `visible-recording`.

`POST /v1/capture/start` requires pairing and accepts:

```json
{
  "source": "teamsDesktop",
  "title": "Optional web meeting title",
  "includeMicrophone": true,
  "allowDesktopAudioFallback": true
}
```

It returns:

```json
{
  "sessionId": "uuid",
  "captureState": "recording",
  "startedAt": "2026-04-28T18:15:00Z",
  "recordingIndicator": "visible-recording"
}
```

`POST /v1/capture/stop` requires pairing and returns:

```json
{
  "sessionId": "uuid",
  "captureState": "stopped",
  "startedAt": "2026-04-28T18:15:00Z",
  "stoppedAt": "2026-04-28T18:40:00Z",
  "duration": 1500,
  "transcript": [
    { "id": 1, "text": "...", "startTime": 0, "endTime": 7, "speaker": null, "confidence": 0.9 }
  ]
}
```

## Web UX

Teams Desktop is enabled only when the helper is reachable, paired, and reports `captureControl = true`. If the helper is unavailable, the source offers an **Open Helper** action via `noteai://capture-helper`. If pairing is missing, the source remains blocked with the existing pairing path in Settings.

Starting Teams Desktop recording routes to helper capture. The existing Live Transcript view is reused as the visible web recording surface; it can show local-helper transcript segments if polling is added later. This milestone persists the final transcript after Stop.

## Safety

- No hidden recording.
- No bypass of Microphone or Screen Recording prompts.
- Capture control requires loopback Host validation, allowlisted CORS, paired origin-bound token, and explicit web user action.
- The helper must not auto-start capture on health/status/pairing.
- If capture starts, `recordingIndicator` must report `visible-recording`.

## Failure And Recovery

- Helper unavailable: web opens `noteai://capture-helper` and tells the user to retry after the helper starts.
- Unpaired: web blocks Teams Desktop recording and points to Settings pairing.
- Permissions denied: helper returns a clear JSON error; web shows it and does not fall back to hidden capture.
- Already recording: start returns the existing session state or a conflict; web treats this as active recording.
- Stop failure: web keeps state as recording and lets the user retry.

## Verification

- Swift router tests for authorized start/stop and unpaired rejection.
- Swift controller tests using an in-memory fake.
- Web helper client tests for bearer-token start/stop payloads.
- Web recording source tests proving Teams Desktop is enabled only when paired capture control exists.
- Local lint/tests/build and main PR/deploy gate.
