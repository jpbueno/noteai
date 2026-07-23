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

export class UpstreamAbortError extends Error {
  readonly abortCause: UpstreamAbortCause;

  constructor(abortCause: UpstreamAbortCause) {
    super(abortCause === "timeout" ? "Upstream request timed out" : "Request cancelled");
    this.name = "UpstreamAbortError";
    this.abortCause = abortCause;
  }
}

export type ConsumedUpstreamResponse =
  | { ok: true; data: unknown }
  | { ok: false; status: number; text: string };

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

async function runWithUpstreamAbortScope<T>(
  requestSignal: AbortSignal,
  timeoutMs: number,
  operation: (signal: AbortSignal) => Promise<T>,
  scheduler: UpstreamAbortScheduler = defaultScheduler,
): Promise<T> {
  const scope = createUpstreamAbortScope(requestSignal, timeoutMs, scheduler);
  try {
    const result = await operation(scope.signal);
    const abortCause = scope.cause();
    if (abortCause) throw new UpstreamAbortError(abortCause);
    return result;
  } catch (error) {
    if (error instanceof UpstreamAbortError) throw error;
    const abortCause = scope.cause();
    if (abortCause) throw new UpstreamAbortError(abortCause);
    throw error;
  } finally {
    scope.dispose();
  }
}

export async function consumeUpstreamResponse(
  requestSignal: AbortSignal,
  timeoutMs: number,
  fetchResponse: (signal: AbortSignal) => Promise<Response>,
  scheduler: UpstreamAbortScheduler = defaultScheduler,
): Promise<ConsumedUpstreamResponse> {
  return runWithUpstreamAbortScope(
    requestSignal,
    timeoutMs,
    async (signal) => {
      const response = await fetchResponse(signal);
      if (!response.ok) {
        return {
          ok: false,
          status: response.status,
          text: await response.text(),
        };
      }
      return { ok: true, data: await response.json() };
    },
    scheduler,
  );
}
