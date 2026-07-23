import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  consumeUpstreamResponse,
  createUpstreamAbortScope,
  UpstreamAbortError,
} from "./src/lib/upstream-abort.ts";

function controlledScheduler() {
  let callback = null;
  let cleared = false;
  return {
    adapter: {
      setTimeout(nextCallback, delay) {
        assert.equal(delay, 60_000);
        callback = nextCallback;
        return 1;
      },
      clearTimeout(handle) {
        assert.equal(handle, 1);
        cleared = true;
      },
    },
    fire() {
      assert.notEqual(callback, null);
      callback();
    },
    wasCleared() {
      return cleared;
    },
  };
}

function abortError() {
  const error = new Error("body read aborted");
  error.name = "AbortError";
  return error;
}

function pendingBody(signal, onStarted) {
  onStarted();
  return new Promise((_, reject) => {
    if (signal.aborted) {
      reject(abortError());
      return;
    }
    signal.addEventListener("abort", () => reject(abortError()), { once: true });
  });
}

test("request cancellation aborts the provider signal without becoming a timeout", () => {
  const request = new AbortController();
  const scheduler = controlledScheduler();
  const scope = createUpstreamAbortScope(request.signal, 60_000, scheduler.adapter);

  request.abort();

  assert.equal(scope.signal.aborted, true);
  assert.equal(scope.cause(), "request");
  scheduler.fire();
  assert.equal(scope.cause(), "request");
  scope.dispose();
  assert.equal(scheduler.wasCleared(), true);
});

test("provider timeout remains distinguishable from request cancellation", () => {
  const request = new AbortController();
  const scheduler = controlledScheduler();
  const scope = createUpstreamAbortScope(request.signal, 60_000, scheduler.adapter);

  scheduler.fire();

  assert.equal(scope.signal.aborted, true);
  assert.equal(scope.cause(), "timeout");
  request.abort();
  assert.equal(scope.cause(), "timeout");
  scope.dispose();
  assert.equal(scheduler.wasCleared(), true);
});

test("an already-aborted request creates an immediately cancelled provider scope", () => {
  const request = new AbortController();
  request.abort();
  const scheduler = controlledScheduler();
  const scope = createUpstreamAbortScope(request.signal, 60_000, scheduler.adapter);

  assert.equal(scope.signal.aborted, true);
  assert.equal(scope.cause(), "request");
  scope.dispose();
  assert.equal(scheduler.wasCleared(), false);
});

test("request cancellation remains active after success headers while JSON is pending", async () => {
  const request = new AbortController();
  const scheduler = controlledScheduler();
  let bodyStartedResolve;
  const bodyStarted = new Promise((resolve) => {
    bodyStartedResolve = resolve;
  });

  const operation = consumeUpstreamResponse(
    request.signal,
    60_000,
    async (signal) => ({
      ok: true,
      json: () => pendingBody(signal, bodyStartedResolve),
    }),
    scheduler.adapter,
  );

  await bodyStarted;
  assert.equal(scheduler.wasCleared(), false);
  request.abort();

  await assert.rejects(
    operation,
    (error) => error instanceof UpstreamAbortError && error.abortCause === "request",
  );
  assert.equal(scheduler.wasCleared(), true);
});

test("timeout remains active after error headers while text is pending", async () => {
  const request = new AbortController();
  const scheduler = controlledScheduler();
  let bodyStartedResolve;
  const bodyStarted = new Promise((resolve) => {
    bodyStartedResolve = resolve;
  });

  const operation = consumeUpstreamResponse(
    request.signal,
    60_000,
    async (signal) => ({
      ok: false,
      status: 429,
      text: () => pendingBody(signal, bodyStartedResolve),
    }),
    scheduler.adapter,
  );

  await bodyStarted;
  assert.equal(scheduler.wasCleared(), false);
  scheduler.fire();

  await assert.rejects(
    operation,
    (error) => error instanceof UpstreamAbortError && error.abortCause === "timeout",
  );
  assert.equal(scheduler.wasCleared(), true);
});

test("chat route uses the production body-lifetime interface for provider fetch", () => {
  const routeSource = readFileSync(
    new URL("./src/app/api/chat/route.ts", import.meta.url),
    "utf8",
  );

  assert.match(routeSource, /consumeUpstreamResponse\(/);
  assert.match(routeSource, /request\.signal/);
  assert.match(routeSource, /signal/);
  assert.match(routeSource, /error\.abortCause === "timeout"/);
  assert.match(routeSource, /error\.abortCause === "request"/);
});
