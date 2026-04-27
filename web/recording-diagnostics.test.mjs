import assert from "node:assert/strict";
import test from "node:test";

import {
  createRecordingDiagnostics,
  recordingDiagnosticsWarnings,
  updateRecordingDiagnosticLevel,
} from "./src/lib/recording-diagnostics.ts";

test("browser recording diagnostics warn about denied mic and missing tab audio", () => {
  const diagnostics = createRecordingDiagnostics({
    microphonePermission: "denied",
    microphoneStatus: "unavailable",
    systemAudioStatus: "unavailable",
    systemAudioReason: "Tab audio was not shared",
  });

  assert.deepEqual(recordingDiagnosticsWarnings(diagnostics), [
    "Microphone permission is denied.",
    "System audio is not being captured: Tab audio was not shared.",
  ]);
});

test("browser recording diagnostics record levels without audio payloads", () => {
  const diagnostics = updateRecordingDiagnosticLevel(
    createRecordingDiagnostics({ microphoneStatus: "capturing" }),
    "microphone",
    0.42,
    1234
  );

  assert.equal(diagnostics.microphone.level, 0.42);
  assert.equal(diagnostics.microphone.updatedAt, 1234);
  assert.doesNotMatch(JSON.stringify(diagnostics), /blob|chunks|transcript|audioData/i);
});
