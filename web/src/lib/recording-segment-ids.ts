export const FIRST_TRANSCRIPT_SEGMENT_ID = 1;

export interface PositiveSegmentIDSequence {
  next: () => number;
  reset: () => void;
}

export function createPositiveSegmentIDSequence(): PositiveSegmentIDSequence {
  let nextID = FIRST_TRANSCRIPT_SEGMENT_ID;

  return {
    next() {
      if (!Number.isSafeInteger(nextID) || nextID < FIRST_TRANSCRIPT_SEGMENT_ID) {
        throw new Error("Transcript segment ID space is exhausted.");
      }
      const id = nextID;
      nextID += 1;
      return id;
    },

    reset() {
      nextID = FIRST_TRANSCRIPT_SEGMENT_ID;
    },
  };
}

export function positiveTranscriptSegmentID(
  value: unknown,
  fallback: number,
): number {
  if (
    typeof value === "number"
    && Number.isSafeInteger(value)
    && value >= FIRST_TRANSCRIPT_SEGMENT_ID
  ) {
    return value;
  }
  if (!Number.isSafeInteger(fallback) || fallback < FIRST_TRANSCRIPT_SEGMENT_ID) {
    throw new Error("A positive safe transcript segment fallback ID is required.");
  }
  return fallback;
}
