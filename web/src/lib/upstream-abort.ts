export type UpstreamAbortCause = "request" | "timeout";

export interface UpstreamAbortScheduler {
  setTimeout: (callback: () => void, delayMs: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

export interface UpstreamAbortScope {
  signal: AbortSignal;
  cause: () => UpstreamAbortCause | null;
  dispose: () => void;
}

const defaultScheduler: UpstreamAbortScheduler = {
  setTimeout: (callback, delayMs) => globalThis.setTimeout(callback, delayMs),
  clearTimeout: (handle) => {
    globalThis.clearTimeout(handle as ReturnType<typeof setTimeout>);
  },
};

export function createUpstreamAbortScope(
  requestSignal: AbortSignal,
  timeoutMs: number,
  scheduler: UpstreamAbortScheduler = defaultScheduler,
): UpstreamAbortScope {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error("A positive upstream timeout is required.");
  }

  const controller = new AbortController();
  let abortCause: UpstreamAbortCause | null = null;
  let timeoutHandle: unknown = null;
  let disposed = false;

  const abort = (cause: UpstreamAbortCause) => {
    if (abortCause !== null) return;
    abortCause = cause;
    controller.abort();
  };
  const onRequestAbort = () => abort("request");

  if (requestSignal.aborted) {
    abort("request");
  } else {
    requestSignal.addEventListener("abort", onRequestAbort, { once: true });
    timeoutHandle = scheduler.setTimeout(() => abort("timeout"), timeoutMs);
  }

  return {
    signal: controller.signal,
    cause: () => abortCause,
    dispose() {
      if (disposed) return;
      disposed = true;
      requestSignal.removeEventListener("abort", onRequestAbort);
      if (timeoutHandle !== null) scheduler.clearTimeout(timeoutHandle);
    },
  };
}
