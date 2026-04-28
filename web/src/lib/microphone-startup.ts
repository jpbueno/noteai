export type MicrophoneStartupErrorKind = "permission-denied" | "no-devices" | "access-failed";

export interface MicrophoneStartupErrorOptions {
  cause?: unknown;
  devices?: MediaDeviceInfo[];
}

export class MicrophoneStartupError extends Error {
  readonly kind: MicrophoneStartupErrorKind;
  readonly devices: MediaDeviceInfo[];
  override readonly cause?: unknown;

  constructor(kind: MicrophoneStartupErrorKind, message: string, options: MicrophoneStartupErrorOptions = {}) {
    super(message);
    this.name = "MicrophoneStartupError";
    this.kind = kind;
    this.devices = options.devices ?? [];
    this.cause = options.cause;
  }
}

export interface AcquiredMicrophoneStream {
  stream: MediaStream;
  devices: MediaDeviceInfo[];
}

export interface MicrophoneAcquisitionOptions {
  micDeviceId?: string;
  maxNoDeviceRetries?: number;
  retryDelayMs?: number;
  wait?: (ms: number) => Promise<void>;
}

type MediaDevicesSubset = Pick<MediaDevices, "getUserMedia" | "enumerateDevices">;

const DEFAULT_NO_DEVICE_RETRIES = 3;
const DEFAULT_RETRY_DELAY_MS = 650;

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => globalThis.setTimeout(resolve, ms));
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : "";
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function isPermissionDenied(err: unknown): boolean {
  return errorName(err) === "NotAllowedError" || errorName(err) === "PermissionDeniedError";
}

function microphoneAttempts(micDeviceId?: string): { constraints: MediaStreamConstraints }[] {
  return [
    ...(micDeviceId ? [{ constraints: { audio: { deviceId: { exact: micDeviceId } } } as MediaStreamConstraints }] : []),
    { constraints: { audio: true } },
    { constraints: { audio: { echoCancellation: true, noiseSuppression: true } } },
    { constraints: { audio: { sampleRate: 44100 } } },
  ];
}

export async function enumerateAudioInputDevices(mediaDevices: MediaDevicesSubset): Promise<MediaDeviceInfo[]> {
  const devices = await mediaDevices.enumerateDevices();
  return devices.filter((device) => device.kind === "audioinput");
}

export async function acquireMicrophoneStream(
  mediaDevices: MediaDevicesSubset,
  options: MicrophoneAcquisitionOptions = {}
): Promise<AcquiredMicrophoneStream> {
  const maxNoDeviceRetries = options.maxNoDeviceRetries ?? DEFAULT_NO_DEVICE_RETRIES;
  const retryDelayMs = options.retryDelayMs ?? DEFAULT_RETRY_DELAY_MS;
  const waitForRetry = options.wait ?? wait;
  let lastErr: unknown = null;
  let lastDevices: MediaDeviceInfo[] = [];

  for (let retry = 0; retry <= maxNoDeviceRetries; retry++) {
    for (const attempt of microphoneAttempts(options.micDeviceId)) {
      try {
        const stream = await mediaDevices.getUserMedia(attempt.constraints);
        const devices = await enumerateAudioInputDevices(mediaDevices).catch(() => []);
        return { stream, devices };
      } catch (err) {
        lastErr = err;
        if (isPermissionDenied(err)) {
          throw new MicrophoneStartupError(
            "permission-denied",
            errorMessage(err) || "Microphone permission denied",
            { cause: err }
          );
        }
      }
    }

    lastDevices = await enumerateAudioInputDevices(mediaDevices).catch(() => []);
    if (lastDevices.length > 0) {
      throw new MicrophoneStartupError(
        "access-failed",
        errorName(lastErr) || errorMessage(lastErr) || "Microphone access failed",
        { cause: lastErr, devices: lastDevices }
      );
    }

    if (retry < maxNoDeviceRetries) {
      await waitForRetry(retryDelayMs);
    }
  }

  throw new MicrophoneStartupError(
    "no-devices",
    "No microphones detected",
    { cause: lastErr, devices: lastDevices }
  );
}

export function formatMicrophoneStartupError(err: MicrophoneStartupError): string {
  if (err.kind === "permission-denied") {
    return (
      "Microphone permission denied.\n\n" +
      "1. Click the lock/tune icon in Chrome's address bar -> Microphone -> Allow\n" +
      "2. macOS: System Settings -> Privacy & Security -> Microphone -> Chrome ON\n" +
      "3. Reload this page"
    );
  }

  if (err.kind === "no-devices") {
    return (
      "Chrome couldn't see a microphone yet.\n\n" +
      "I released NoteAI's previous capture state and retried, but Chrome still reported zero audio-input devices.\n\n" +
      "Try Start Recording again in this tab. If a Chrome microphone or screen-share prompt is open, close it first."
    );
  }

  const devices = err.devices.map((device) => device.label || "unnamed").join(", ");
  return (
    `Mic access failed: ${err.message}\n\n` +
    `${err.devices.length} mic(s) detected: ${devices || "unnamed"}\n\n` +
    "Try Start Recording again, or click the lock/tune icon in Chrome's address bar -> Microphone -> Allow."
  );
}
