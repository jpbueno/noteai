export interface DisposableRecorder {
  stop: () => unknown;
}

export interface RecorderOwner<T extends DisposableRecorder> {
  current: T | null;
}

export interface StartRecorderOptions {
  timeoutMs?: number;
}

export const DEFAULT_RECORDING_START_TIMEOUT_MS = 20000;

export type RecordingLifecycleState = "idle" | "starting" | "recording" | "processing";
export type RecordingReadinessMode =
  | "manual-fallback"
  | "likely-meeting"
  | "calendar-armed"
  | "starting"
  | "recording"
  | "processing";

export interface RecordingReadinessSource {
  id: string;
  label: string;
  supportsRecording: boolean;
  statusLabel: string;
}

export interface RecordingCalendarEvent {
  title: string;
  startsAt: string;
}

export interface RecordingReadinessInput {
  state: RecordingLifecycleState;
  activeSource: RecordingReadinessSource;
  calendarAuthConfigured: boolean;
  browserMeetingDetectionAvailable: boolean;
  upcomingCalendarEvent?: RecordingCalendarEvent | null;
}

export interface RecordingReadiness {
  mode: RecordingReadinessMode;
  title: string;
  detail: string;
  badgeTitle: string;
  primaryActionTitle: string;
}

export function resolveRecordingReadiness(input: RecordingReadinessInput): RecordingReadiness {
  if (input.state === "recording") {
    return {
      mode: "recording",
      title: "Recording",
      detail: `${input.activeSource.label} capture is active.`,
      badgeTitle: "Live",
      primaryActionTitle: "Stop Recording",
    };
  }

  if (input.state === "starting") {
    return {
      mode: "starting",
      title: "Starting capture",
      detail: "Waiting for browser recording permission.",
      badgeTitle: "Starting",
      primaryActionTitle: "Starting...",
    };
  }

  if (input.state === "processing") {
    return {
      mode: "processing",
      title: "Processing meeting",
      detail: "Finalizing transcript and summary.",
      badgeTitle: "Processing",
      primaryActionTitle: "Processing...",
    };
  }

  if (input.calendarAuthConfigured && input.upcomingCalendarEvent) {
    return {
      mode: "calendar-armed",
      title: `${input.upcomingCalendarEvent.title} soon`,
      detail: "Calendar access is available; a pre-meeting prompt is armed.",
      badgeTitle: "Armed",
      primaryActionTitle: "Start Recording",
    };
  }

  if (input.activeSource.id === "teams-desktop" && input.activeSource.supportsRecording) {
    return {
      mode: "likely-meeting",
      title: "Teams Desktop ready",
      detail: "The paired helper is a likely meeting source. Manual start remains available.",
      badgeTitle: "Signal",
      primaryActionTitle: "Start Recording",
    };
  }

  return {
    mode: "manual-fallback",
    title: "Manual recording",
    detail: manualFallbackDetail(input),
    badgeTitle: "Manual",
    primaryActionTitle: "Start Recording",
  };
}

function manualFallbackDetail(input: RecordingReadinessInput): string {
  if (!input.calendarAuthConfigured && !input.browserMeetingDetectionAvailable) {
    return "Calendar prompts are unavailable, and browser app detection is unavailable here. Manual recording remains primary.";
  }

  if (!input.calendarAuthConfigured) {
    return "Calendar prompts are unavailable. Manual recording remains primary.";
  }

  if (!input.browserMeetingDetectionAvailable) {
    return "No pre-meeting prompt is armed, and browser app detection is unavailable here. Manual recording remains primary.";
  }

  return "No likely meeting signal is active. Use explicit manual recording.";
}

export function disposeRecorder(recorder: DisposableRecorder | null | undefined): void {
  if (!recorder) return;

  try {
    recorder.stop();
  } catch (err) {
    console.warn("[NoteAI] Failed to dispose recorder:", err);
  }
}

export async function startRecorderWithCleanup<T extends DisposableRecorder>(
  recorder: T,
  start: () => Promise<void>,
  options: StartRecorderOptions = {}
): Promise<T> {
  const timeoutMs = options.timeoutMs ?? DEFAULT_RECORDING_START_TIMEOUT_MS;
  const startPromise = start();
  let timeoutId: ReturnType<typeof globalThis.setTimeout> | undefined;
  const timeoutPromise = new Promise<never>((_, reject) => {
    if (timeoutMs <= 0) return;

    timeoutId = globalThis.setTimeout(() => {
      reject(new Error(
        `Recording startup timed out after ${Math.round(timeoutMs / 1000)} seconds. ` +
        "Close any browser microphone or screen-share prompt and try again."
      ));
    }, timeoutMs);
  });

  // If timeout wins the race, startPromise may still settle later because
  // browser media prompts are not cancellable. Observe it to avoid noisy
  // unhandled rejections while recorder.stop() handles cleanup.
  startPromise.catch(() => {});

  try {
    await (timeoutMs > 0 ? Promise.race([startPromise, timeoutPromise]) : startPromise);
    return recorder;
  } catch (err) {
    disposeRecorder(recorder);
    throw err;
  } finally {
    if (timeoutId !== undefined) {
      globalThis.clearTimeout(timeoutId);
    }
  }
}

export async function startOwnedRecorder<T extends DisposableRecorder>(
  owner: RecorderOwner<T>,
  recorder: T,
  start: () => Promise<void>,
  options: StartRecorderOptions = {}
): Promise<T> {
  owner.current = recorder;

  try {
    await startRecorderWithCleanup(recorder, start, options);
    if (owner.current !== recorder) {
      disposeRecorder(recorder);
      throw new Error("Recording startup cancelled.");
    }
    return recorder;
  } catch (err) {
    if (owner.current === recorder) {
      owner.current = null;
    }
    throw err;
  }
}
