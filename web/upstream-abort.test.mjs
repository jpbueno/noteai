import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { createUpstreamAbortScope } from "./src/lib/upstream-abort.ts";

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

test("chat route uses the production abort scope for provider fetch", () => {
  const routeSource = readFileSync(
    new URL("./src/app/api/chat/route.ts", import.meta.url),
    "utf8",
  );

  assert.match(routeSource, /createUpstreamAbortScope\(request\.signal, CHAT_UPSTREAM_TIMEOUT_MS\)/);
  assert.match(routeSource, /signal: abortScope\.signal/);
  assert.match(routeSource, /abortScope\.cause\(\) === "timeout"/);
  assert.match(routeSource, /abortScope\.cause\(\) === "request"/);
  assert.match(routeSource, /abortScope\.dispose\(\)/);
});
