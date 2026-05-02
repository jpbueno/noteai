"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { MessageSquare, Plus, Search } from "lucide-react";
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
import { db, getSetting, getT5TConfig, isSettingConfigured } from "@/lib/db";
import type { LLMProvider, SidebarSelection, T5TConfig, TaskItem } from "@/lib/types";
import { DEFAULT_T5T_CONFIG } from "@/lib/types";
import {
  buildOnboardingChecklist,
  type OnboardingChecklistItem,
  type OnboardingPermission,
} from "@/lib/onboarding";
import { recordingSetupBlocker } from "@/lib/ai-preflight";
import type { LibraryQuickFilter } from "@/lib/search";
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
import {
  detectLocalCaptureHelper,
  openLocalCaptureHelper,
  readLocalCaptureHelperToken,
  type LocalCaptureHelperDetection,
} from "@/lib/local-helper";
import { buildRecordingSourceOptions, type RecordingSourceId } from "@/lib/recording-sources";

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
            <span className="text-[10px] font-medium text-text-tertiary -mt-0.5">v4.0</span>
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

function quickFilterLabel(filter: LibraryQuickFilter) {
  switch (filter) {
    case "recent":
      return "Recent meetings";
    case "openTodos":
      return "Open todos";
    case "unreviewed":
      return "Unreviewed summaries";
    case "all":
    default:
      return "All workspace";
  }
}

export default function Home() {
  const [authState, setAuthState] = useState<"loading" | "authenticated" | "login">("loading");
  const [googleClientId, setGoogleClientId] = useState("");
  const [calendarAuthConfigured, setCalendarAuthConfigured] = useState(false);

  useEffect(() => {
    fetch("/api/auth")
      .then(async (res) => {
        const data = await res.json();
        if (!data.required || data.authenticated) {
          setCalendarAuthConfigured(Boolean(data.required && data.authenticated));
          setAuthState("authenticated");
        } else {
          setGoogleClientId(data.clientId || "");
          setCalendarAuthConfigured(false);
          setAuthState("login");
        }
      })
      .catch(() => {
        setCalendarAuthConfigured(false);
        setAuthState("login");
      });
  }, []);

  const meetings = useMeetings();
  const notes = useNotes();
  const todos = useTodos();
  const t5tReports = useT5TReports();
  const chatMessages = useChatMessages();
  const { state: recordingState, duration, liveTranscript, interimText, capturingTabAudio, micLevel, recordingDiagnostics, startRecording, stopRecording } = useRecording();
  const { insights: coachInsights, isAnalyzing: coachAnalyzing, isReplying: coachReplying, enabled: coachEnabled, setEnabled: setCoachEnabled, sendMessage: sendCoachMessage } = useAICoach(liveTranscript, recordingState === "recording");

  const [selection, setSelection] = useState<SidebarSelection>(null);
  const [showChat, setShowChat] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [sidebarWidth, setSidebarWidth] = useState(220);
  const [isSidebarDragging, setIsSidebarDragging] = useState(false);
  const [quickFilter, setQuickFilter] = useState<LibraryQuickFilter>("all");
  const [localHelperDetection, setLocalHelperDetection] = useState<LocalCaptureHelperDetection | null>(null);
  const [onboardingProvider, setOnboardingProvider] = useState<LLMProvider>("openrouter");
  const [providerKeyConfigured, setProviderKeyConfigured] = useState(false);
  const [transcriptionKeyConfigured, setTranscriptionKeyConfigured] = useState(false);
  const [microphonePermission, setMicrophonePermission] = useState<OnboardingPermission>(() =>
    typeof navigator !== "undefined" && Boolean(navigator.mediaDevices?.getUserMedia) ? "unknown" : "unsupported",
  );
  const [notificationPermission, setNotificationPermission] = useState<OnboardingPermission>(() =>
    typeof window !== "undefined" && "Notification" in window ? Notification.permission : "unsupported",
  );
  const [supportsMediaDevices] = useState(() =>
    typeof navigator !== "undefined" && Boolean(navigator.mediaDevices?.getUserMedia),
  );
  const [supportsNotifications] = useState(() =>
    typeof window !== "undefined" && "Notification" in window,
  );
  const chatWidth = 360;

  const { query, setQuery, filteredMeetings, filteredNotes, filteredTodos } =
    useSearch(meetings, notes, todos, quickFilter);
  const recordingSources = buildRecordingSourceOptions(localHelperDetection);

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

  const loadOnboardingState = useCallback(async () => {
    const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
    const providerConfigured = await isSettingConfigured(`api_key_${provider}`);
    const groqConfigured = await isSettingConfigured("api_key_groq");
    const openAIConfigured = await isSettingConfigured("api_key_openai");
    return {
      provider,
      providerConfigured,
      transcriptionConfigured: groqConfigured || openAIConfigured,
    };
  }, []);

  const applyOnboardingState = useCallback(
    (state: Awaited<ReturnType<typeof loadOnboardingState>>) => {
      setOnboardingProvider(state.provider);
      setProviderKeyConfigured(state.providerConfigured);
      setTranscriptionKeyConfigured(state.transcriptionConfigured);
    },
    [],
  );

  const refreshOnboardingState = useCallback(async () => {
    applyOnboardingState(await loadOnboardingState());
  }, [applyOnboardingState, loadOnboardingState]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const state = await loadOnboardingState();
        if (!cancelled) applyOnboardingState(state);
      } catch {
        if (!cancelled) {
          setProviderKeyConfigured(false);
          setTranscriptionKeyConfigured(false);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [applyOnboardingState, loadOnboardingState]);

  useEffect(() => {
    if (selection?.type !== "settings") {
      let cancelled = false;
      void (async () => {
        try {
          const state = await loadOnboardingState();
          if (!cancelled) applyOnboardingState(state);
        } catch {}
      })();
      return () => {
        cancelled = true;
      };
    }
  }, [applyOnboardingState, loadOnboardingState, selection]);

  useEffect(() => {
    let cancelled = false;
    const refreshLocalHelper = async () => {
      const detection = await detectLocalCaptureHelper({ token: readLocalCaptureHelperToken() });
      if (!cancelled) setLocalHelperDetection(detection);
    };
    void refreshLocalHelper();
    const interval = setInterval(() => {
      void refreshLocalHelper();
    }, 5_000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    if (supportsMediaDevices && navigator.permissions?.query) {
      navigator.permissions
        .query({ name: "microphone" as PermissionName })
        .then((status) => {
          if (cancelled) return;
          setMicrophonePermission(status.state);
          status.onchange = () => setMicrophonePermission(status.state);
        })
        .catch(() => {
          if (!cancelled && supportsMediaDevices) setMicrophonePermission("unknown");
        });
    }

    return () => {
      cancelled = true;
    };
  }, [supportsMediaDevices]);

  const onboardingChecklist = buildOnboardingChecklist({
    provider: onboardingProvider,
    providerKeyConfigured,
    transcriptionKeyConfigured,
    authConfigured: authState === "authenticated",
    microphonePermission,
    notificationPermission,
    supportsMediaDevices,
    supportsNotifications,
    meetingCount: meetings.length,
  });

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
      sourceMeetingID: null,
      sourceActionItemID: null,
      owner: null,
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

  const guardedStartRecording = useCallback(
    async (
      micDeviceId?: string,
      captureTab = false,
      source: RecordingSourceId = "browser-tab",
    ) => {
      const latestOnboardingState = await loadOnboardingState();
      applyOnboardingState(latestOnboardingState);
      const blocker = recordingSetupBlocker({
        provider: latestOnboardingState.provider,
        providerKeyConfigured: latestOnboardingState.providerConfigured,
        transcriptionKeyConfigured: latestOnboardingState.transcriptionConfigured,
        microphoneStatus: onboardingChecklist.items.find((item) => item.id === "microphone")?.status ?? "needs-action",
      });

      if (blocker) {
        alert(blocker.message);
        setSelection({ type: "settings", tab: "ai" });
        return;
      }

      const started = await startRecording(micDeviceId, captureTab, source);
      if (!started) return;

      setSelection({ type: "liveTranscript" });
    },
    [applyOnboardingState, loadOnboardingState, onboardingChecklist.items, startRecording],
  );

  const handleOnboardingAction = useCallback(
    async (item: OnboardingChecklistItem) => {
      if (item.target === "recording") {
        void guardedStartRecording(undefined, true);
        return;
      }

      if (item.target === "settings-ai") {
        setSelection({ type: "settings", tab: "ai" });
        refreshOnboardingState();
        return;
      }

      if (item.target === "settings-general") {
        setSelection({ type: "settings", tab: "general" });
        refreshOnboardingState();
        return;
      }

      if (item.target === "settings-privacy") {
        if (
          item.id === "notifications" &&
          supportsNotifications &&
          Notification.permission === "default"
        ) {
          const next = await Notification.requestPermission();
          setNotificationPermission(next);
        }
        setSelection({ type: "settings", tab: "privacy" });
        refreshOnboardingState();
      }
    },
    [guardedStartRecording, refreshOnboardingState, supportsNotifications],
  );

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
          void guardedStartRecording();
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
  }, [recordingState, guardedStartRecording, handleStopRecording]);

  if (authState === "loading") return null;
  if (authState === "login") return <LoginForm clientId={googleClientId} onSuccess={() => {
    setCalendarAuthConfigured(true);
    setAuthState("authenticated");
  }} />;

  const renderDetail = () => {
    if (!selection) {
      return (
        <HomeDashboard
          todos={todos}
          onboardingChecklist={onboardingChecklist}
          onSelect={setSelection}
          onNewTodo={handleNewTodo}
          onOnboardingAction={handleOnboardingAction}
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
          diagnostics={recordingDiagnostics}
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
      return <Settings initialTab={selection.tab} />;
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
      if (meeting) return <MeetingDetail meeting={meeting} todos={todos} onNavigate={setSelection} />;
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
      <div className="flex h-screen">
        {/* Sidebar — slides via negative margin, always in DOM */}
        <div
          className={`flex-shrink-0 bg-sidebar/95 border-r border-border relative ${isSidebarDragging ? "" : "transition-[margin-left] duration-300 ease-in-out"}`}
          style={{ width: sidebarWidth, marginLeft: sidebarCollapsed ? -sidebarWidth : 0 }}
        >
          {/* Brand header lives inside the sliding drawer so it cannot overlap the command bar */}
          <button
            onClick={() => setSidebarCollapsed((v) => !v)}
            className="absolute left-0 top-0 z-30 flex h-[52px] w-full items-center gap-2.5 px-3.5 py-3 text-left transition-opacity hover:opacity-80"
            title={sidebarCollapsed ? "Show sidebar" : "Hide sidebar"}
          >
            <BrainHeadIcon className="w-[22px] h-[22px] flex-shrink-0 text-text-secondary" />
            <div className="min-w-0 flex flex-col leading-tight">
              <span className="truncate text-lg font-semibold text-text-primary">NoteAI</span>
              <span className="-mt-0.5 truncate text-[10px] font-medium text-text-tertiary">v4.0 Command Center</span>
            </div>
          </button>

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
            quickFilter={quickFilter}
            onQuickFilterChange={setQuickFilter}
            recordingState={recordingState}
            recordingDuration={duration}
            recordingSources={recordingSources}
            calendarAuthConfigured={calendarAuthConfigured}
            browserMeetingDetectionAvailable={false}
            onStartRecording={(micDeviceId, captureTab, source) => {
              void guardedStartRecording(micDeviceId, captureTab, source);
            }}
            onStopRecording={handleStopRecording}
            onOpenLocalHelper={() => {
              openLocalCaptureHelper();
            }}
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
          <div className="absolute top-0 left-0 right-0 z-20 h-[62px] border-b border-border/70 bg-content/88 backdrop-blur-xl">
            <div
              className={`flex h-full items-center justify-between gap-4 pr-7 transition-[padding-left] duration-300 ease-in-out ${
                sidebarCollapsed ? "pl-[72px]" : "pl-7"
              }`}
            >
              <button
                onClick={() => document.querySelector<HTMLInputElement>("[data-search-input]")?.focus()}
                className="flex h-10 min-w-[340px] max-w-[560px] flex-1 items-center gap-3 rounded-xl border border-border bg-sidebar/70 px-4 text-left text-sm text-text-tertiary hover:border-accent/45 hover:text-text-secondary transition-colors"
              >
                <Search className="h-4 w-4 text-text-tertiary" />
                <span className="truncate">
                  {quickFilter === "all"
                    ? "Command + K  Search meetings, notes, tasks..."
                    : `Command + K  ${quickFilterLabel(quickFilter)} filter active`}
                </span>
              </button>
              <div className="flex items-center gap-2">
                <button
                  onClick={handleNewNote}
                  className="flex h-10 items-center gap-2 rounded-xl border border-border bg-sidebar/70 px-3 text-sm font-semibold text-text-secondary hover:bg-selected hover:text-text-primary transition-colors"
                  title="New note"
                >
                  <Plus className="h-4 w-4" />
                  New note
                </button>
                <button
                  onClick={() => setShowChat((v) => !v)}
                  className={`flex h-10 items-center gap-2 rounded-xl px-3 text-sm font-semibold transition-colors ${
                    showChat
                      ? "border border-accent/45 bg-accent/12 text-accent hover:bg-accent/18"
                      : "bg-accent text-black hover:bg-accent/85"
                  }`}
                  title={showChat ? "Hide AI copilot" : "Open AI copilot"}
                >
                  <MessageSquare className="h-4 w-4" />
                  AI copilot
                </button>
              </div>
            </div>
          </div>

          <div className="h-full pt-[62px]">
            {renderDetail()}
          </div>
        </div>

        {/* Chat drawer — slides via negative margin, always in DOM */}
        <div
          className={`flex h-full flex-shrink-0 ${showChat ? "" : "pointer-events-none"} transition-[margin-right] duration-300 ease-in-out`}
          style={{ width: chatWidth, marginRight: showChat ? 0 : -chatWidth }}
          aria-hidden={!showChat}
        >
          <div className="w-px flex-shrink-0 bg-border/80" />
          <div className="min-w-0 flex-1">
            <ChatPanel
              messages={chatMessages}
              meetings={meetings}
              notes={notes}
              todos={todos}
              t5tReports={t5tReports}
              onClose={() => setShowChat(false)}
              onOpenAISettings={() => setSelection({ type: "settings", tab: "ai" })}
              onNavigate={(nextSelection) => {
                setSelection(nextSelection);
                setShowChat(false);
              }}
            />
          </div>
        </div>
      </div>

      {sidebarCollapsed && (
        <button
          onClick={() => setSidebarCollapsed(false)}
          className="fixed left-3 top-3 z-30 flex h-10 w-10 items-center justify-center rounded-xl border border-border bg-sidebar/95 text-text-secondary shadow-lg shadow-black/25 transition-colors hover:border-accent/45 hover:text-accent"
          title="Show sidebar"
          aria-label="Show sidebar"
        >
          <BrainHeadIcon className="h-5 w-5" />
        </button>
      )}
    </div>
  );
}
