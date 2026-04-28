"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { db } from "./db";
import type {
  Meeting,
  Note,
  TodoItem,
  T5TReport,
  DailyLog,
  ChatMessage,
  SidebarSelection,
  MeetingSummary,
  TranscriptSegment,
} from "./types";
import { AudioRecorder, type RecordingState } from "./audio";
import { summarizeTranscript, transcribeAudio } from "./ai";
import { applyLibraryFilters, type LibraryQuickFilter } from "./search";
import { emptyRecordingDiagnostics, type RecordingDiagnostics } from "./recording-diagnostics";
import { disposeRecorder, startOwnedRecorder } from "./recording-lifecycle";

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

  useEffect(() => {
    fetcherRef.current = fetcher;
  }, [fetcher]);

  const refresh = useCallback(async () => {
    try {
      const result = await fetcherRef.current();
      if (Array.isArray(result)) {
        setData(result);
      }
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

export function useTodos() {
  return useRefreshable<TodoItem>(() => db.todos.toArray() as Promise<TodoItem[]>);
}

export function useT5TReports() {
  return useRefreshable<T5TReport>(() => db.t5tReports.toArray() as Promise<T5TReport[]>);
}

export function useDailyLogs() {
  return useRefreshable<DailyLog>(() => db.dailyLogs.toArray() as Promise<DailyLog[]>);
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
  todos: TodoItem[],
  quickFilter: LibraryQuickFilter = "all"
) {
  const [query, setQuery] = useState("");
  const {
    meetings: filteredMeetings,
    notes: filteredNotes,
    todos: filteredTodos,
  } = applyLibraryFilters({ meetings, notes, todos }, { query, quickFilter });

  return { query, setQuery, filteredMeetings, filteredNotes, filteredTodos };
}

export function useRecording() {
  const recorderRef = useRef<AudioRecorder | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const startingRef = useRef(false);
  const segmentCounter = useRef(0);
  const interimRef = useRef("");
  const [state, setState] = useState<RecordingState>("idle");
  const [duration, setDuration] = useState(0);
  const [liveTranscript, setLiveTranscript] = useState<TranscriptSegment[]>([]);
  const [interimText, setInterimText] = useState("");
  const [capturingTabAudio, setCapturingTabAudio] = useState(false);
  const [micLevel, setMicLevel] = useState(0);
  const [recordingDiagnostics, setRecordingDiagnostics] = useState<RecordingDiagnostics>(emptyRecordingDiagnostics);

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const disposeActiveRecorder = useCallback(() => {
    disposeRecorder(recorderRef.current);
    recorderRef.current = null;
    startingRef.current = false;
  }, []);

  const startRecording = useCallback(async (micDeviceId?: string, captureTab = false): Promise<boolean> => {
    if (startingRef.current || recorderRef.current) return false;

    let recorder: AudioRecorder | null = null;
    startingRef.current = true;

    try {
      setState("starting");
      setDuration(0);
      setLiveTranscript([]);
      setInterimText("");
      setCapturingTabAudio(false);
      setMicLevel(0);
      setRecordingDiagnostics(emptyRecordingDiagnostics);
      segmentCounter.current = 0;
      interimRef.current = "";

      recorder = new AudioRecorder();
      await startOwnedRecorder(recorderRef, recorder, () => recorder!.start((text: string, isFinal: boolean) => {
        if (isFinal) {
          const elapsed = recorder?.elapsed ?? 0;
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
      }, micDeviceId, captureTab, (level) => {
        setMicLevel(level);
      }, (diagnostics) => {
        setRecordingDiagnostics(diagnostics);
      }));

      setState("recording");
      setCapturingTabAudio(recorder.capturingTabAudio);
      setRecordingDiagnostics(recorder.diagnosticSnapshot);
      setDuration(0);
      setLiveTranscript([]);
      setInterimText("");

      timerRef.current = setInterval(() => {
        setDuration((d) => d + 1);
      }, 1000);
      return true;
    } catch (err) {
      console.error("Failed to start recording:", err);
      const msg = err instanceof Error ? err.message : String(err);
      if (recorderRef.current === recorder) {
        recorderRef.current = null;
      }
      setState("idle");
      setDuration(0);
      setLiveTranscript([]);
      setInterimText("");
      setCapturingTabAudio(false);
      setMicLevel(0);
      setRecordingDiagnostics(emptyRecordingDiagnostics);
      globalThis.setTimeout(() => {
        alert(`Recording failed:\n\n${msg}`);
      }, 0);
      return false;
    } finally {
      startingRef.current = false;
    }
  }, []);

  const stopRecording = useCallback(
    async (title?: string): Promise<Meeting | null> => {
      if (!recorderRef.current) return null;

      clearTimer();

      setState("processing");
      const hadTabAudio = recorderRef.current.capturingTabAudio;
      const audioBlob = recorderRef.current.stop();
      setRecordingDiagnostics(recorderRef.current.diagnosticSnapshot);
      recorderRef.current = null;
      const recordedDuration = duration;
      const liveSegments = [...liveTranscript];

      // If we captured tab audio, send the full blob to Whisper for a complete
      // transcript that includes both speakers. Fall back to live segments if
      // Whisper is unavailable or fails.
      let finalText = "";
      let finalSegments: TranscriptSegment[] = liveSegments;

      // Whisper API caps request size at 25 MB. A full-blob retranscribe on a
      // large recording silently truncates on some upstream providers, leaving
      // us with a single short segment that overwrites the live polling output.
      // Skip it for oversize blobs and trust the live segments accumulated
      // during recording.
      const WHISPER_MAX_BYTES = 24 * 1024 * 1024;
      if (hadTabAudio && audioBlob.size > 0 && audioBlob.size <= WHISPER_MAX_BYTES) {
        try {
          const whisperText = await transcribeAudio(audioBlob);
          const liveTextLen = liveSegments.reduce((acc, s) => acc + s.text.length, 0);
          // Only accept Whisper's result if it's at least as complete as what we
          // already have from live polling — guards against silent truncation.
          if (whisperText && whisperText.length >= liveTextLen) {
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
          id: crypto.randomUUID(),
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
        setCapturingTabAudio(false);
        setMicLevel(0);
        setRecordingDiagnostics(emptyRecordingDiagnostics);
        return meeting;
      }

      let summary: MeetingSummary;
      try {
        summary = await summarizeTranscript(finalText);
      } catch {
        summary = { decisions: [], actionItems: [], topics: [], openQuestions: [], wasSummarized: false };
      }

      const meeting: Meeting = {
        id: crypto.randomUUID(),
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
      setCapturingTabAudio(false);
      setMicLevel(0);
      setRecordingDiagnostics(emptyRecordingDiagnostics);
      return meeting;
    },
    [clearTimer, duration, liveTranscript]
  );

  useEffect(() => {
    const cleanup = () => {
      clearTimer();
      disposeActiveRecorder();
    };

    window.addEventListener("pagehide", cleanup);
    window.addEventListener("beforeunload", cleanup);

    return () => {
      window.removeEventListener("pagehide", cleanup);
      window.removeEventListener("beforeunload", cleanup);
      cleanup();
    };
  }, [clearTimer, disposeActiveRecorder]);

  return { state, duration, liveTranscript, interimText, capturingTabAudio, micLevel, recordingDiagnostics, startRecording, stopRecording };
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

export function parseDueDate(dueDate: string): Date {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(dueDate);
  if (match) {
    return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  }
  return new Date(dueDate);
}
