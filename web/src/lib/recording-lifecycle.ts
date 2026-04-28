export interface DisposableRecorder {
  stop: () => unknown;
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
  start: () => Promise<void>
): Promise<T> {
  try {
    await start();
    return recorder;
  } catch (err) {
    disposeRecorder(recorder);
    throw err;
  }
}
