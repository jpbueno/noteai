export const LOCAL_CAPTURE_HELPER_BASE_URL = "http://127.0.0.1:47391";
export const LOCAL_CAPTURE_HELPER_TOKEN_STORAGE_KEY = "noteai.localCaptureHelperToken";

export type LocalCaptureHelperConnectionState = "connected" | "unavailable";
export type LocalCaptureHelperPermissionStatus = "unknown" | "granted" | "denied" | "available" | "unavailable";
export type LocalCaptureHelperSourceStatus = "available" | "blocked" | "notProbed" | "capturing" | "idle" | "unavailable";
export type LocalCaptureHelperDiagnosticSeverity = "info" | "warning" | "error";
export type LocalHelperDiagnosticTone = "good" | "warning" | "muted";

export interface LocalCaptureHelperCapabilities {
  status: boolean;
  pairing: boolean;
  captureControl: boolean;
  events: boolean;
  audioStreaming: boolean;
}

export interface LocalCaptureHelperHealthResponse {
  protocolVersion: string;
  helperVersion: string;
  appName: string;
  status: "ready";
  pairingRequired: boolean;
  capabilities: LocalCaptureHelperCapabilities;
}

export interface LocalCaptureHelperPermissionDiagnostic {
  status: LocalCaptureHelperPermissionStatus;
  action?: string;
  reason?: string;
  requiresMacOS?: string;
}

export interface LocalCaptureHelperSourceDiagnostic {
  status: LocalCaptureHelperSourceStatus;
  level: number;
  adapter?: string;
  reason?: string;
  label?: string;
}

export interface LocalCaptureHelperStatusResponse {
  protocolVersion: string;
  helperVersion: string;
  captureState: string;
  recordingIndicator: string;
  permissions: {
    microphone: LocalCaptureHelperPermissionDiagnostic;
    screenRecording: LocalCaptureHelperPermissionDiagnostic;
    processTap: LocalCaptureHelperPermissionDiagnostic;
  };
  teams: {
    detected: boolean;
    bundleId?: string;
    pid?: number;
    displayName?: string;
    frontmost: boolean;
    audioActivity: string;
  };
  sources: {
    microphone: LocalCaptureHelperSourceDiagnostic;
    teamsAudio: LocalCaptureHelperSourceDiagnostic;
    desktopAudioFallback: LocalCaptureHelperSourceDiagnostic;
  };
  diagnostics: {
    severity: LocalCaptureHelperDiagnosticSeverity;
    code: string;
    message: string;
  }[];
}

export interface LocalCaptureHelperDetection {
  state: LocalCaptureHelperConnectionState;
  baseUrl: string;
  health?: LocalCaptureHelperHealthResponse;
  status?: LocalCaptureHelperStatusResponse;
  error?: string;
}

export interface LocalCapturePairRequestResponse {
  pairingSessionId: string;
  expiresAt: string;
  codeLength: number;
}

export interface LocalCapturePairConfirmResponse {
  accessToken: string;
  tokenId: string;
  origin: string;
  expiresAt: string | null;
}

export interface LocalCaptureTranscriptSegment {
  id: number;
  text: string;
  startTime: number;
  endTime: number;
  speaker: string | null;
  confidence: number;
}

export interface LocalCaptureStartRequest {
  source: "teamsDesktop";
  title?: string;
  includeMicrophone: boolean;
  allowDesktopAudioFallback: boolean;
}

export interface LocalCaptureStartResponse {
  sessionId: string;
  captureState: "recording" | string;
  startedAt: string;
  recordingIndicator: string;
}

export interface LocalCaptureStopResponse {
  sessionId: string;
  captureState: "stopped" | string;
  startedAt: string;
  stoppedAt: string;
  duration: number;
  transcript: LocalCaptureTranscriptSegment[];
}

export interface LocalHelperDiagnosticRow {
  label: string;
  value: string;
  tone: LocalHelperDiagnosticTone;
  detail?: string;
}

type HelperFetchResponse = {
  ok: boolean;
  status?: number;
  json: () => Promise<unknown>;
};

type HelperFetch = (input: string, init: RequestInit) => Promise<HelperFetchResponse>;

function defaultFetch(): HelperFetch | null {
  if (typeof fetch !== "function") return null;
  return fetch.bind(globalThis) as HelperFetch;
}

function createAbortSignal(timeoutMs: number): { signal?: AbortSignal; cancel: () => void } {
  if (typeof AbortController !== "function" || timeoutMs <= 0) {
    return { cancel: () => {} };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return {
    signal: controller.signal,
    cancel: () => clearTimeout(timer),
  };
}

function errorMessage(err: unknown): string {
  if (err instanceof DOMException && err.name === "AbortError") {
    return "Timed out while checking the local helper.";
  }
  return err instanceof Error ? err.message : String(err);
}

function isHealthResponse(value: unknown): value is LocalCaptureHelperHealthResponse {
  const candidate = value as Partial<LocalCaptureHelperHealthResponse> | null;
  return Boolean(
    candidate &&
      typeof candidate.protocolVersion === "string" &&
      typeof candidate.helperVersion === "string" &&
      candidate.appName === "NoteAI Capture Helper" &&
      candidate.status === "ready" &&
      typeof candidate.pairingRequired === "boolean" &&
      candidate.capabilities
  );
}

export async function detectLocalCaptureHelper({
  baseUrl = LOCAL_CAPTURE_HELPER_BASE_URL,
  fetchImpl = defaultFetch(),
  token,
  timeoutMs = 1_500,
}: {
  baseUrl?: string;
  fetchImpl?: HelperFetch | null;
  token?: string | null;
  timeoutMs?: number;
} = {}): Promise<LocalCaptureHelperDetection> {
  if (!fetchImpl) {
    return {
      state: "unavailable",
      baseUrl,
      error: "Fetch is not available in this environment.",
    };
  }

  const abort = createAbortSignal(timeoutMs);
  try {
    const response = await fetchImpl(`${baseUrl}/v1/health`, {
      method: "GET",
      mode: "cors",
      cache: "no-store",
      credentials: "omit",
      headers: {
        Accept: "application/json",
      },
      signal: abort.signal,
    });

    if (!response.ok) {
      return {
        state: "unavailable",
        baseUrl,
        error: `Local helper health returned HTTP ${response.status ?? "error"}.`,
      };
    }

    const health = await response.json();
    if (!isHealthResponse(health)) {
      return {
        state: "unavailable",
        baseUrl,
        error: "Local helper health response was not recognized.",
      };
    }

    const detection: LocalCaptureHelperDetection = {
      state: "connected",
      baseUrl,
      health,
    };

    if (token?.trim()) {
      try {
        detection.status = await getLocalCaptureHelperStatus({
          baseUrl,
          fetchImpl,
          token: token.trim(),
          timeoutMs,
        });
      } catch (err) {
        detection.error = errorMessage(err);
      }
    }

    return detection;
  } catch (err) {
    return {
      state: "unavailable",
      baseUrl,
      error: errorMessage(err),
    };
  } finally {
    abort.cancel();
  }
}

function currentOrigin(): string {
  if (typeof window !== "undefined" && window.location?.origin) {
    return window.location.origin;
  }
  return "http://localhost:3000";
}

export function createLocalCaptureClientNonce(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const raw = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  const encoded =
    typeof btoa === "function"
      ? btoa(raw)
      : Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return encoded.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export async function requestLocalCaptureHelperPairing({
  baseUrl = LOCAL_CAPTURE_HELPER_BASE_URL,
  fetchImpl = defaultFetch(),
  origin = currentOrigin(),
  clientName = "NoteAI Web",
  clientNonce = createLocalCaptureClientNonce(),
  timeoutMs = 5_000,
}: {
  baseUrl?: string;
  fetchImpl?: HelperFetch | null;
  origin?: string;
  clientName?: string;
  clientNonce?: string;
  timeoutMs?: number;
} = {}): Promise<LocalCapturePairRequestResponse> {
  if (!fetchImpl) {
    throw new Error("Fetch is not available in this environment.");
  }

  const abort = createAbortSignal(timeoutMs);
  try {
    const response = await fetchImpl(`${baseUrl}/v1/pair/request`, {
      method: "POST",
      mode: "cors",
      cache: "no-store",
      credentials: "omit",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ origin, clientName, clientNonce }),
      signal: abort.signal,
    });

    if (!response.ok) {
      throw new Error(`Local helper pairing request returned HTTP ${response.status ?? "error"}.`);
    }

    return (await response.json()) as LocalCapturePairRequestResponse;
  } finally {
    abort.cancel();
  }
}

export async function confirmLocalCaptureHelperPairing({
  baseUrl = LOCAL_CAPTURE_HELPER_BASE_URL,
  fetchImpl = defaultFetch(),
  pairingSessionId,
  code,
  clientNonce,
  timeoutMs = 5_000,
}: {
  baseUrl?: string;
  fetchImpl?: HelperFetch | null;
  pairingSessionId: string;
  code: string;
  clientNonce: string;
  timeoutMs?: number;
}): Promise<LocalCapturePairConfirmResponse> {
  if (!fetchImpl) {
    throw new Error("Fetch is not available in this environment.");
  }

  const abort = createAbortSignal(timeoutMs);
  try {
    const response = await fetchImpl(`${baseUrl}/v1/pair/confirm`, {
      method: "POST",
      mode: "cors",
      cache: "no-store",
      credentials: "omit",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ pairingSessionId, code, clientNonce }),
      signal: abort.signal,
    });

    if (!response.ok) {
      throw new Error(`Local helper pairing confirmation returned HTTP ${response.status ?? "error"}.`);
    }

    return (await response.json()) as LocalCapturePairConfirmResponse;
  } finally {
    abort.cancel();
  }
}

export function readLocalCaptureHelperToken(): string | null {
  if (typeof window === "undefined") return null;
  return window.localStorage.getItem(LOCAL_CAPTURE_HELPER_TOKEN_STORAGE_KEY)?.trim() || null;
}

export function storeLocalCaptureHelperToken(token: string): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(LOCAL_CAPTURE_HELPER_TOKEN_STORAGE_KEY, token);
}

export async function getLocalCaptureHelperStatus({
  baseUrl = LOCAL_CAPTURE_HELPER_BASE_URL,
  fetchImpl = defaultFetch(),
  token,
  timeoutMs = 1_500,
}: {
  baseUrl?: string;
  fetchImpl?: HelperFetch | null;
  token: string;
  timeoutMs?: number;
}): Promise<LocalCaptureHelperStatusResponse> {
  if (!fetchImpl) {
    throw new Error("Fetch is not available in this environment.");
  }

  const abort = createAbortSignal(timeoutMs);
  try {
    const response = await fetchImpl(`${baseUrl}/v1/status`, {
      method: "GET",
      mode: "cors",
      cache: "no-store",
      credentials: "omit",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
      },
      signal: abort.signal,
    });

    if (!response.ok) {
      throw new Error(`Local helper status returned HTTP ${response.status ?? "error"}.`);
    }

    return (await response.json()) as LocalCaptureHelperStatusResponse;
  } finally {
    abort.cancel();
  }
}

async function parseHelperError(response: HelperFetchResponse, fallback: string): Promise<Error> {
  try {
    const payload = await response.json();
    const candidate = payload as { message?: unknown; error?: unknown } | null;
    if (typeof candidate?.message === "string" && candidate.message.trim()) {
      return new Error(candidate.message);
    }
    if (typeof candidate?.error === "string" && candidate.error.trim()) {
      return new Error(candidate.error);
    }
  } catch {}
  return new Error(fallback);
}

export async function startLocalCaptureHelperCapture({
  baseUrl = LOCAL_CAPTURE_HELPER_BASE_URL,
  fetchImpl = defaultFetch(),
  token,
  title,
  includeMicrophone = true,
  allowDesktopAudioFallback = true,
  timeoutMs = 120_000,
}: {
  baseUrl?: string;
  fetchImpl?: HelperFetch | null;
  token: string;
  title?: string;
  includeMicrophone?: boolean;
  allowDesktopAudioFallback?: boolean;
  timeoutMs?: number;
}): Promise<LocalCaptureStartResponse> {
  if (!fetchImpl) {
    throw new Error("Fetch is not available in this environment.");
  }
  const trimmedToken = token.trim();
  if (!trimmedToken) {
    throw new Error("Pair the NoteAI local helper before starting Teams Desktop capture.");
  }

  const payload: LocalCaptureStartRequest = {
    source: "teamsDesktop",
    ...(title?.trim() ? { title: title.trim() } : {}),
    includeMicrophone,
    allowDesktopAudioFallback,
  };

  const abort = createAbortSignal(timeoutMs);
  try {
    const response = await fetchImpl(`${baseUrl}/v1/capture/start`, {
      method: "POST",
      mode: "cors",
      cache: "no-store",
      credentials: "omit",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${trimmedToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
      signal: abort.signal,
    });

    if (!response.ok) {
      throw await parseHelperError(
        response,
        `Local helper capture start returned HTTP ${response.status ?? "error"}.`,
      );
    }

    return (await response.json()) as LocalCaptureStartResponse;
  } finally {
    abort.cancel();
  }
}

export async function stopLocalCaptureHelperCapture({
  baseUrl = LOCAL_CAPTURE_HELPER_BASE_URL,
  fetchImpl = defaultFetch(),
  token,
  timeoutMs = 30_000,
}: {
  baseUrl?: string;
  fetchImpl?: HelperFetch | null;
  token: string;
  timeoutMs?: number;
}): Promise<LocalCaptureStopResponse> {
  if (!fetchImpl) {
    throw new Error("Fetch is not available in this environment.");
  }
  const trimmedToken = token.trim();
  if (!trimmedToken) {
    throw new Error("Pair the NoteAI local helper before stopping Teams Desktop capture.");
  }

  const abort = createAbortSignal(timeoutMs);
  try {
    const response = await fetchImpl(`${baseUrl}/v1/capture/stop`, {
      method: "POST",
      mode: "cors",
      cache: "no-store",
      credentials: "omit",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${trimmedToken}`,
      },
      signal: abort.signal,
    });

    if (!response.ok) {
      throw await parseHelperError(
        response,
        `Local helper capture stop returned HTTP ${response.status ?? "error"}.`,
      );
    }

    return (await response.json()) as LocalCaptureStopResponse;
  } finally {
    abort.cancel();
  }
}

export function openLocalCaptureHelper(): boolean {
  if (typeof window === "undefined") return false;
  window.location.href = "noteai://capture-helper";
  return true;
}

function permissionRow(label: string, permission?: LocalCaptureHelperPermissionDiagnostic): LocalHelperDiagnosticRow {
  if (!permission) {
    return { label, value: "Unknown", tone: "muted" };
  }
  if (permission.status === "granted") {
    return { label, value: "Granted", tone: "good" };
  }
  if (permission.status === "available") {
    return { label, value: "Available", tone: "good", detail: permission.reason };
  }
  if (permission.status === "denied") {
    return {
      label,
      value: "Denied",
      tone: "warning",
      detail: permission.reason,
    };
  }
  return {
    label,
    value: permission.status === "unavailable" ? "Unavailable" : "Unknown",
    tone: "muted",
    detail: permission.reason,
  };
}

function sourceRow(label: string, source?: LocalCaptureHelperSourceDiagnostic): LocalHelperDiagnosticRow {
  if (!source) {
    return { label, value: "Unknown", tone: "muted" };
  }
  if (source.status === "capturing" || source.status === "available") {
    return {
      label,
      value: source.status === "capturing" ? "Capturing" : "Available",
      tone: "good",
      detail: source.label || source.adapter,
    };
  }
  if (source.status === "unavailable" || source.status === "blocked") {
    return {
      label,
      value: source.status === "blocked" ? "Blocked" : "Unavailable",
      tone: "warning",
      detail: source.reason,
    };
  }
  return {
    label,
    value: source.status === "notProbed" ? "Not probed" : "Idle",
    tone: "muted",
    detail: source.reason || source.label || source.adapter,
  };
}

export function formatLocalHelperDiagnosticRows(detection: LocalCaptureHelperDetection): LocalHelperDiagnosticRow[] {
  if (detection.state !== "connected" || !detection.health) {
    return [
      {
        label: "Helper",
        value: "Unavailable",
        tone: "warning",
        detail: detection.error,
      },
    ];
  }

  const rows: LocalHelperDiagnosticRow[] = [
    {
      label: "Helper",
      value: "Connected",
      tone: "good",
      detail: detection.health.appName,
    },
    {
      label: "Pairing",
      value: detection.status ? "Trusted" : detection.health.pairingRequired ? "Required" : "Not required",
      tone: detection.status || !detection.health.pairingRequired ? "good" : "warning",
      detail: detection.health.pairingRequired && !detection.status
        ? "Status details require an explicit trust handshake with the helper."
        : undefined,
    },
  ];

  if (!detection.status) return rows;

  rows.push(permissionRow("Microphone", detection.status.permissions.microphone));
  rows.push(permissionRow("Screen Recording", detection.status.permissions.screenRecording));
  rows.push({
    label: "Teams",
    value: detection.status.teams.detected ? "Detected" : "Not detected",
    tone: detection.status.teams.detected ? "good" : "muted",
    detail: detection.status.teams.displayName || detection.status.teams.bundleId,
  });
  rows.push(sourceRow("Mic", detection.status.sources.microphone));
  rows.push(sourceRow("Teams audio", detection.status.sources.teamsAudio));

  return rows;
}
