import assert from "node:assert/strict";
import test from "node:test";

import {
  disposeRecorder,
  resolveRecordingReadiness,
  startOwnedRecorder,
  startRecorderWithCleanup,
} from "./src/lib/recording-lifecycle.ts";

test("recording startup disposes partial recorder when microphone acquisition fails", async () => {
  const startError = new Error("Chrome cannot see any microphones.");
  let stopped = 0;
  const recorder = {
    stop() {
      stopped += 1;
    },
  };

  await assert.rejects(
    startRecorderWithCleanup(recorder, async () => {
      throw startError;
    }),
    startError
  );

  assert.equal(stopped, 1);
});

test("recording startup times out and disposes hung recorder setup", async () => {
  let stopped = 0;
  const recorder = {
    stop() {
      stopped += 1;
    },
  };

  await assert.rejects(
    startRecorderWithCleanup(
      recorder,
      async () => new Promise(() => {}),
      { timeoutMs: 1 }
    ),
    /Recording startup timed out/
  );

  assert.equal(stopped, 1);
});

test("owned recording startup exposes pending recorder to refresh cleanup", async () => {
  let resolveStart;
  const owner = { current: null };
  const recorder = {
    stop() {},
  };

  const started = startOwnedRecorder(
    owner,
    recorder,
    async () => new Promise((resolve) => {
      resolveStart = resolve;
    }),
    { timeoutMs: 0 }
  );

  assert.equal(owner.current, recorder);
  resolveStart();
  await started;
  assert.equal(owner.current, recorder);
});

test("owned recording startup clears active recorder after startup failure", async () => {
  const owner = { current: null };
  const recorder = {
    stop() {},
  };
  const startError = new Error("Microphone unavailable");

  await assert.rejects(
    startOwnedRecorder(
      owner,
      recorder,
      async () => {
        throw startError;
      },
      { timeoutMs: 0 }
    ),
    startError
  );

  assert.equal(owner.current, null);
});

test("recording startup preserves original failure when cleanup also fails", async () => {
  const startError = new Error("Microphone unavailable");
  const recorder = {
    stop() {
      throw new Error("cleanup failed");
    },
  };
  const originalWarn = console.warn;
  console.warn = () => {};

  try {
    await assert.rejects(
      startRecorderWithCleanup(recorder, async () => {
        throw startError;
      }),
      startError
    );
  } finally {
    console.warn = originalWarn;
  }
});

test("recording disposal tolerates already cleared recorders", () => {
  assert.doesNotThrow(() => disposeRecorder(null));
});

test("recording readiness keeps manual recording primary when calendar and browser detection are unavailable", () => {
  const readiness = resolveRecordingReadiness({
    state: "idle",
    activeSource: {
      id: "browser-tab",
      label: "Browser Tab",
      description: "Capture the browser microphone and optional shared tab audio.",
      icon: "browser",
      availability: "available",
      supportsRecording: true,
      statusLabel: "Ready",
    },
    calendarAuthConfigured: false,
    browserMeetingDetectionAvailable: false,
    upcomingCalendarEvent: null,
  });

  assert.equal(readiness.mode, "manual-fallback");
  assert.equal(readiness.title, "Manual recording");
  assert.match(readiness.detail, /Calendar prompts are unavailable/);
  assert.equal(readiness.primaryActionTitle, "Start Recording");
});

test("recording readiness auto-arms when an authenticated calendar event is near", () => {
  const readiness = resolveRecordingReadiness({
    state: "idle",
    activeSource: {
      id: "browser-tab",
      label: "Browser Tab",
      description: "Capture the browser microphone and optional shared tab audio.",
      icon: "browser",
      availability: "available",
      supportsRecording: true,
      statusLabel: "Ready",
    },
    calendarAuthConfigured: true,
    browserMeetingDetectionAvailable: false,
    upcomingCalendarEvent: {
      title: "Customer Sync",
      startsAt: "2026-05-02T16:00:00.000Z",
    },
  });

  assert.equal(readiness.mode, "calendar-armed");
  assert.equal(readiness.title, "Customer Sync soon");
  assert.match(readiness.detail, /pre-meeting prompt/);
  assert.equal(readiness.badgeTitle, "Armed");
});

test("recording readiness surfaces Teams Desktop as a likely meeting source", () => {
  const readiness = resolveRecordingReadiness({
    state: "idle",
    activeSource: {
      id: "teams-desktop",
      label: "Teams Desktop",
      description: "Use the NoteAI macOS helper to capture Microsoft Teams desktop meetings.",
      icon: "teams",
      availability: "available",
      supportsRecording: true,
      statusLabel: "Ready",
    },
    calendarAuthConfigured: false,
    browserMeetingDetectionAvailable: false,
    upcomingCalendarEvent: null,
  });

  assert.equal(readiness.mode, "likely-meeting");
  assert.equal(readiness.title, "Teams Desktop ready");
  assert.match(readiness.detail, /likely meeting source/);
});
