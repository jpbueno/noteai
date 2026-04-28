import assert from "node:assert/strict";
import test from "node:test";

import {
  LOCAL_CAPTURE_HELPER_BASE_URL,
  confirmLocalCaptureHelperPairing,
  detectLocalCaptureHelper,
  formatLocalHelperDiagnosticRows,
  getLocalCaptureHelperStatus,
  requestLocalCaptureHelperPairing,
  startLocalCaptureHelperCapture,
  stopLocalCaptureHelperCapture,
} from "./src/lib/local-helper.ts";
import {
  TEAMS_DESKTOP_RECORDING_SOURCE,
  buildRecordingSourceOptions,
} from "./src/lib/recording-sources.ts";

const healthResponse = {
  protocolVersion: "2026-04-28",
  helperVersion: "1",
  appName: "NoteAI Capture Helper",
  status: "ready",
  pairingRequired: true,
  capabilities: {
    status: true,
    pairing: true,
    captureControl: false,
    events: false,
    audioStreaming: false,
  },
};

const statusResponse = {
  protocolVersion: "2026-04-28",
  helperVersion: "1",
  captureState: "idle",
  recordingIndicator: "visible-idle",
  permissions: {
    microphone: { status: "granted" },
    screenRecording: { status: "denied", reason: "Screen Recording is disabled." },
    processTap: { status: "available", requiresMacOS: "14.2" },
  },
  teams: {
    detected: true,
    bundleId: "com.microsoft.teams2",
    pid: 123,
    displayName: "Microsoft Teams",
    frontmost: false,
    audioActivity: "unknown",
  },
  sources: {
    microphone: { status: "available", adapter: "microphone", level: 0 },
    teamsAudio: { status: "notProbed", adapter: "processTap", level: 0, reason: "Not capturing in M1." },
    desktopAudioFallback: { status: "blocked", adapter: "screenCaptureKit", level: 0 },
  },
  diagnostics: [
    { code: "screen-recording-permission", severity: "warning", message: "Screen Recording is disabled." },
  ],
};

test("local helper detection reads loopback health without requiring a token", async () => {
  const calls = [];
  const detection = await detectLocalCaptureHelper({
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return {
        ok: true,
        json: async () => healthResponse,
      };
    },
    timeoutMs: 1_000,
  });

  assert.equal(calls[0].url, `${LOCAL_CAPTURE_HELPER_BASE_URL}/v1/health`);
  assert.equal(calls[0].init.method, "GET");
  assert.equal(calls[0].init.cache, "no-store");
  assert.equal(detection.state, "connected");
  assert.equal(detection.health.capabilities.audioStreaming, false);
  assert.equal(detection.health.pairingRequired, true);
});

test("local helper detection is unavailable when localhost fetch fails", async () => {
  const detection = await detectLocalCaptureHelper({
    fetchImpl: async () => {
      throw new Error("connection refused");
    },
    timeoutMs: 1_000,
  });

  assert.equal(detection.state, "unavailable");
  assert.match(detection.error, /connection refused/i);
});

test("status request sends the origin-bound bearer token", async () => {
  const calls = [];
  const status = await getLocalCaptureHelperStatus({
    token: "paired-token",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return {
        ok: true,
        json: async () => statusResponse,
      };
    },
  });

  assert.equal(calls[0].url, `${LOCAL_CAPTURE_HELPER_BASE_URL}/v1/status`);
  assert.equal(calls[0].init.headers.Authorization, "Bearer paired-token");
  assert.equal(status.teams.detected, true);
});

test("pairing request and confirmation bind the helper token to the web origin", async () => {
  const calls = [];
  const pairRequest = await requestLocalCaptureHelperPairing({
    origin: "http://localhost:3000",
    clientName: "NoteAI Web",
    clientNonce: "nonce",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return {
        ok: true,
        json: async () => ({
          pairingSessionId: "session-id",
          expiresAt: "2026-04-28T12:02:00Z",
          codeLength: 6,
        }),
      };
    },
  });

  assert.equal(pairRequest.pairingSessionId, "session-id");
  assert.equal(calls[0].url, `${LOCAL_CAPTURE_HELPER_BASE_URL}/v1/pair/request`);
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    origin: "http://localhost:3000",
    clientName: "NoteAI Web",
    clientNonce: "nonce",
  });

  const confirmed = await confirmLocalCaptureHelperPairing({
    pairingSessionId: "session-id",
    code: "123456",
    clientNonce: "nonce",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return {
        ok: true,
        json: async () => ({
          accessToken: "paired-token",
          tokenId: "token-id",
          origin: "http://localhost:3000",
          expiresAt: null,
        }),
      };
    },
  });

  assert.equal(confirmed.accessToken, "paired-token");
  assert.equal(calls[1].url, `${LOCAL_CAPTURE_HELPER_BASE_URL}/v1/pair/confirm`);
  assert.deepEqual(JSON.parse(calls[1].init.body), {
    pairingSessionId: "session-id",
    code: "123456",
    clientNonce: "nonce",
  });
});

test("capture start posts an origin-bound Teams Desktop request to the helper", async () => {
  const calls = [];
  const started = await startLocalCaptureHelperCapture({
    token: "paired-token",
    title: "Weekly Sync",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return {
        ok: true,
        json: async () => ({
          sessionId: "11111111-1111-1111-1111-111111111111",
          captureState: "recording",
          startedAt: "2026-04-28T16:00:00Z",
          recordingIndicator: "visible-recording",
        }),
      };
    },
  });

  assert.equal(calls[0].url, `${LOCAL_CAPTURE_HELPER_BASE_URL}/v1/capture/start`);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers.Authorization, "Bearer paired-token");
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    source: "teamsDesktop",
    title: "Weekly Sync",
    includeMicrophone: true,
    allowDesktopAudioFallback: true,
  });
  assert.equal(started.captureState, "recording");
});

test("capture stop returns helper transcript segments for web persistence", async () => {
  const calls = [];
  const stopped = await stopLocalCaptureHelperCapture({
    token: "paired-token",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return {
        ok: true,
        json: async () => ({
          sessionId: "11111111-1111-1111-1111-111111111111",
          captureState: "stopped",
          startedAt: "2026-04-28T16:00:00Z",
          stoppedAt: "2026-04-28T16:10:00Z",
          duration: 600,
          transcript: [
            { id: 1, text: "Hello from Teams.", startTime: 0, endTime: 3, speaker: null, confidence: 0.9 },
          ],
        }),
      };
    },
  });

  assert.equal(calls[0].url, `${LOCAL_CAPTURE_HELPER_BASE_URL}/v1/capture/stop`);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers.Authorization, "Bearer paired-token");
  assert.equal(stopped.transcript[0].text, "Hello from Teams.");
});

test("diagnostic rows include connection, pairing, permissions, and Teams state", () => {
  const rows = formatLocalHelperDiagnosticRows({
    state: "connected",
    health: healthResponse,
    status: statusResponse,
  });

  assert.deepEqual(rows.map((row) => row.label), [
    "Helper",
    "Pairing",
    "Microphone",
    "Screen Recording",
    "Teams",
    "Mic",
    "Teams audio",
  ]);
  assert.equal(rows.find((row) => row.label === "Teams").tone, "good");
  assert.equal(rows.find((row) => row.label === "Screen Recording").tone, "warning");
});

test("Teams Desktop source records when paired helper advertises capture control", () => {
  assert.equal(TEAMS_DESKTOP_RECORDING_SOURCE.id, "teams-desktop");

  const options = buildRecordingSourceOptions({
    state: "connected",
    health: {
      ...healthResponse,
      capabilities: {
        ...healthResponse.capabilities,
        captureControl: true,
      },
    },
    status: statusResponse,
  });

  const teams = options.find((option) => option.id === "teams-desktop");
  assert.equal(teams.label, "Teams Desktop");
  assert.equal(teams.supportsRecording, true);
  assert.equal(teams.statusLabel, "Ready");
  assert.equal(teams.disabledReason, undefined);
});
