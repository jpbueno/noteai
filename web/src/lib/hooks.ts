"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { db } from "./db";
import type {
  Meeting,
  Note,
  TaskItem,
  T5TReport,
  ChatMessage,
  SidebarSelection,
  MeetingSummary,
  TranscriptSegment,
} from "./types";
import { AudioRecorder, type RecordingState } from "./audio";
import { summarizeTranscript, transcribeAudio } from "./ai";
import { v4 as uuid } from "uuid";

// Expose a global refresh trigger so mutations can force immediate refresh.
// No polling — data is fetched once on mount, then only when triggerRefresh() is called
// after a mutation. This keeps Vercel function invocations minimal (free tier friendly).
let globalRefreshCallbacks: (() => void)[] = [];
export function triggerRefresh() {
  globalRefreshCallbacks.forEach((cb) => cb());
}

function useRefreshable<T>(fetcher: () => Promise<T[]>): T[] {
  const [data, setData] = useState<T[]>([]);
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  const refresh = useCallback(async () => {
    try {
      const result = await fetcherRef.current();
      setData(result);
    } catch { /* keep stale */ }
  }, []);

  useEffect(() => {
    refresh();
    globalRefreshCallbacks.push(refresh);
    return () => {
      globalRefreshCallbacks = globalRefreshCallbacks.filter((cb) => cb !== refresh);
    };
  }, [refresh]);

  return data;
}

export function useMeetings() {
  return useRefreshable<Meeting>(() => db.meetings.toArray() as Promise<Meeting[]>);
}

export function useNotes() {
  return useRefreshable<Note>(() => db.notes.toArray() as Promise<Note[]>);
}

export function useTasks() {
  return useRefreshable<TaskItem>(() => db.tasks.toArray() as Promise<TaskItem[]>);
}

export function useT5TReports() {
  return useRefreshable<T5TReport>(() => db.t5tReports.toArray() as Promise<T5TReport[]>);
}

export function useChatMessages() {
  return useRefreshable<ChatMessage>(() => db.chatMessages.toArray() as Promise<ChatMessage[]>);
}

export function useSelection() {
  const [selection, setSelection] = useState<SidebarSelection>(null);
  return { selection, setSelection };
}

export function useSearch(
  meetings: Meeting[],
  notes: Note[],
  tasks: TaskItem[]
) {
  const [query, setQuery] = useState("");
  const q = query.toLowerCase().trim();

  const filteredMeetings = q
    ? meetings.filter(
        (m) =>
          m.title.toLowerCase().includes(q) ||
          m.transcript.some((s) => s.text.toLowerCase().includes(q))
      )
    : meetings;

  const filteredNotes = q
    ? notes.filter(
        (n) =>
          n.title.toLowerCase().includes(q) ||
          n.content.toLowerCase().includes(q) ||
          n.tags.some((t) => t.toLowerCase().includes(q))
      )
    : notes;

  const filteredTasks = q
    ? tasks.filter(
        (t) =>
          t.title.toLowerCase().includes(q) ||
          t.description.toLowerCase().includes(q)
      )
    : tasks;

  return { query, setQuery, filteredMeetings, filteredNotes, filteredTasks };
}

export function useRecording() {
  const recorderRef = useRef<AudioRecorder | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const segmentCounter = useRef(0);
  const interimRef = useRef("");
  const [state, setState] = useState<RecordingState>("idle");
  const [duration, setDuration] = useState(0);
  const [liveTranscript, setLiveTranscript] = useState<TranscriptSegment[]>([]);
  const [interimText, setInterimText] = useState("");
  const [capturingTabAudio, setCapturingTabAudio] = useState(false);

  const startRecording = useCallback(async (micDeviceId?: string, captureTab = false) => {
    try {
      segmentCounter.current = 0;
      interimRef.current = "";

      const recorder = new AudioRecorder();
      await recorder.start((text: string, isFinal: boolean) => {
        if (isFinal) {
          const elapsed = recorder.elapsed;
          setLiveTranscript((prev) => [
            ...prev,
            {
              id: segmentCounter.current++,
              text,
              startTime: Math.max(0, elapsed - 5),
              endTime: elapsed,
              speaker: null,
              confidence: 0.9,
            },
          ]);
          setInterimText("");
          interimRef.current = "";
        } else {
          setInterimText(text);
          interimRef.current = text;
        }
      }, micDeviceId, captureTab);

      recorderRef.current = recorder;
      setState("recording");
      setCapturingTabAudio(recorder.capturingTabAudio);
      setDuration(0);
      setLiveTranscript([]);
      setInterimText("");

      timerRef.current = setInterval(() => {
        setDuration((d) => d + 1);
      }, 1000);
    } catch (err) {
      console.error("Failed to start recording:", err);
      alert("Could not access microphone. Please grant permission and try again.");
    }
  }, []);

  const stopRecording = useCallback(
    async (title?: string): Promise<Meeting | null> => {
      if (!recorderRef.current) return null;

      if (timerRef.current) {
        clearInterval(timerRef.current);
        timerRef.current = null;
      }

      setState("processing");
      const hadTabAudio = recorderRef.current.capturingTabAudio;
      const audioBlob = recorderRef.current.stop();
      recorderRef.current = null;
      const recordedDuration = duration;
      const liveSegments = [...liveTranscript];

      // If we captured tab audio, send the full blob to Whisper for a complete
      // transcript that includes both speakers. Fall back to live segments if
      // Whisper is unavailable or fails.
      let finalText = "";
      let finalSegments: TranscriptSegment[] = liveSegments;

      if (hadTabAudio && audioBlob.size > 0) {
        try {
          const whisperText = await transcribeAudio(audioBlob);
          if (whisperText) {
            finalText = whisperText;
            finalSegments = [{
              id: 0,
              text: whisperText,
              startTime: 0,
              endTime: recordedDuration,
              speaker: null,
              confidence: 0.95,
            }];
          }
        } catch (err) {
          console.warn("[NoteAI] Whisper full-blob transcription failed, using live segments:", err);
          // Fall through to live segments
        }
      }

      if (!finalText) {
        finalText = liveSegments.map((s) => s.text).join(" ");
      }

      if (!finalText) {
        const meeting: Meeting = {
          id: uuid(),
          title: title || `Meeting ${new Date().toLocaleDateString()}`,
          date: new Date().toISOString(),
          duration: recordedDuration,
          transcript: [{ id: 0, text: "[No speech detected during recording]", startTime: 0, endTime: 0, speaker: null, confidence: 0 }],
          summary: { decisions: [], actionItems: [], topics: [], openQuestions: [], wasSummarized: false },
        };
        await db.meetings.add(meeting);
        triggerRefresh();
        setState("idle");
        setDuration(0);
        return meeting;
      }

      let summary: MeetingSummary;
      try {
        summary = await summarizeTranscript(finalText);
      } catch {
        summary = { decisions: [], actionItems: [], topics: [], openQuestions: [], wasSummarized: false };
      }

      const meeting: Meeting = {
        id: uuid(),
        title: title || `Meeting ${new Date().toLocaleDateString()}`,
        date: new Date().toISOString(),
        duration: recordedDuration,
        transcript: finalSegments,
        summary,
      };

      await db.meetings.add(meeting);
      triggerRefresh();
      setState("idle");
      setDuration(0);
      return meeting;
    },
    [duration, liveTranscript]
  );

  useEffect(() => {
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, []);

  return { state, duration, liveTranscript, interimText, capturingTabAudio, startRecording, stopRecording };
}

export function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  if (mins >= 60) {
    const hrs = Math.floor(mins / 60);
    const m = mins % 60;
    return `${hrs}h ${m}m`;
  }
  return `${String(mins).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
}

export function formatDate(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleDateString("en-US", { month: "2-digit", day: "2-digit", year: "2-digit" });
}

export function formatDateTime(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
}
