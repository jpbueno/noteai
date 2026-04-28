# NoteAI Teams Helper M1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the first diagnostic-only milestone for JPB-49: a local macOS helper health/status surface, web helper detection, visible Teams Desktop recording source, and diagnostics without audio streaming.

**Architecture:** The existing macOS app becomes the local helper runtime by adding a loopback HTTP transport Module over focused protocol, pairing, and status Modules. The web app gains a local helper client Adapter and a recording source model so UI can show Teams Desktop without pushing helper-specific logic into the existing browser `AudioRecorder`.

**Tech Stack:** Swift 5.9, Network.framework, AppKit, Security/Keychain, XCTest, Next.js 16 client components, React 19, TypeScript, Node `--test`.

---

## File Structure

- Create `NoteAI/LocalHelper/LocalCaptureHelperProtocol.swift`
  - Codable helper protocol models and HTTP response helpers.
- Create `NoteAI/LocalHelper/LocalCaptureHelperPairingStore.swift`
  - In-memory pending pairing sessions, Keychain-backed trusted clients, SHA-256 token hashing.
- Create `NoteAI/LocalHelper/LocalCaptureHelperStatusProvider.swift`
  - Non-capturing health/status diagnostics mapped from existing macOS permission and Teams detection primitives.
- Create `NoteAI/LocalHelper/LocalCaptureHelperServer.swift`
  - Loopback-only HTTP server for `/v1/health`, `/v1/pair/request`, `/v1/pair/confirm`, `/v1/status`, and future capture-not-enabled responses.
- Modify `NoteAI/App/AppDelegate.swift`
  - Start/stop the helper server and show native pairing approval.
- Create `NoteAITests/LocalCaptureHelperTests.swift`
  - XCTest coverage for health redaction, pairing token validation, status redaction, and request routing.
- Create `web/src/lib/local-helper.ts`
  - Browser-side helper detection, pairing/status client, runtime JSON validation, storage helpers, and diagnostic mapping.
- Create `web/src/lib/recording-sources.ts`
  - Source selection model for Browser / Tab and Teams Desktop.
- Create `web/local-helper.test.mjs`
  - Node tests for helper response validation, safe failures, pairing storage behavior, and Teams Desktop source state.
- Modify `web/src/app/page.tsx`
  - Load helper status with a polling hook and pass it to Sidebar/Settings.
- Modify `web/src/components/Sidebar.tsx`
  - Add compact source selector and Teams Desktop diagnostics; keep Teams Desktop Record disabled.
- Modify `web/src/components/Settings.tsx`
  - Add helper diagnostics section beside the existing recording diagnostics.

## Task 1: Swift Helper Protocol, Pairing, and Status

**Files:**
- Create: `NoteAI/LocalHelper/LocalCaptureHelperProtocol.swift`
- Create: `NoteAI/LocalHelper/LocalCaptureHelperPairingStore.swift`
- Create: `NoteAI/LocalHelper/LocalCaptureHelperStatusProvider.swift`
- Test: `NoteAITests/LocalCaptureHelperTests.swift`

- [ ] **Step 1: Write failing Swift tests for health/status/pairing**

```swift
func testHealthResponseDoesNotExposeLocalDiagnostics() throws {
    let health = LocalCaptureHelperStatusProvider(helperVersion: "0.1.0").health()
    let data = try JSONEncoder().encode(health)
    let json = String(decoding: data, as: UTF8.self)

    XCTAssertTrue(json.contains("\"pairingRequired\":true"))
    XCTAssertFalse(json.contains("microphone"))
    XCTAssertFalse(json.contains("Microsoft Teams"))
    XCTAssertFalse(json.contains("transcript"))
}

func testPairingTokenIsOriginBoundAndStoredHashed() throws {
    let storage = InMemoryTrustedClientStore()
    let store = LocalCaptureHelperPairingStore(trustedClientStore: storage)
    let challenge = store.createPairingRequest(origin: "http://localhost:3000", clientName: "NoteAI Web", clientNonce: "nonce")
    let confirmed = try store.confirmPairing(sessionId: challenge.pairingSessionId, code: challenge.debugCode, clientNonce: "nonce")

    XCTAssertTrue(store.validate(token: confirmed.accessToken, origin: "http://localhost:3000"))
    XCTAssertFalse(store.validate(token: confirmed.accessToken, origin: "https://evil.example"))
    XCTAssertFalse(storage.rawJSON.contains(confirmed.accessToken))
}
```

- [ ] **Step 2: Run Swift test to verify RED**

Run: `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -only-testing:NoteAITests/LocalCaptureHelperTests test`

Expected: FAIL because `LocalCaptureHelperStatusProvider`, `LocalCaptureHelperPairingStore`, and `InMemoryTrustedClientStore` do not exist.

- [ ] **Step 3: Implement protocol, pairing, and status Modules**

Implement:
- Health response with `captureControl: false`, `events: false`, and `audioStreaming: false`.
- Pairing sessions with 6 digit codes, 2 minute expiration, nonce matching, origin binding, random token issuance, and SHA-256 token hashes.
- Status response that reads current mic/screen/processTap permission state and Teams process detection without starting capture.

- [ ] **Step 4: Run Swift test to verify GREEN**

Run: `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -only-testing:NoteAITests/LocalCaptureHelperTests test`

Expected: PASS.

## Task 2: Swift Loopback HTTP Server and App Startup

**Files:**
- Create: `NoteAI/LocalHelper/LocalCaptureHelperServer.swift`
- Modify: `NoteAI/App/AppDelegate.swift`
- Test: `NoteAITests/LocalCaptureHelperTests.swift`

- [ ] **Step 1: Write failing Swift routing tests**

```swift
func testRouterReturnsHealthWithoutAuthorization() async throws {
    let server = LocalCaptureHelperRouter(
        statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
        pairingStore: LocalCaptureHelperPairingStore(trustedClientStore: InMemoryTrustedClientStore()),
        allowedOrigins: ["http://localhost:3000"]
    )

    let response = await server.route(.init(method: "GET", path: "/v1/health", headers: ["Origin": "http://localhost:3000"], body: Data()))

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertTrue(response.bodyText.contains("\"status\":\"ready\""))
    XCTAssertEqual(response.headers["Access-Control-Allow-Origin"], "http://localhost:3000")
}

func testStatusRequiresPairedBearerToken() async throws {
    let server = LocalCaptureHelperRouter(
        statusProvider: LocalCaptureHelperStatusProvider(helperVersion: "0.1.0"),
        pairingStore: LocalCaptureHelperPairingStore(trustedClientStore: InMemoryTrustedClientStore()),
        allowedOrigins: ["http://localhost:3000"]
    )

    let response = await server.route(.init(method: "GET", path: "/v1/status", headers: ["Origin": "http://localhost:3000"], body: Data()))

    XCTAssertEqual(response.statusCode, 401)
    XCTAssertTrue(response.bodyText.contains("pairing_required"))
}
```

- [ ] **Step 2: Run Swift routing tests to verify RED**

Run: `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -only-testing:NoteAITests/LocalCaptureHelperTests test`

Expected: FAIL because router/server types do not exist.

- [ ] **Step 3: Implement router/server and wire AppDelegate**

Implement:
- HTTP parser/response writer for the M1 endpoints.
- Loopback listener on `127.0.0.1:47391`.
- Host and Origin validation.
- CORS preflight responses with no wildcard origins.
- Native pairing presenter using `NSAlert` on the main actor.
- AppDelegate lifecycle start/stop, skipped during XCTest.

- [ ] **Step 4: Run Swift routing tests to verify GREEN**

Run: `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -only-testing:NoteAITests/LocalCaptureHelperTests test`

Expected: PASS.

## Task 3: Web Helper Client and Source Model

**Files:**
- Create: `web/src/lib/local-helper.ts`
- Create: `web/src/lib/recording-sources.ts`
- Test: `web/local-helper.test.mjs`

- [ ] **Step 1: Write failing Node tests**

```js
test("local helper validation rejects sensitive or unsupported health responses", () => {
  assert.equal(parseHelperHealth({ protocolVersion: "2026-04-28", helperVersion: "0.1.0", appName: "NoteAI Capture Helper", status: "ready", pairingRequired: true, capabilities: { status: true, pairing: true, captureControl: false, events: false, audioStreaming: false } }).kind, "available");
  assert.equal(parseHelperHealth({ status: "ready", capabilities: { audioStreaming: true } }).kind, "unavailable");
});

test("teams desktop source is visible but not startable without capture control", () => {
  const source = teamsDesktopSourceFromHelper({ connection: "connected", paired: true, captureControl: false, teamsDetected: true, diagnostics: [] });
  assert.equal(source.id, "teamsDesktop");
  assert.equal(source.visible, true);
  assert.equal(source.canStart, false);
});
```

- [ ] **Step 2: Run Node test to verify RED**

Run: `cd web && node --test local-helper.test.mjs`

Expected: FAIL because helper client/source exports do not exist.

- [ ] **Step 3: Implement helper client and source model**

Implement:
- `detectLocalHelper(fetchImpl, storage)` with timeout and safe failure states.
- `parseHelperHealth` and `parseHelperStatus` runtime validation.
- `requestPairing`, `confirmPairing`, `load/store/clear token`.
- `recordingSourcesFromHelper` with Browser / Tab plus Teams Desktop.
- Teams Desktop source visible for all states, disabled until future `captureControl` is true.

- [ ] **Step 4: Run Node test to verify GREEN**

Run: `cd web && node --test local-helper.test.mjs`

Expected: PASS.

## Task 4: Web Sidebar and Settings Diagnostics

**Files:**
- Modify: `web/src/app/page.tsx`
- Modify: `web/src/components/Sidebar.tsx`
- Modify: `web/src/components/Settings.tsx`
- Test: `web/local-helper.test.mjs`

- [ ] **Step 1: Extend failing Node tests for UI integration anchors**

```js
test("teams desktop source copy stays diagnostic-only in UI files", () => {
  const sidebar = readFileSync(new URL("./src/components/Sidebar.tsx", import.meta.url), "utf8");
  const settings = readFileSync(new URL("./src/components/Settings.tsx", import.meta.url), "utf8");

  assert.match(sidebar, /Teams Desktop/);
  assert.match(sidebar, /Diagnostics only/);
  assert.match(settings, /Local Teams helper/);
}
```

- [ ] **Step 2: Run Node test to verify RED**

Run: `cd web && node --test local-helper.test.mjs`

Expected: FAIL because UI does not yet contain Teams Desktop helper diagnostics.

- [ ] **Step 3: Implement UI wiring**

Implement:
- `useLocalCaptureHelper` state in `page.tsx`.
- Props into `Sidebar` and `Settings`.
- Compact source selector with Browser / Tab and Teams Desktop buttons.
- Helper status row: Helper, Trust, Teams, Mic, Teams audio.
- Teams Desktop Start button disabled with diagnostic copy until capture control exists.
- Settings helper diagnostics section with pair action.

- [ ] **Step 4: Run Node test to verify GREEN**

Run: `cd web && node --test local-helper.test.mjs`

Expected: PASS.

## Task 5: Full Verification and Bookkeeping

**Files:**
- All touched files.

- [ ] **Step 1: Run Swift tests**

Run: `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI test`

Expected: PASS.

- [ ] **Step 2: Run web tests**

Run: `cd web && node --test *.test.mjs`

Expected: PASS.

- [ ] **Step 3: Run web lint/typecheck/build**

Run:

```bash
cd web
npm run lint
npx tsc --noEmit --pretty false
npm run build
```

Expected: all exit 0.

- [ ] **Step 4: Commit implementation**

Run:

```bash
git add NoteAI NoteAITests web docs/superpowers/plans/2026-04-28-noteai-teams-helper-m1.md
git commit -m "JPB-49 Implement Teams helper diagnostics"
```

Expected: commit succeeds with JPB-49 in the message.

- [ ] **Step 5: Update Linear**

Post a JPB-49 comment listing affected files, verification commands/results, no-audio-streaming confirmation, and remaining follow-ups for capture control/transcription.
