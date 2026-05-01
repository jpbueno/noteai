import assert from "node:assert/strict";
import test from "node:test";

import { buildOnboardingChecklist } from "./src/lib/onboarding.ts";

test("marks required setup incomplete until permissions and provider keys are ready", () => {
  const checklist = buildOnboardingChecklist({
    provider: "nvidia",
    providerKeyConfigured: false,
    transcriptionKeyConfigured: false,
    authConfigured: false,
    microphonePermission: "prompt",
    notificationPermission: "default",
    supportsMediaDevices: true,
    supportsNotifications: true,
    meetingCount: 0,
  });

  assert.equal(checklist.completedCount, 1);
  assert.equal(checklist.totalCount, 7);
  assert.deepEqual(
    checklist.items.map((item) => [item.id, item.status]),
    [
      ["microphone", "needs-action"],
      ["notifications", "needs-action"],
      ["auth", "needs-action"],
      ["ai-provider", "needs-action"],
      ["transcription", "needs-action"],
      ["privacy", "complete"],
      ["first-recording", "blocked"],
    ],
  );
});

test("validates required provider settings before recording", () => {
  const checklist = buildOnboardingChecklist({
    provider: "nvidia",
    providerKeyConfigured: false,
    transcriptionKeyConfigured: true,
    authConfigured: true,
    microphonePermission: "granted",
    notificationPermission: "granted",
    supportsMediaDevices: true,
    supportsNotifications: true,
    meetingCount: 0,
  });

  assert.equal(checklist.firstRecordingBlocker, "Add your NVIDIA summaries API key before recording.");
});

test("validates required provider settings after meetings exist", () => {
  const checklist = buildOnboardingChecklist({
    provider: "openai",
    providerKeyConfigured: false,
    transcriptionKeyConfigured: true,
    authConfigured: true,
    microphonePermission: "granted",
    notificationPermission: "granted",
    supportsMediaDevices: true,
    supportsNotifications: true,
    meetingCount: 2,
  });

  assert.equal(checklist.requiredReady, false);
  assert.equal(checklist.firstRecordingBlocker, "Add your OpenAI summaries API key before recording.");
  assert.equal(checklist.items.find((item) => item.id === "first-recording")?.status, "blocked");
});

test("shows unsupported browser capabilities explicitly", () => {
  const checklist = buildOnboardingChecklist({
    provider: "openrouter",
    providerKeyConfigured: true,
    transcriptionKeyConfigured: true,
    authConfigured: true,
    microphonePermission: "unknown",
    notificationPermission: "unsupported",
    supportsMediaDevices: false,
    supportsNotifications: false,
    meetingCount: 0,
  });

  assert.equal(checklist.items.find((item) => item.id === "microphone")?.status, "unsupported");
  assert.equal(checklist.items.find((item) => item.id === "notifications")?.status, "unsupported");
  assert.equal(checklist.requiredReady, false);
});

test("allows first recording once required setup is complete", () => {
  const checklist = buildOnboardingChecklist({
    provider: "anthropic",
    providerKeyConfigured: true,
    transcriptionKeyConfigured: true,
    authConfigured: true,
    microphonePermission: "granted",
    notificationPermission: "granted",
    supportsMediaDevices: true,
    supportsNotifications: true,
    meetingCount: 2,
  });

  assert.equal(checklist.requiredReady, true);
  assert.equal(checklist.completedCount, 7);
  assert.equal(checklist.items.find((item) => item.id === "first-recording")?.status, "complete");
  assert.equal(checklist.firstRecordingBlocker, null);
});
