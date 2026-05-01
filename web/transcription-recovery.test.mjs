import assert from "node:assert/strict";
import test from "node:test";

import {
  buildIncompleteTranscriptWarning,
  chunkBlobForTranscription,
  shouldAcceptFinalWhisperTranscript,
} from "./src/lib/types.ts";

test("final Whisper replacement must be at least as complete as preserved live text", () => {
  assert.equal(shouldAcceptFinalWhisperTranscript("short", 20), false);
  assert.equal(shouldAcceptFinalWhisperTranscript("long enough transcript", 10), true);
  assert.equal(shouldAcceptFinalWhisperTranscript("   ", 0), false);
});

test("incomplete transcript warning uses the shared transcript segment shape", () => {
  const warning = buildIncompleteTranscriptWarning({
    id: 7,
    message: "Whisper chunk failed; live transcript preserved",
    startTime: 120,
    endTime: 135,
  });

  assert.deepEqual(warning, {
    id: 7,
    text: "[Transcript may be incomplete: Whisper chunk failed; live transcript preserved]",
    startTime: 120,
    endTime: 135,
    speaker: "System",
    confidence: 0,
  });
});

test("large blobs are left as live-transcript-only instead of sent past the proxy limit", () => {
  const small = new Blob(["a".repeat(1024)]);
  const large = new Blob(["a".repeat(25 * 1024 * 1024)]);

  assert.deepEqual(chunkBlobForTranscription(small, { maxBytes: 24 * 1024 * 1024 }), {
    chunks: [small],
    skipped: false,
  });
  assert.deepEqual(chunkBlobForTranscription(large, { maxBytes: 24 * 1024 * 1024 }), {
    chunks: [],
    skipped: true,
  });
});
