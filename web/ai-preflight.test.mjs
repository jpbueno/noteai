import assert from "node:assert/strict";
import test from "node:test";

import {
  copilotSetupMessage,
  recordingSetupBlocker,
} from "./src/lib/ai-preflight.ts";

test("recording preflight requires selected provider key after meetings exist", () => {
  assert.deepEqual(
    recordingSetupBlocker({
      provider: "openai",
      providerKeyConfigured: false,
      transcriptionKeyConfigured: true,
      microphoneStatus: "complete",
    }),
    {
      message: "Add your OpenAI summaries API key before recording.",
      target: "settings-ai",
    },
  );
});

test("recording preflight requires a transcription key before recording", () => {
  assert.deepEqual(
    recordingSetupBlocker({
      provider: "nvidia",
      providerKeyConfigured: true,
      transcriptionKeyConfigured: false,
      microphoneStatus: "complete",
    }),
    {
      message: "Add a Groq or OpenAI transcription key before recording.",
      target: "settings-ai",
    },
  );
});

test("recording preflight allows configured keys", () => {
  assert.equal(
    recordingSetupBlocker({
      provider: "anthropic",
      providerKeyConfigured: true,
      transcriptionKeyConfigured: true,
      microphoneStatus: "complete",
    }),
    null,
  );
});

test("copilot preflight explains missing selected provider key without secrets", () => {
  assert.equal(
    copilotSetupMessage({
      provider: "nvidia",
      providerKeyConfigured: false,
    }),
    "Add your NVIDIA API key in AI settings before using AI copilot.",
  );

  assert.equal(
    copilotSetupMessage({
      provider: "nvidia",
      providerKeyConfigured: true,
    }),
    null,
  );
});
