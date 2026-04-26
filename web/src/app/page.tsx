"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import HomeDashboard from "@/components/HomeDashboard";
import { NoteListView, MeetingListView, T5TListView } from "@/components/SectionListView";
import BrainHeadIcon from "@/components/BrainHeadIcon";
import Sidebar from "@/components/Sidebar";
import MeetingDetail from "@/components/MeetingDetail";
import NoteEditor from "@/components/NoteEditor";
import TodoDetail from "@/components/TodoDetail";
import T5TComposer from "@/components/T5TComposer";
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
  useChatMessages,
  useSearch,
  useRecording,
  triggerRefresh,
} from "@/lib/hooks";
import { useAICoach } from "@/lib/useAICoach";

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
  const [authState, setAuthState] = useState<"loading" | "authenticated" | "login">("loading");
  const [googleClientId, setGoogleClientId] = useState("");

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
  const chatMessages = useChatMessages();
  const { state: recordingState, duration, liveTranscript, interimText, capturingTabAudio, micLevel, startRecording, stopRecording } = useRecording();
  const { insights: coachInsights, isAnalyzing: coachAnalyzing, isReplying: coachReplying, enabled: coachEnabled, setEnabled: setCoachEnabled, sendMessage: sendCoachMessage } = useAICoach(liveTranscript, recordingState === "recording");

  const [selection, setSelection] = useState<SidebarSelection>(null);
  const [showChat, setShowChat] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [sidebarWidth, setSidebarWidth] = useState(220);
  const [isSidebarDragging, setIsSidebarDragging] = useState(false);

  const { query, setQuery, filteredMeetings, filteredNotes, filteredTodos } =
    useSearch(meetings, notes, todos);

  // One-time migration: clean up any remaining old TaskItems
  const migrationDone = useRef(false);
  useEffect(() => {
    if (migrationDone.current) return;
    migrationDone.current = true;
    (async () => {
      const tasks: TaskItem[] = await db.tasks.toArray() as TaskItem[];
      if (tasks.length === 0) return;
      for (const task of tasks) {
        await db.tasks.delete(task.id);
      }
      triggerRefresh();
    })();
  }, []);

  const handleNewNote = useCallback(async () => {
    const note = {
      id: crypto.randomUUID(),
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
      id: crypto.randomUUID(),
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

    // Title matches the Top 5 Things email subject line
    const focus = config.identity.focus || "Inference Ops";
    const region = config.identity.region || "NALA";
    const roleShort = config.identity.roleShort || "SA";
    const title = `Top 5 Things - ${focus} | ${region} | ${roleShort}`;

    const report = {
      id: crypto.randomUUID(),
      title,
      createdDate: new Date().toISOString(),
      periodStart: start.toISOString(),
      periodEnd: end.toISOString(),
      dailyLogIDs: [],
      meetingIDs: [],
      noteIDs: [],
      taskIDs: [],
      todoIDs: todos.map((t) => t.id),
      sections: [],
      status: "draft" as const,
    };
    await db.t5tReports.add(report);
    triggerRefresh();
    setSelection({ type: "t5t", id: report.id });
  }, [todos]);

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

  if (authState === "loading") return null;
  if (authState === "login") return <LoginForm clientId={googleClientId} onSuccess={() => setAuthState("authenticated")} />;

  const renderDetail = () => {
    if (!selection) {
      return (
        <HomeDashboard
          todos={todos}
          onSelect={setSelection}
          onNewTodo={handleNewTodo}
        />
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
          micLevel={micLevel}
          coachInsights={coachInsights}
          coachAnalyzing={coachAnalyzing}
          coachReplying={coachReplying}
          coachEnabled={coachEnabled}
          onToggleCoach={() => setCoachEnabled(!coachEnabled)}
          onCoachSendMessage={sendCoachMessage}
        />
      );
    }

    if (selection.type === "settings") {
      return <Settings />;
    }

    if (selection.type === "noteList") {
      return <NoteListView notes={notes} onSelect={setSelection} onNew={handleNewNote} />;
    }

    if (selection.type === "meetingList") {
      return <MeetingListView meetings={meetings} onSelect={setSelection} />;
    }

    if (selection.type === "t5tList") {
      return <T5TListView reports={t5tReports} onSelect={setSelection} onNew={handleNewT5T} />;
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

    if (selection.type === "t5t") {
      const report = t5tReports.find((r) => r.id === selection.id);
      if (report)
        return (
          <T5TComposer
            report={report}
            meetings={meetings}
            notes={notes}
            todos={todos}
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
          className={`flex-shrink-0 bg-sidebar border-r border-border relative ${isSidebarDragging ? "" : "transition-[margin-left] duration-300 ease-in-out"}`}
          style={{ width: sidebarWidth, marginLeft: sidebarCollapsed ? -sidebarWidth : 0 }}
        >
          {/* Resize handle */}
          <div
            className="absolute top-0 right-0 w-1 h-full cursor-col-resize z-20 hover:bg-accent/40 active:bg-accent/60 transition-colors"
            onMouseDown={(e) => {
              e.preventDefault();
              setIsSidebarDragging(true);
              const startX = e.clientX;
              const startWidth = sidebarWidth;
              const onMove = (ev: MouseEvent) => {
                const newWidth = Math.max(160, Math.min(400, startWidth + ev.clientX - startX));
                setSidebarWidth(newWidth);
              };
              const onUp = () => {
                setIsSidebarDragging(false);
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
            onDeleteMeeting={handleDeleteMeeting}
            onDeleteNote={handleDeleteNote}
            onDeleteTodo={handleDeleteTodo}
            onDeleteT5T={handleDeleteT5T}
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
