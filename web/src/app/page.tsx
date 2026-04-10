"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { FileText } from "lucide-react";
import BrainHeadIcon from "@/components/BrainHeadIcon";
import Sidebar from "@/components/Sidebar";
import MeetingDetail from "@/components/MeetingDetail";
import NoteEditor from "@/components/NoteEditor";
import TodoDetail from "@/components/TodoDetail";
import T5TComposer from "@/components/T5TComposer";
import DailyLogEditor from "@/components/DailyLogEditor";
import ChatPanel from "@/components/ChatPanel";
import Settings from "@/components/Settings";
import LiveTranscript from "@/components/LiveTranscript";
import { db, getT5TConfig } from "@/lib/db";
import type { SidebarSelection, T5TConfig, TaskItem } from "@/lib/types";
import { DEFAULT_T5T_CONFIG } from "@/lib/types";
import {
  useMeetings,
  useNotes,
  useTodos,
  useT5TReports,
  useDailyLogs,
  useChatMessages,
  useSearch,
  useRecording,
  triggerRefresh,
} from "@/lib/hooks";
import { v4 as uuid } from "uuid";

declare global {
  interface Window {
    google?: {
      accounts: {
        id: {
          initialize: (config: { client_id: string; callback: (response: { credential: string }) => void; auto_select?: boolean }) => void;
          renderButton: (element: HTMLElement, config: { theme?: string; size?: string; width?: number; shape?: string; text?: string }) => void;
        };
      };
    };
  }
}

function LoginForm({ clientId, onSuccess }: { clientId: string; onSuccess: () => void }) {
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const buttonRef = useCallback(
    (node: HTMLDivElement | null) => {
      if (!node || !window.google) return;
      window.google.accounts.id.initialize({
        client_id: clientId,
        callback: async (response) => {
          setLoading(true);
          setError("");
          try {
            const res = await fetch("/api/auth", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ credential: response.credential }),
            });
            const data = await res.json();
            if (res.ok) {
              onSuccess();
            } else {
              setError(data.error || "Sign-in failed");
            }
          } catch {
            setError("Connection failed");
          }
          setLoading(false);
        },
      });
      window.google.accounts.id.renderButton(node, {
        theme: "filled_black",
        size: "large",
        width: 320,
        shape: "pill",
        text: "signin_with",
      });
    },
    [clientId, onSuccess],
  );

  return (
    <div className="flex items-center justify-center h-screen bg-content">
      <div className="w-80 space-y-6 text-center">
        <div className="flex items-center gap-2.5 justify-center mb-2">
          <BrainHeadIcon className="w-8 h-8 text-text-secondary" />
          <div className="flex flex-col leading-tight">
            <span className="text-2xl font-semibold text-text-primary">NoteAI</span>
            <span className="text-[10px] font-medium text-text-tertiary -mt-0.5">v3.0</span>
          </div>
        </div>
        <p className="text-sm text-text-tertiary">Sign in to access your meetings and notes</p>
        <div className="flex justify-center">
          {loading ? (
            <p className="text-sm text-text-secondary">Signing in...</p>
          ) : (
            <div ref={buttonRef} />
          )}
        </div>
        {error && <p className="text-sm text-danger">{error}</p>}
      </div>
    </div>
  );
}

export default function Home() {
  const [mounted, setMounted] = useState(false);
  const [authState, setAuthState] = useState<"loading" | "authenticated" | "login">("loading");
  const [googleClientId, setGoogleClientId] = useState("");

  useEffect(() => { setMounted(true); }, []);

  useEffect(() => {
    fetch("/api/auth")
      .then(async (res) => {
        const data = await res.json();
        if (!data.required || data.authenticated) {
          setAuthState("authenticated");
        } else {
          setGoogleClientId(data.clientId || "");
          setAuthState("login");
        }
      })
      .catch(() => setAuthState("login"));
  }, []);

  const meetings = useMeetings();
  const notes = useNotes();
  const todos = useTodos();
  const t5tReports = useT5TReports();
  const dailyLogs = useDailyLogs();
  const chatMessages = useChatMessages();
  const { state: recordingState, duration, liveTranscript, interimText, capturingTabAudio, startRecording, stopRecording } = useRecording();

  const [selection, setSelection] = useState<SidebarSelection>(null);
  const [showChat, setShowChat] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [sidebarWidth, setSidebarWidth] = useState(220);
  const isDragging = useRef(false);

  const { query, setQuery, filteredMeetings, filteredNotes, filteredTodos } =
    useSearch(meetings, notes, todos);

  // One-time migration: convert any remaining tasks into daily logs, then delete them
  const migrationDone = useRef(false);
  useEffect(() => {
    if (migrationDone.current) return;
    migrationDone.current = true;
    (async () => {
      const tasks: TaskItem[] = await db.tasks.toArray() as TaskItem[];
      if (tasks.length === 0) return;

      let config: T5TConfig;
      try { config = await getT5TConfig(); } catch { config = DEFAULT_T5T_CONFIG; }

      for (const task of tasks) {
        const date = task.createdDate.slice(0, 10);
        const existingLogs: { id: string; date: string; sections: { name: string; content: string }[] }[] =
          await db.dailyLogs.toArray() as never[];
        const existing = existingLogs.find((d) => d.date === date);

        const sectionName = task.status === "completed" ? "Project Work" : "In-Progress & Carry-Over";
        const line = `- [Task] ${task.title}${task.description ? ": " + task.description : ""} [${task.status}]`;

        if (existing) {
          const newSections = existing.sections.map((s) => {
            if (s.name === sectionName) {
              return { ...s, content: s.content ? s.content + "\n" + line : line };
            }
            return s;
          });
          // If the section didn't exist, add it
          if (!newSections.find((s) => s.name === sectionName)) {
            newSections.push({ name: sectionName, content: line });
          }
          await db.dailyLogs.update(existing.id, { sections: newSections, modifiedDate: new Date().toISOString() });
        } else {
          const sections = config.dailyTemplate.map((t) => ({
            name: t.name,
            content: t.name === sectionName ? line : "",
          }));
          await db.dailyLogs.add({
            id: uuid(),
            date,
            sections,
            linkedMeetingIDs: [],
            createdDate: new Date().toISOString(),
            modifiedDate: new Date().toISOString(),
          });
        }
        await db.tasks.delete(task.id);
      }
      triggerRefresh();
    })();
  }, []);

  const handleNewNote = useCallback(async () => {
    const note = {
      id: uuid(),
      title: "Untitled",
      content: "",
      tags: [],
      createdDate: new Date().toISOString(),
      modifiedDate: new Date().toISOString(),
      sourceMeetingID: null,
    };
    await db.notes.add(note);
    triggerRefresh();
    setSelection({ type: "note", id: note.id });
  }, []);

  const handleNewTodo = useCallback(async () => {
    const todo = {
      id: uuid(),
      title: "",
      description: "",
      completed: 0,
      dueDate: null,
      createdDate: new Date().toISOString(),
      modifiedDate: new Date().toISOString(),
    };
    await db.todos.add(todo);
    triggerRefresh();
    setSelection({ type: "todo", id: todo.id });
  }, []);

  const handleNewDailyLog = useCallback(async () => {
    const today = new Date().toISOString().slice(0, 10);

    // Check if log for today already exists
    const existing = dailyLogs.find((d) => d.date === today);
    if (existing) {
      setSelection({ type: "dailyLog", id: existing.id });
      return;
    }

    // Load config for daily template
    let config: T5TConfig;
    try {
      config = await getT5TConfig();
    } catch {
      config = DEFAULT_T5T_CONFIG;
    }

    // Create sections from template
    const sections = config.dailyTemplate.map((t) => ({
      name: t.name,
      content: "",
    }));

    // Auto-link today's meetings
    const todayMeetings = meetings.filter(
      (m) => m.date.slice(0, 10) === today,
    );

    const log = {
      id: uuid(),
      date: today,
      sections,
      linkedMeetingIDs: todayMeetings.map((m) => m.id),
      createdDate: new Date().toISOString(),
      modifiedDate: new Date().toISOString(),
    };
    await db.dailyLogs.add(log);
    triggerRefresh();
    setSelection({ type: "dailyLog", id: log.id });
  }, [dailyLogs, meetings]);

  const handleNewT5T = useCallback(async () => {
    // Default to last 7 days (Mon-Fri work week)
    const end = new Date();
    const start = new Date();
    start.setDate(start.getDate() - 7);

    // Load config for title
    let config: T5TConfig;
    try {
      config = await getT5TConfig();
    } catch {
      config = DEFAULT_T5T_CONFIG;
    }

    const title = config.identity.team
      ? `Weekly Report – ${config.identity.team}`
      : "Weekly Report";

    // Auto-select daily logs and meetings in range
    const logsInRange = dailyLogs.filter((d) => {
      const date = new Date(d.date + "T12:00:00");
      return date >= start && date <= end;
    });
    const meetingsInRange = meetings.filter((m) => {
      const d = new Date(m.date);
      return d >= start && d <= end;
    });

    const report = {
      id: uuid(),
      title,
      createdDate: new Date().toISOString(),
      periodStart: start.toISOString(),
      periodEnd: end.toISOString(),
      dailyLogIDs: logsInRange.map((d) => d.id),
      meetingIDs: meetingsInRange.map((m) => m.id),
      noteIDs: [],
      taskIDs: [],
      sections: [],
      status: "draft" as const,
    };
    await db.t5tReports.add(report);
    triggerRefresh();
    setSelection({ type: "t5t", id: report.id });
  }, [meetings, dailyLogs]);

  const handleStopRecording = useCallback(async () => {
    const title = prompt("Meeting name:", `Meeting ${new Date().toLocaleDateString()}`);
    const meeting = await stopRecording(title || undefined);
    if (meeting) {
      setSelection({ type: "meeting", id: meeting.id });
    }
  }, [stopRecording]);

  const handleDeleteMeeting = useCallback(
    async (id: string) => {
      await db.meetings.delete(id);
      triggerRefresh();
      if (selection?.type === "meeting" && selection.id === id) setSelection(null);
    },
    [selection]
  );

  const handleDeleteNote = useCallback(
    async (id: string) => {
      await db.notes.delete(id);
      triggerRefresh();
      if (selection?.type === "note" && selection.id === id) setSelection(null);
    },
    [selection]
  );

  const handleDeleteTodo = useCallback(
    async (id: string) => {
      await db.todos.delete(id);
      triggerRefresh();
      if (selection?.type === "todo" && selection.id === id) setSelection(null);
    },
    [selection]
  );

  const handleDeleteT5T = useCallback(
    async (id: string) => {
      await db.t5tReports.delete(id);
      triggerRefresh();
      if (selection?.type === "t5t" && selection.id === id) setSelection(null);
    },
    [selection]
  );

  const handleDeleteDailyLog = useCallback(
    async (id: string) => {
      await db.dailyLogs.delete(id);
      triggerRefresh();
      if (selection?.type === "dailyLog" && selection.id === id) setSelection(null);
    },
    [selection]
  );



  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === "R") {
        e.preventDefault();
        if (recordingState === "recording") {
          handleStopRecording();
        } else if (recordingState === "idle") {
          startRecording();
        }
      }
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === "C") {
        e.preventDefault();
        setShowChat((prev) => !prev);
      }
      if ((e.ctrlKey || e.metaKey) && e.key === "k") {
        e.preventDefault();
        document.querySelector<HTMLInputElement>("[data-search-input]")?.focus();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [recordingState, startRecording, handleStopRecording]);

  if (!mounted || authState === "loading") return null;
  if (authState === "login") return <LoginForm clientId={googleClientId} onSuccess={() => setAuthState("authenticated")} />;

  const renderDetail = () => {
    if (!selection) {
      return (
        <div className="flex flex-col items-center justify-center h-full gap-3">
          <FileText className="w-9 h-9 text-text-tertiary" />
          <p className="text-base font-medium text-text-secondary">
            Select a meeting, note, or report
          </p>
          <p className="text-xs text-text-tertiary">
            Or start a recording to capture a new meeting
          </p>
        </div>
      );
    }

    if (selection.type === "liveTranscript") {
      return (
        <LiveTranscript
          duration={duration}
          segments={liveTranscript}
          interimText={interimText}
          onStop={handleStopRecording}
          capturingTabAudio={capturingTabAudio}
        />
      );
    }

    if (selection.type === "settings") {
      return <Settings />;
    }

    if (selection.type === "meeting") {
      const meeting = meetings.find((m) => m.id === selection.id);
      if (meeting) return <MeetingDetail meeting={meeting} onNavigate={setSelection} />;
    }

    if (selection.type === "note") {
      const note = notes.find((n) => n.id === selection.id);
      if (note) return <NoteEditor note={note} onNavigate={setSelection} />;
    }

    if (selection.type === "todo") {
      const todo = todos.find((t) => t.id === selection.id);
      if (todo) return <TodoDetail todo={todo} />;
    }

    if (selection.type === "dailyLog") {
      const log = dailyLogs.find((d) => d.id === selection.id);
      if (log) return <DailyLogEditor log={log} />;
    }

    if (selection.type === "t5t") {
      const report = t5tReports.find((r) => r.id === selection.id);
      if (report)
        return (
          <T5TComposer
            report={report}
            meetings={meetings}
            notes={notes}
            dailyLogs={dailyLogs}
            onNavigate={setSelection}
          />
        );
    }

    return null;
  };

  return (
    <div className="relative h-screen bg-content">
      {/* Fixed header — always visible, never moves */}
      <div
        onClick={() => setSidebarCollapsed((v) => !v)}
        className="fixed top-0 left-0 z-30 flex items-center gap-2.5 px-3.5 py-3 cursor-pointer hover:opacity-80 transition-opacity"
        style={{ height: 52 }}
      >
        <BrainHeadIcon className="w-[22px] h-[22px] text-text-secondary" />
        <div className="flex flex-col leading-tight">
          <span className="text-lg font-semibold text-text-primary">NoteAI</span>
          <span className="text-[10px] font-medium text-text-tertiary -mt-0.5">v3.0</span>
        </div>
      </div>

      <div className="flex h-screen">
        {/* Sidebar — slides via negative margin, always in DOM */}
        <div
          className={`flex-shrink-0 bg-sidebar border-r border-border relative ${isDragging.current ? "" : "transition-[margin-left] duration-300 ease-in-out"}`}
          style={{ width: sidebarWidth, marginLeft: sidebarCollapsed ? -sidebarWidth : 0 }}
        >
          {/* Resize handle */}
          <div
            className="absolute top-0 right-0 w-1 h-full cursor-col-resize z-20 hover:bg-accent/40 active:bg-accent/60 transition-colors"
            onMouseDown={(e) => {
              e.preventDefault();
              isDragging.current = true;
              const startX = e.clientX;
              const startWidth = sidebarWidth;
              const onMove = (ev: MouseEvent) => {
                const newWidth = Math.max(160, Math.min(400, startWidth + ev.clientX - startX));
                setSidebarWidth(newWidth);
              };
              const onUp = () => {
                isDragging.current = false;
                document.removeEventListener("mousemove", onMove);
                document.removeEventListener("mouseup", onUp);
                document.body.style.cursor = "";
                document.body.style.userSelect = "";
              };
              document.body.style.cursor = "col-resize";
              document.body.style.userSelect = "none";
              document.addEventListener("mousemove", onMove);
              document.addEventListener("mouseup", onUp);
            }}
          />
          <Sidebar
            meetings={filteredMeetings}
            notes={filteredNotes}
            todos={filteredTodos}
            t5tReports={t5tReports}
            dailyLogs={dailyLogs}
            selection={selection}
            onSelect={setSelection}
            searchQuery={query}
            onSearchChange={setQuery}
            recordingState={recordingState}
            recordingDuration={duration}
            onStartRecording={(micDeviceId, captureTab) => {
              startRecording(micDeviceId, captureTab);
              setSelection({ type: "liveTranscript" });
            }}
            onStopRecording={handleStopRecording}
            onNewNote={handleNewNote}
            onNewTodo={handleNewTodo}
            onNewT5T={handleNewT5T}
            onNewDailyLog={handleNewDailyLog}
            onDeleteMeeting={handleDeleteMeeting}
            onDeleteNote={handleDeleteNote}
            onDeleteTodo={handleDeleteTodo}
            onDeleteT5T={handleDeleteT5T}
            onDeleteDailyLog={handleDeleteDailyLog}
          />
        </div>

        {/* Main content */}
        <div className="flex-1 relative bg-content overflow-hidden">
          {renderDetail()}

          {/* Floating chat button */}
          {!showChat && (
            <button
              onClick={() => setShowChat(true)}
              className="absolute bottom-5 right-5 flex items-center justify-center w-12 h-12 rounded-full bg-accent text-white shadow-lg shadow-black/30 hover:bg-accent/80 transition-colors z-10"
            >
              <BrainHeadIcon className="w-[22px] h-[22px]" />
            </button>
          )}
        </div>

        {/* Chat drawer */}
        {showChat && (
          <>
            <div className="w-px bg-border" />
            <div className="w-[340px] flex-shrink-0">
              <ChatPanel
                messages={chatMessages}
                onClose={() => setShowChat(false)}
              />
            </div>
          </>
        )}
      </div>
    </div>
  );
}
