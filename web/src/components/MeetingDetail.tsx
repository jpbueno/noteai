"use client";

import { useMemo, useRef, useState } from "react";
import {
  Clock,
  Calendar,
  CheckCircle,
  Circle,
  Copy,
  Download,
  Loader2,
  Plus,
  RotateCcw,
  Save,
  Trash2,
  Volume2,
  FileText,
  Sparkles,
  AlignLeft,
} from "lucide-react";
import type { ActionItem, Meeting, SidebarSelection, SummarySectionKey, TodoItem } from "@/lib/types";
import {
  ensureMeetingSummaryMetadata,
  markSummarySectionUserEdited,
  normalizeActionItems,
} from "@/lib/types";
import { formatDuration, formatDateTime, triggerRefresh } from "@/lib/hooks";
import { db } from "@/lib/db";
import { regenerateSummarySection } from "@/lib/ai";
import { generateMeetingMarkdown, meetingMarkdownFilename, printMeetingPdf } from "@/lib/exports";
import { useTTS } from "@/lib/tts";
import { TTSPlayer, ReadAloudButton } from "@/components/TTSPlayer";
import { readSelectedTextForReadAloud } from "@/lib/read-aloud-selection";

type Tab = "summary" | "transcript" | "raw";

interface MeetingDetailProps {
  meeting: Meeting;
  todos?: TodoItem[];
  onNavigate?: (sel: SidebarSelection) => void;
}

export default function MeetingDetail({ meeting, todos = [], onNavigate }: MeetingDetailProps) {
  const summary = useMemo(() => ensureMeetingSummaryMetadata(meeting.summary), [meeting.summary]);
  const hasSummary = summary.wasSummarized && !summaryEmpty(summary);
  const [activeTab, setActiveTab] = useState<Tab>(hasSummary ? "summary" : "transcript");
  const [regeneratingSection, setRegeneratingSection] = useState<SummarySectionKey | null>(null);
  const [summaryError, setSummaryError] = useState("");
  const tts = useTTS();
  const readAloudRootRef = useRef<HTMLDivElement>(null);
  const linkedTodos = useMemo(
    () => todos.filter((todo) => todo.sourceMeetingID === meeting.id),
    [meeting.id, todos],
  );

  const readableText = hasSummary
    ? [
        ...summary.decisions,
        ...summary.actionItems.map((ai) => ai.task),
        ...summary.topics,
        ...summary.openQuestions,
      ].join(". ")
    : meeting.transcript.map((s) => s.text).join(" ");

  const saveSummary = async (nextSummary: Meeting["summary"]) => {
    const updated = { ...meeting, summary: ensureMeetingSummaryMetadata(nextSummary) };
    await db.meetings.put(updated);
    triggerRefresh();
  };

  const handleSaveTextSection = async (section: Exclude<SummarySectionKey, "actionItems">, items: string[]) => {
    await saveSummary(markSummarySectionUserEdited({ ...summary, [section]: items }, section));
  };

  const handleSaveActionItems = async (items: ActionItem[]) => {
    await saveSummary(
      markSummarySectionUserEdited(
        { ...summary, actionItems: normalizeActionItems(items) },
        "actionItems",
      ),
    );
  };

  const handleRegenerateSection = async (section: SummarySectionKey) => {
    setSummaryError("");
    setRegeneratingSection(section);
    try {
      const nextSummary = await regenerateSummarySection({ ...meeting, summary }, section);
      await saveSummary(nextSummary);
    } catch (err) {
      setSummaryError(err instanceof Error ? err.message : "Could not regenerate this summary section.");
    } finally {
      setRegeneratingSection(null);
    }
  };

  const rawText = meeting.transcript.map((s) => s.text).join("\n");

  const copyToClipboard = () => {
    navigator.clipboard.writeText(
      activeTab === "raw" ? rawText : generateMeetingMarkdown(meeting, { formatDateTime })
    );
  };

  const downloadMarkdown = () => {
    const md = generateMeetingMarkdown(meeting, { formatDateTime });
    const blob = new Blob([md], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = meetingMarkdownFilename(meeting);
    a.click();
    URL.revokeObjectURL(url);
  };

  const exportPdf = () => {
    printMeetingPdf(meeting, { formatDateTime });
  };

  const tabs: { id: Tab; label: string; icon: React.ReactNode }[] = [
    ...(hasSummary
      ? [{ id: "summary" as Tab, label: "Summary", icon: <Sparkles className="w-3.5 h-3.5" /> }]
      : []),
    { id: "transcript", label: "Transcript", icon: <FileText className="w-3.5 h-3.5" /> },
    { id: "raw", label: "Raw", icon: <AlignLeft className="w-3.5 h-3.5" /> },
  ];

  return (
    <div ref={readAloudRootRef} className="h-full overflow-y-auto">
      <div className="mx-auto max-w-5xl px-8 py-8">
        {/* Title */}
        <div className="v4-panel mb-6 p-6">
          <p className="text-xs font-bold uppercase tracking-[0.16em] text-text-tertiary">
            Meeting intelligence
          </p>
          <div className="mt-2 flex items-start justify-between gap-6">
            <div>
              <h1 className="text-[38px] font-bold leading-tight tracking-[-0.025em] text-text-primary">
                {meeting.title}
              </h1>
              <div className="mt-4 flex flex-wrap items-center gap-3 text-sm text-text-secondary">
                <span className="flex items-center gap-1.5 rounded-full border border-border bg-content/55 px-3 py-1">
                  <Calendar className="w-3.5 h-3.5" />
                  {formatDateTime(meeting.date)}
                </span>
                <span className="flex items-center gap-1.5 rounded-full border border-border bg-content/55 px-3 py-1">
                  <Clock className="w-3.5 h-3.5" />
                  {formatDuration(meeting.duration)}
                </span>
                <span className="flex items-center gap-1.5 rounded-full border border-border bg-content/55 px-3 py-1">
                  <Volume2 className="w-3.5 h-3.5" />
                  {meeting.transcript.length} segments
                </span>
              </div>
            </div>
            {hasSummary && (
              <span className="rounded-full bg-green-400/12 px-3 py-1 text-xs font-bold text-green-400">
                Summarized
              </span>
            )}
          </div>

          {/* Actions bar */}
          <div className="mt-6 flex flex-wrap gap-2">
            <button
              onClick={copyToClipboard}
              className="v4-soft-button flex items-center gap-1.5 rounded-xl px-3 py-2 text-sm font-semibold transition-colors"
            >
              <Copy className="w-3.5 h-3.5" />
              Copy
            </button>
            <button
              onClick={downloadMarkdown}
              className="v4-soft-button flex items-center gap-1.5 rounded-xl px-3 py-2 text-sm font-semibold transition-colors"
            >
              <Download className="w-3.5 h-3.5" />
              Export .md
            </button>
            <button
              onClick={exportPdf}
              className="v4-soft-button flex items-center gap-1.5 rounded-xl px-3 py-2 text-sm font-semibold transition-colors"
            >
              <Download className="w-3.5 h-3.5" />
              Export PDF
            </button>
            <ReadAloudButton
              state={tts.state}
              onSpeak={() => {
                const selectedText = readSelectedTextForReadAloud({
                  root: readAloudRootRef.current,
                });
                tts.speak(selectedText ?? readableText);
              }}
              onStop={tts.stop}
            />
          </div>
        </div>

        <TTSPlayer
          state={tts.state}
          progress={tts.progress}
          error={tts.error}
          voice={tts.voice}
          onTogglePlayPause={tts.togglePlayPause}
          onStop={tts.stop}
          onDismissError={tts.dismissError}
        />

        {/* Tabs */}
        <div className="mb-6 flex gap-2 rounded-xl border border-border bg-sidebar/70 p-1">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-semibold transition-colors ${
                activeTab === tab.id
                  ? "bg-selected text-text-primary"
                  : "text-text-tertiary hover:text-text-secondary"
              }`}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </div>

        {/* Tab content */}
        {activeTab === "summary" && hasSummary && (
          <div className="space-y-4">
            {summaryError && (
              <div className="rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-300">
                {summaryError}
              </div>
            )}
            <div className="grid gap-4 lg:grid-cols-2">
              <SummaryTextSection
                key={summarySectionRenderKey("decisions", summary.decisions, summary.sectionMetadata?.decisions?.modifiedAt)}
                section="decisions"
                title="Key Decisions"
                color="text-blue-400"
                items={summary.decisions}
                metadata={summary.sectionMetadata?.decisions}
                regenerating={regeneratingSection === "decisions"}
                onSave={handleSaveTextSection}
                onRegenerate={handleRegenerateSection}
              />

              <ActionItemsSection
                key={summarySectionRenderKey("actionItems", summary.actionItems, summary.sectionMetadata?.actionItems?.modifiedAt)}
                items={summary.actionItems}
                metadata={summary.sectionMetadata?.actionItems}
                regenerating={regeneratingSection === "actionItems"}
                onSave={handleSaveActionItems}
                onRegenerate={() => handleRegenerateSection("actionItems")}
              />

              <SummaryTextSection
                key={summarySectionRenderKey("topics", summary.topics, summary.sectionMetadata?.topics?.modifiedAt)}
                section="topics"
                title="Topics Discussed"
                color="text-green-400"
                items={summary.topics}
                metadata={summary.sectionMetadata?.topics}
                regenerating={regeneratingSection === "topics"}
                onSave={handleSaveTextSection}
                onRegenerate={handleRegenerateSection}
              />

              <SummaryTextSection
                key={summarySectionRenderKey("openQuestions", summary.openQuestions, summary.sectionMetadata?.openQuestions?.modifiedAt)}
                section="openQuestions"
                title="Open Questions"
                color="text-purple-400"
                items={summary.openQuestions}
                metadata={summary.sectionMetadata?.openQuestions}
                regenerating={regeneratingSection === "openQuestions"}
                onSave={handleSaveTextSection}
                onRegenerate={handleRegenerateSection}
              />

              {linkedTodos.length > 0 && (
                <LinkedTodosBlock todos={linkedTodos} onNavigate={onNavigate} />
              )}
            </div>
          </div>
        )}

        {activeTab === "transcript" && (
          <div className="v4-panel space-y-3 p-5">
            {meeting.transcript.map((seg) => (
              <div key={seg.id} className="flex gap-3">
                <span className="text-xs text-text-tertiary font-mono w-12 pt-0.5 flex-shrink-0 text-right">
                  {seg.startTime > 0 ? formatTimestamp(seg.startTime) : ""}
                </span>
                <div className="flex-1">
                  {seg.speaker && (
                    <span className="text-xs text-accent font-medium mr-2">
                      {seg.speaker}
                    </span>
                  )}
                  <span className="text-[15px] text-text-primary leading-relaxed">
                    {seg.text}
                  </span>
                </div>
              </div>
            ))}
            {meeting.transcript.length === 0 && (
              <p className="text-text-tertiary text-sm py-8 text-center">
                No transcript segments recorded.
              </p>
            )}
          </div>
        )}

        {activeTab === "raw" && (
          <div>
            <div className="flex justify-end mb-2">
              <button
                onClick={() => navigator.clipboard.writeText(rawText)}
                className="flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs text-text-tertiary hover:text-text-secondary hover:bg-hover transition-colors"
              >
                <Copy className="w-3 h-3" />
                Copy raw text
              </button>
            </div>
            <pre className="bg-sidebar border border-border rounded-xl p-4 text-sm text-text-primary font-mono leading-relaxed whitespace-pre-wrap overflow-x-auto select-all">
              {rawText || "[No transcript data]"}
            </pre>
          </div>
        )}

        {!hasSummary && activeTab === "summary" && (
          <div className="text-center py-12">
            <p className="text-text-tertiary text-sm">
              No summary available for this meeting.
            </p>
            <p className="text-text-tertiary text-xs mt-1">
              Configure an API key in Settings to enable summarization.
            </p>
          </div>
        )}

      </div>
    </div>
  );
}

function SummaryBlock({
  title,
  color,
  metadata,
  regenerating = false,
  onRegenerate,
  className = "",
  children,
}: {
  title: string;
  color: string;
  metadata?: { state: "generated" | "userEdited"; modifiedAt: string };
  regenerating?: boolean;
  onRegenerate?: () => void;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={`v4-panel p-5 ${className}`}>
      <div className="mb-3 flex items-center justify-between gap-3">
        <div className="min-w-0">
          <h3 className={`text-sm font-bold uppercase tracking-[0.14em] ${color}`}>{title}</h3>
          {metadata && (
            <p className="mt-1 text-[11px] font-medium uppercase tracking-[0.12em] text-text-tertiary">
              {metadata.state === "userEdited" ? "Edited" : "Generated"}
            </p>
          )}
        </div>
        {onRegenerate && (
          <button
            onClick={onRegenerate}
            disabled={regenerating}
            className="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-md border border-border bg-content/60 text-text-tertiary transition-colors hover:text-text-primary disabled:cursor-wait disabled:opacity-60"
            title={`Regenerate ${title}`}
          >
            {regenerating ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RotateCcw className="h-3.5 w-3.5" />}
          </button>
        )}
      </div>
      {children}
    </div>
  );
}

function SummaryTextSection({
  section,
  title,
  color,
  items,
  metadata,
  regenerating,
  onSave,
  onRegenerate,
}: {
  section: Exclude<SummarySectionKey, "actionItems">;
  title: string;
  color: string;
  items: string[];
  metadata?: { state: "generated" | "userEdited"; modifiedAt: string };
  regenerating: boolean;
  onSave: (section: Exclude<SummarySectionKey, "actionItems">, items: string[]) => Promise<void>;
  onRegenerate: (section: SummarySectionKey) => void;
}) {
  const source = items.join("\n");
  const [draft, setDraft] = useState(source);
  const [saving, setSaving] = useState(false);

  const dirty = draft !== source;

  const handleSave = async () => {
    setSaving(true);
    await onSave(
      section,
      draft
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean),
    );
    setSaving(false);
  };

  return (
    <SummaryBlock
      title={title}
      color={color}
      metadata={metadata}
      regenerating={regenerating}
      onRegenerate={() => onRegenerate(section)}
    >
      <textarea
        value={draft}
        onChange={(event) => setDraft(event.target.value)}
        className="min-h-[132px] w-full resize-y rounded-md border border-border bg-content/70 p-3 text-[14px] leading-relaxed text-text-primary outline-none transition-colors placeholder:text-text-tertiary focus:border-accent"
      />
      <div className="mt-3 flex justify-end">
        <button
          onClick={handleSave}
          disabled={!dirty || saving}
          className="flex items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-sm font-semibold text-white transition-colors hover:bg-accent/80 disabled:cursor-not-allowed disabled:opacity-40"
        >
          {saving ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Save className="h-3.5 w-3.5" />}
          {saving ? "Saving" : "Save"}
        </button>
      </div>
    </SummaryBlock>
  );
}

function ActionItemsSection({
  items,
  metadata,
  regenerating,
  onSave,
  onRegenerate,
}: {
  items: ActionItem[];
  metadata?: { state: "generated" | "userEdited"; modifiedAt: string };
  regenerating: boolean;
  onSave: (items: ActionItem[]) => Promise<void>;
  onRegenerate: () => void;
}) {
  const sourceKey = actionItemsKey(items);
  const [draft, setDraft] = useState(() => actionDraftsFromItems(items));
  const [saving, setSaving] = useState(false);

  const dirty = actionItemsKey(draft) !== sourceKey;

  const updateDraft = (id: string, changes: Partial<ActionDraft>) => {
    setDraft((current) => current.map((item) => (item.id === id ? { ...item, ...changes } : item)));
  };

  const handleSave = async () => {
    setSaving(true);
    await onSave(
      draft
        .filter((item) => item.task.trim())
        .map((item) => ({
          id: item.id,
          task: item.task.trim(),
          owner: item.owner.trim() || null,
          deadline: item.deadline.trim() || null,
          isCompleted: item.isCompleted,
        })),
    );
    setSaving(false);
  };

  return (
    <SummaryBlock
      title="Action Items"
      color="text-orange-400"
      metadata={metadata}
      regenerating={regenerating}
      onRegenerate={onRegenerate}
    >
      <div className="space-y-2">
        {draft.map((item) => (
          <div key={item.id} className="rounded-lg border border-border bg-content/55 p-3">
            <div className="flex items-start gap-2">
              <button
                onClick={() => updateDraft(item.id, { isCompleted: !item.isCompleted })}
                className="mt-2 flex-shrink-0 text-text-tertiary transition-colors hover:text-orange-400"
                title={item.isCompleted ? "Mark pending" : "Mark complete"}
              >
                {item.isCompleted ? <CheckCircle className="h-4 w-4 text-green-500" /> : <Circle className="h-4 w-4" />}
              </button>
              <input
                value={item.task}
                onChange={(event) => updateDraft(item.id, { task: event.target.value })}
                className="min-w-0 flex-1 rounded-md border border-border bg-sidebar/70 px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
              />
              <button
                onClick={() => setDraft((current) => current.filter((draftItem) => draftItem.id !== item.id))}
                className="mt-1.5 flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-md text-text-tertiary transition-colors hover:bg-hover hover:text-red-300"
                title="Remove action item"
              >
                <Trash2 className="h-3.5 w-3.5" />
              </button>
            </div>
            <div className="mt-2 grid gap-2 sm:grid-cols-2">
              <input
                value={item.owner}
                onChange={(event) => updateDraft(item.id, { owner: event.target.value })}
                placeholder="Owner"
                className="rounded-md border border-border bg-sidebar/70 px-2.5 py-1.5 text-xs text-text-primary outline-none placeholder:text-text-tertiary focus:border-accent"
              />
              <input
                value={item.deadline}
                onChange={(event) => updateDraft(item.id, { deadline: event.target.value })}
                placeholder="Deadline"
                className="rounded-md border border-border bg-sidebar/70 px-2.5 py-1.5 text-xs text-text-primary outline-none placeholder:text-text-tertiary focus:border-accent"
              />
            </div>
          </div>
        ))}
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
        <button
          onClick={() =>
            setDraft((current) => [
              ...current,
              { id: crypto.randomUUID(), task: "", owner: "", deadline: "", isCompleted: false },
            ])
          }
          className="flex items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-sm font-semibold text-text-secondary transition-colors hover:text-text-primary"
        >
          <Plus className="h-3.5 w-3.5" />
          Add
        </button>
        <button
          onClick={handleSave}
          disabled={!dirty || saving}
          className="flex items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-sm font-semibold text-white transition-colors hover:bg-accent/80 disabled:cursor-not-allowed disabled:opacity-40"
        >
          {saving ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Save className="h-3.5 w-3.5" />}
          {saving ? "Saving" : "Save"}
        </button>
      </div>
    </SummaryBlock>
  );
}

function LinkedTodosBlock({
  todos,
  onNavigate,
}: {
  todos: TodoItem[];
  onNavigate?: (sel: SidebarSelection) => void;
}) {
  return (
    <SummaryBlock title="Linked Todos" color="text-yellow-300" className="lg:col-span-2">
      <div className="grid gap-2 sm:grid-cols-2">
        {todos.map((todo) => (
          <button
            key={todo.id}
            onClick={() => onNavigate?.({ type: "todo", id: todo.id })}
            className="v4-row flex items-start gap-2 p-3 text-left transition-colors hover:border-accent/50"
          >
            {todo.completed ? (
              <CheckCircle className="mt-0.5 h-4 w-4 flex-shrink-0 text-green-500" />
            ) : (
              <Circle className="mt-0.5 h-4 w-4 flex-shrink-0 text-text-tertiary" />
            )}
            <span className="min-w-0 flex-1">
              <span className={`block text-sm ${todo.completed ? "text-text-tertiary line-through" : "text-text-primary"}`}>
                {todo.title || "Untitled todo"}
              </span>
              {(todo.owner || todo.dueDate) && (
                <span className="mt-1 flex flex-wrap gap-2 text-xs text-text-tertiary">
                  {todo.owner && <span>@{todo.owner}</span>}
                  {todo.dueDate && <span>Due: {todo.dueDate}</span>}
                </span>
              )}
            </span>
          </button>
        ))}
      </div>
    </SummaryBlock>
  );
}

interface ActionDraft {
  id: string;
  task: string;
  owner: string;
  deadline: string;
  isCompleted: boolean;
}

function actionDraftsFromItems(items: ActionItem[]): ActionDraft[] {
  return items.map((item) => ({
    id: item.id,
    task: item.task,
    owner: item.owner ?? "",
    deadline: item.deadline ?? "",
    isCompleted: item.isCompleted,
  }));
}

function actionItemsKey(items: Array<ActionItem | ActionDraft>): string {
  return JSON.stringify(
    items.map((item) => ({
      task: item.task.trim(),
      owner: item.owner?.trim() ?? "",
      deadline: item.deadline?.trim() ?? "",
      isCompleted: item.isCompleted,
    })),
  );
}

function summarySectionRenderKey(section: SummarySectionKey, items: string[] | ActionItem[], modifiedAt?: string): string {
  return `${section}:${modifiedAt ?? ""}:${Array.isArray(items) ? JSON.stringify(items) : ""}`;
}

function summaryEmpty(s: Meeting["summary"]): boolean {
  return s.decisions.length === 0 && s.actionItems.length === 0 && s.topics.length === 0 && s.openQuestions.length === 0;
}

function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}
