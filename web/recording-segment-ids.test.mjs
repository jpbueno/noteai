import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  FIRST_TRANSCRIPT_SEGMENT_ID,
  createPositiveSegmentIDSequence,
  positiveTranscriptSegmentID,
} from "./src/lib/recording-segment-ids.ts";

test("browser live segment IDs start at one and reset to one", () => {
  const sequence = createPositiveSegmentIDSequence();

  assert.equal(sequence.next(), 1);
  assert.equal(sequence.next(), 2);
  sequence.reset();
  assert.equal(sequence.next(), 1);
});

test("recording persistence preserves valid IDs and replaces invalid fallbacks", () => {
  assert.equal(FIRST_TRANSCRIPT_SEGMENT_ID, 1);
  assert.equal(positiveTranscriptSegmentID(9, 1), 9);
  assert.equal(positiveTranscriptSegmentID(1.0, 2), 1);
  assert.equal(positiveTranscriptSegmentID(1e0, 3), 1);
  assert.equal(positiveTranscriptSegmentID(0, 4), 4);
  assert.equal(positiveTranscriptSegmentID(-1, 5), 5);
  assert.equal(positiveTranscriptSegmentID(1.5, 6), 6);
  assert.equal(positiveTranscriptSegmentID(true, 7), 7);
  assert.equal(positiveTranscriptSegmentID(Number.MAX_SAFE_INTEGER + 1, 8), 8);
});

test("useRecording wires the positive ID production helpers into live and persisted segments", () => {
  const hooksSource = readFileSync(new URL("./src/lib/hooks.ts", import.meta.url), "utf8");

  assert.match(hooksSource, /createPositiveSegmentIDSequence/);
  assert.match(hooksSource, /segmentIDsRef\.current\.reset\(\)/);
  assert.match(hooksSource, /id: segmentIDsRef\.current\.next\(\)/);
  assert.match(hooksSource, /positiveTranscriptSegmentID\(segment\.id, index \+ 1\)/);
  assert.doesNotMatch(hooksSource, /id: 0,\s*text:/);
});
