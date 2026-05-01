# NoteAI Local Capture Helper Lifecycle Definition

Issue: JPB-70, "Follow-up: define durable local helper launch/install/update lifecycle"
Date: 2026-05-01
Status: Definition for implementation

## Goal

Define the durable product and architecture lifecycle for the macOS local capture helper after the JPB-51 web recovery slice. The helper should be reliable enough for Teams Desktop capture without becoming a second product, a hidden recorder, or a separate protocol surface for install/update operations.

## Context

JPB-51 polished web-visible recovery states for helper connection, pairing, stale tokens, permissions, and busy capture. JPB-70 broadens that into the helper lifecycle around the existing localhost helper:

- `NoteAI/LocalHelper/LocalCaptureHelperProtocol.swift` defines the loopback JSON Interface and protocol version.
- `NoteAI/LocalHelper/LocalCaptureHelperStatusProvider.swift` returns minimal unauthenticated health and paired diagnostics.
- `NoteAI/LocalHelper/LocalCaptureHelperServer.swift` owns loopback binding, Host validation, CORS, bearer-token authorization, pairing, events, and capture control routing.
- `NoteAI/App/AppDelegate.swift` currently starts the helper server when the NoteAI macOS app launches and handles `noteai://capture-helper`.
- `web/src/lib/local-helper.ts` and `web/src/lib/recording-sources.ts` already treat loopback-unavailable as a launch-helper recovery path.

## Non-Goals

- Do not redesign the helper protocol for lifecycle. No `/v1/install`, `/v1/update`, `/v1/repair`, or protocol version change is required for this issue.
- Do not make the helper independently store meetings, summaries, or web account data.
- Do not add hidden or background-only capture.
- Do not expose bearer token material, token identifiers, token hashes, pairing codes, or detailed helper trust state in logs, support bundles, or web-visible UI.
- Do not implement a separate helper app bundle until packaging constraints prove the existing NoteAI app is the wrong Adapter.

## Product Decisions

### 1. Helper Packaging

The helper remains inside the existing signed NoteAI macOS app for the next implementation slice.

Architecture: `NoteAI.app` is the concrete Adapter for the local helper runtime. The helper Module remains `NoteAI/LocalHelper`, and the web app continues to talk only to the loopback HTTP Interface. This preserves Locality: capture, permissions, pairing, and launch handling stay in the native app that already owns macOS capabilities.

Depth: callers get durable helper availability through a small Interface: launch the app, probe health, pair, read status, start/stop capture. The Implementation can change from regular app window to menu-bar status item or login item without changing web protocol callers.

### 2. Launch At Login

The macOS helper should support launch-at-login, but it must be explicit and user controlled.

Default: off for a fresh install.

Recommended enablement moment: after the user selects Teams Desktop or pairs the helper, NoteAI may offer "Keep Teams helper ready at login." The setting should also be available from native settings.

Implementation direction:

- Use the macOS login item mechanism appropriate for the packaged app, such as `SMAppService`, rather than a custom daemon or shell script.
- Login launch starts NoteAI in helper-ready mode, starts the loopback helper server, and does not start capture.
- Disabling launch-at-login removes only the login item. It must not delete pairings, tokens, transcripts, meetings, or app settings.
- If macOS reports the login item as disabled by system policy, the native UI should show a repair action that opens the appropriate System Settings pane. The web should show only coarse "Open NoteAI Helper" or "Update/Reopen NoteAI" guidance.

Security check: launch-at-login increases ambient availability but not capture authority. The helper still binds only to loopback, health remains minimal, status/capture still require an origin-bound bearer token, and capture still requires explicit user action with visible recording state.

### 3. Background And Menu-Bar Presentation

The helper should support a quiet menu-bar/background presentation, but it must never be invisible while recording.

Decision:

- When launched for helper readiness, NoteAI may run without opening the main library window.
- A menu-bar/status item should remain visible whenever the helper is running.
- The status item should expose: helper running status, open NoteAI, restart helper, pairing reset entry point, launch-at-login setting, and quit.
- During capture, the status item and any native recording surface must show `visible-recording` before audio capture begins.
- A Dock/main-window presentation remains allowed when the user opens NoteAI normally.

Architecture: `LocalHelperLifecycle` should be a Module owned by the macOS app shell. Its Interface is native lifecycle state and commands, not HTTP. `LocalCaptureHelperServer` remains the loopback transport Module; `MeetingManager` remains the capture Adapter.

Seam: the web-to-helper seam stays `noteai://capture-helper` plus `/v1/health` and paired `/v1/status`. The native lifecycle seam is separate so future packaging can replace the app-shell Adapter without changing helper protocol semantics.

### 4. Installed But Not Running Recovery

The web recovery path for "installed but not running" is:

1. Web probes `http://127.0.0.1:47391/v1/health` with a short timeout.
2. If health is unavailable, the Teams Desktop source shows "Open NoteAI Helper" and invokes `noteai://capture-helper`.
3. The macOS app opens or foregrounds, starts `LocalCaptureHelperServer`, and presents a native helper-ready state.
4. Web retries health/status after the user returns or after a short retry window.
5. If health appears:
   - If paired, continue to `/v1/status`.
   - If unpaired or token is stale, follow the existing pairing recovery.
   - If capture control is unsupported, show "Update NoteAI for Mac."
6. If health still does not appear, show repair guidance:
   - Open NoteAI from Applications.
   - Restart NoteAI.
   - Update or reinstall NoteAI for Mac if the URL handler or helper server remains unavailable.

The browser cannot reliably distinguish "not installed", "installed but launch failed", "blocked by local network policy", and "port unavailable" from the first failed loopback probe. The product should avoid false certainty and phrase the fallback as "Open or install NoteAI for Mac" when health never appears.

No bearer token, token trust details, or local Keychain state should be included in this recovery UI. "Pair Helper" and "Pair again" are acceptable because they are coarse actions, not trust-state disclosure.

### 5. Repair Flow

Repair is an app/native lifecycle operation, not a web protocol operation.

Repair actions:

- Restart helper server: stop and start `LocalCaptureHelperServer` from native UI.
- Reopen URL handler: ask the user to reopen or reinstall NoteAI if `noteai://capture-helper` does not launch the app.
- Port conflict: native UI should report that the helper could not bind to `127.0.0.1:47391` and offer restart/retry. Logs should include the coarse failure code, not request headers or tokens.
- Stale browser token: web clears its stored token only after a paired endpoint returns 401 and then asks the user to pair again.
- Paired-origin reset: native UI may offer "Reset paired websites" behind an explicit user action. Web must not remotely reset helper trust.

Architecture: a future `LocalHelperLifecycle` Module should own repair commands and health of the server process. `LocalCaptureHelperRouter` should not learn install or repair behavior. This keeps the HTTP Interface deep and focused: network request validation and helper protocol responses remain in one place, while OS launch/update behavior remains local to the app shell.

### 6. Update Flow

The helper updates with the NoteAI macOS app.

Decision:

- There is no independent helper updater in the current architecture.
- `/v1/health` remains the compatibility probe for protocol and capability checks.
- If health returns an older protocol or missing required capability, web disables Teams Desktop recording and asks the user to update/reopen NoteAI for Mac.
- Updating should preserve Keychain-backed trusted clients when the bundle identity and signing identity remain stable.
- If an update changes bundle identity, storage access, or trust material, the helper should degrade to unpaired and ask the user to pair again.

Security check: update/repair messages must not include token material, pairing codes, or detailed paired-origin trust state. The web should treat helper health/status JSON as untrusted input and render only validated text.

## Lifecycle States

These states are product states, not new protocol enums.

| State | Detection | User action | Protocol impact |
| --- | --- | --- | --- |
| Not installed or not reachable | `/v1/health` fails | Open/install NoteAI for Mac | None |
| Installed but not running | `/v1/health` fails, `noteai://capture-helper` may launch app | Open NoteAI Helper, retry | None |
| Running, unpaired | `/v1/health` succeeds; `/v1/status` 401 or no token | Pair Helper | Existing pairing endpoints |
| Running, paired idle | `/v1/health` and `/v1/status` succeed, `captureState=idle` | Start Teams Desktop when capability is present | Existing status/capture |
| Running, capture active | Paired status reports `captureState=recording` and `recordingIndicator=visible-recording` | Stop or reconnect web | Existing status/events/capture |
| Version unsupported | Health protocol/capability mismatch | Update NoteAI for Mac | Existing health |
| Repair needed | URL handler, login item, or helper server start fails | Native repair/restart/reinstall | None |

Because these are product states, tests should assert the mapping at the Adapter edges: web recovery mapping for loopback failures and Swift lifecycle/status tests only when native lifecycle code exists.

## Architecture Notes

- **Module:** `LocalCaptureHelperServer`
  - **Interface:** loopback HTTP request routing, Host/CORS validation, pairing authorization, health/status/events/capture routes.
  - **Implementation:** socket binding to `127.0.0.1`, JSON encoding, event snapshots.
  - **Locality:** network exposure and helper protocol behavior remain together.

- **Module:** `LocalCaptureHelperStatusProvider`
  - **Interface:** health and paired diagnostics.
  - **Implementation:** macOS microphone, Screen Recording, ProcessTap, and Teams process checks.
  - **Depth:** health intentionally hides local diagnostics; status provides leverage only after pairing.

- **Module:** future `LocalHelperLifecycle`
  - **Interface:** launch-at-login setting, helper-ready startup, server restart, helper presentation mode, native repair actions.
  - **Implementation:** app launch handling, login item Adapter, menu-bar/status item Adapter, `LocalCaptureHelperServer` ownership.
  - **Seam:** native app shell, not the HTTP protocol.
  - **Leverage:** web and capture Modules do not need to know macOS login item, URL handler, or port repair mechanics.

- **Adapter:** existing `NoteAI.app`
  - Owns app activation, `noteai://capture-helper`, helper startup, menu-bar/background presentation, and future app update integration.

- **Adapter:** web helper recovery
  - Owns browser probe timeout, open-helper URL action, stale-token clearing, and user-facing fallback copy.

Deletion test: if a lifecycle Module were deleted, login item, status item, URL repair, server restart, and update compatibility decisions would scatter across `AppDelegate`, `LocalCaptureHelperServer`, and web recovery code. Keeping it as a native app-shell Module preserves Locality and keeps the helper HTTP Interface deep.

## Security And Privacy Checks

- Helper trust:
  - Pairing remains explicit, origin-bound, and native-visible.
  - Web UI may say "Pair Helper" or "Paired" only as coarse state. It should not expose token IDs, token hashes, exact trust records, or Keychain state.
  - Native pairing reset, if added, must be an explicit local settings action and must not list trust records by default or write sensitive trust details to logs.

- Local network exposure:
  - Bind only to `127.0.0.1` and optional loopback IPv6 if implemented.
  - Continue Host validation and allowlist-only CORS.
  - Do not add LAN, Bonjour, remote, or wildcard discovery for lifecycle.

- Launch-at-login:
  - Opt-in only.
  - Starts helper readiness, not capture.
  - Must have visible helper presence through status item or app UI.
  - Must be reversible without destroying local data.

- Repair/update:
  - No web endpoint performs repair, update, reset, or trust mutation.
  - Reinstall/update should preserve local trust when signing identity is stable; otherwise degrade to unpaired.
  - Repair logs should use coarse lifecycle codes such as `helper_bind_failed` or `login_item_disabled`, not request headers, tokens, origins, pairing codes, transcript text, or audio content.

- Token material:
  - Bearer token material remains in the web origin's browser storage and hashed in macOS Keychain.
  - Tokens must not appear in URLs, command-line arguments, crash reports, support bundles, logs, or UI.
  - `noteai://capture-helper` carries no token and grants no capture authority.

## Implementation Follow-Ups

These should become separate implementation issues rather than expanding JPB-70:

1. Add a native `LocalHelperLifecycle` Module to own helper startup mode, restart, and future login item state.
2. Add a menu-bar/status item presentation for helper-ready and helper-recording states.
3. Add opt-in launch-at-login using the signed app's supported macOS login item mechanism.
4. Add native repair UI for helper server bind failure, disabled login item, and paired-site reset.
5. Add web copy that avoids over-claiming whether the helper is uninstalled versus installed but not running when loopback health never appears.

## Verification Guidance

Docs-only definition for JPB-70 does not require new Swift lifecycle tests. When implementation starts:

- Add Swift tests only for native lifecycle/status behavior that has a deterministic test seam, such as launch-at-login state mapping or server restart status.
- Keep existing `LocalCaptureHelperTests` for protocol, loopback, pairing, events, and capture control behavior.
- Add web tests only at the recovery Adapter edge: helper unavailable, open-helper action, stale token, unsupported version, and permission/capture readiness.
