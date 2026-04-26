import { v4 as uuid } from "uuid";
import type { Meeting, MeetingSummary, TranscriptSegment } from "./types";
import { emptyMeetingSummary } from "./ai-tasks";

export type RecordingCompletionInput = {
  title?: string;
  duration: number;
  liveSegments: TranscriptSegment[];
  hadTabAudio: boolean;
  audioBlob: Blob;
};

export type RecordingCompletionDeps = {
  transcribeAudio: (audioBlob: Blob) => Promise<string>;
  summarizeTranscript: (transcript: string) => Promise<MeetingSummary>;
  saveMeeting: (meeting: Meeting) => Promise<void>;
  now?: () => Date;
  newId?: () => string;
};

export async function completeRecording(
  input: RecordingCompletionInput,
  deps: RecordingCompletionDeps
): Promise<Meeting> {
  const now = deps.now?.() || new Date();
  const newId = deps.newId || uuid;
  let finalText = "";
  let finalSegments = [...input.liveSegments];

  if (input.hadTabAudio && input.audioBlob.size > 0) {
    try {
      const whisperText = await deps.transcribeAudio(input.audioBlob);
      if (whisperText) {
        finalText = whisperText;
        finalSegments = [
          {
            id: 0,
            text: whisperText,
            startTime: 0,
            endTime: input.duration,
            speaker: null,
            confidence: 0.95,
          },
        ];
      }
    } catch (error) {
      console.warn("[NoteAI] Whisper full-blob transcription failed, using live segments:", error);
    }
  }

  if (!finalText) {
    finalText = input.liveSegments.map((segment) => segment.text).join(" ");
  }

  let summary: MeetingSummary;
  if (!finalText) {
    finalSegments = [
      {
        id: 0,
        text: "[No speech detected during recording]",
        startTime: 0,
        endTime: 0,
        speaker: null,
        confidence: 0,
      },
    ];
    summary = emptyMeetingSummary(false);
  } else {
    try {
      summary = await deps.summarizeTranscript(finalText);
    } catch {
      summary = emptyMeetingSummary(false);
    }
  }

  const meeting: Meeting = {
    id: newId(),
    title: input.title || `Meeting ${now.toLocaleDateString()}`,
    date: now.toISOString(),
    duration: input.duration,
    transcript: finalSegments,
    summary,
  };

  await deps.saveMeeting(meeting);
  return meeting;
}

