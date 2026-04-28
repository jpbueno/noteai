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
