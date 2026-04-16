"use client";

import {
  FileText,
  StickyNote,
  ListChecks,
  BookOpen,
  AudioWaveform,
  Calendar,
  Clock,
  Tag,
  Plus,
} from "lucide-react";
import type {
  Meeting,
  Note,
  T5TReport,
  DailyLog,
  SidebarSelection,
} from "@/lib/types";
import { formatDate, formatDuration } from "@/lib/hooks";

// ── Notes ──────────────────────────────────────────────

export function NoteListView({
  notes,
  onSelect,
  onNew,
}: {
  notes: Note[];
  onSelect: (sel: SidebarSelection) => void;
  onNew: () => void;
}) {
  const sorted = [...notes].sort(
    (a, b) => new Date(b.modifiedDate).getTime() - new Date(a.modifiedDate).getTime()
  );

  return (
    <ListShell
      title="Notes"
      count={sorted.length}
      icon={<StickyNote className="w-5 h-5 text-text-tertiary" />}
      onNew={onNew}
      newLabel="New Note"
      emptyIcon={<StickyNote className="w-9 h-9 text-text-tertiary" />}
      emptyText="No notes yet"
      emptyHint="Create your first note to get started"
    >
      {sorted.map((n) => {
        const snippet = n.content
          .replace(/[#*_`>\-\[\]()!]/g, "")
          .slice(0, 120)
          .trim();
        return (
          <button
            key={n.id}
            onClick={() => onSelect({ type: "note", id: n.id })}
            className="flex flex-col gap-1 w-full px-4 py-3 rounded-lg hover:bg-hover transition-colors text-left"
          >
            <div className="flex items-center gap-2">
              <StickyNote className="w-3.5 h-3.5 text-text-tertiary flex-shrink-0" />
              <span className="text-sm font-medium text-text-primary truncate flex-1">
                {n.title || "Untitled"}
              </span>
              <span className="text-xs text-text-tertiary flex-shrink-0">
                {formatDate(n.modifiedDate)}
              </span>
            </div>
            {snippet && (
              <p className="text-xs text-text-tertiary truncate pl-5.5">{snippet}</p>
            )}
            {n.tags.length > 0 && (
              <div className="flex items-center gap-1.5 pl-5.5">
                <Tag className="w-3 h-3 text-text-tertiary" />
                {n.tags.slice(0, 4).map((t) => (
                  <span
                    key={t}
                    className="text-[11px] px-1.5 py-0.5 rounded bg-hover text-text-secondary"
                  >
                    {t}
                  </span>
                ))}
                {n.tags.length > 4 && (
                  <span className="text-[11px] text-text-tertiary">+{n.tags.length - 4}</span>
                )}
              </div>
            )}
          </button>
        );
      })}
    </ListShell>
  );
}

// ── Meetings ───────────────────────────────────────────

export function MeetingListView({
  meetings,
  onSelect,
}: {
  meetings: Meeting[];
  onSelect: (sel: SidebarSelection) => void;
}) {
  const sorted = [...meetings].sort(
    (a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()
  );

  return (
    <ListShell
      title="Meetings"
      count={sorted.length}
      icon={<AudioWaveform className="w-5 h-5 text-text-tertiary" />}
      emptyIcon={<AudioWaveform className="w-9 h-9 text-text-tertiary" />}
      emptyText="No meetings yet"
      emptyHint="Start a recording to capture a meeting"
    >
      {sorted.map((m) => {
        const topicCount = m.summary?.topics?.length || 0;
        const actionCount = m.summary?.actionItems?.length || 0;
        return (
          <button
            key={m.id}
            onClick={() => onSelect({ type: "meeting", id: m.id })}
            className="flex flex-col gap-1 w-full px-4 py-3 rounded-lg hover:bg-hover transition-colors text-left"
          >
            <div className="flex items-center gap-2">
              <FileText className="w-3.5 h-3.5 text-text-tertiary flex-shrink-0" />
              <span className="text-sm font-medium text-text-primary truncate flex-1">
                {m.title}
              </span>
              <span className="text-xs text-text-tertiary flex-shrink-0">
                {formatDate(m.date)}
              </span>
            </div>
            <div className="flex items-center gap-3 pl-5.5 text-xs text-text-tertiary">
              <span className="flex items-center gap-1">
                <Clock className="w-3 h-3" />
                {formatDuration(m.duration)}
              </span>
              {topicCount > 0 && <span>{topicCount} topics</span>}
              {actionCount > 0 && <span>{actionCount} action items</span>}
              {m.summary?.wasSummarized && (
                <span className="px-1.5 py-0.5 rounded bg-green-500/15 text-green-400 text-[11px]">
                  Summarized
                </span>
              )}
            </div>
          </button>
        );
      })}
    </ListShell>
  );
}

// ── Daily Logs ─────────────────────────────────────────

export function DailyLogListView({
  dailyLogs,
  onSelect,
  onNew,
}: {
  dailyLogs: DailyLog[];
  onSelect: (sel: SidebarSelection) => void;
  onNew: () => void;
}) {
  const sorted = [...dailyLogs].sort(
    (a, b) => b.date.localeCompare(a.date)
  );

  return (
    <ListShell
      title="Daily Logs"
      count={sorted.length}
      icon={<BookOpen className="w-5 h-5 text-text-tertiary" />}
      onNew={onNew}
      newLabel="+ Today"
      emptyIcon={<BookOpen className="w-9 h-9 text-text-tertiary" />}
      emptyText="No daily logs yet"
      emptyHint="Start today's log to track your work"
    >
      {sorted.map((d) => {
        const filledSections = d.sections.filter((s) => s.content.trim());
        const day = new Date(d.date + "T12:00:00");
        const dayName = day.toLocaleDateString("en-US", { weekday: "short" });
        return (
          <button
            key={d.id}
            onClick={() => onSelect({ type: "dailyLog", id: d.id })}
            className="flex flex-col gap-1 w-full px-4 py-3 rounded-lg hover:bg-hover transition-colors text-left"
          >
            <div className="flex items-center gap-2">
              <BookOpen className="w-3.5 h-3.5 text-text-tertiary flex-shrink-0" />
              <span className="text-sm font-medium text-text-primary truncate flex-1">
                {d.date}
                <span className="text-text-tertiary font-normal ml-1.5">{dayName}</span>
              </span>
            </div>
            <div className="flex items-center gap-2 pl-5.5 text-xs text-text-tertiary">
              <span>{filledSections.length} sections filled</span>
              {d.linkedMeetingIDs.length > 0 && (
                <span>{d.linkedMeetingIDs.length} linked meetings</span>
              )}
              {filledSections.length > 0 && (
                <span className="truncate max-w-[200px]">
                  {filledSections.map((s) => s.name).join(", ")}
                </span>
              )}
            </div>
          </button>
        );
      })}
    </ListShell>
  );
}

// ── T5T Reports ────────────────────────────────────────

export function T5TListView({
  reports,
  onSelect,
  onNew,
}: {
  reports: T5TReport[];
  onSelect: (sel: SidebarSelection) => void;
  onNew: () => void;
}) {
  const sorted = [...reports].sort(
    (a, b) => new Date(b.createdDate).getTime() - new Date(a.createdDate).getTime()
  );

  return (
    <ListShell
      title="T5T Reports"
      count={sorted.length}
      icon={<ListChecks className="w-5 h-5 text-text-tertiary" />}
      onNew={onNew}
      newLabel="New Report"
      emptyIcon={<ListChecks className="w-9 h-9 text-text-tertiary" />}
      emptyText="No T5T reports yet"
      emptyHint="Create your first weekly report"
    >
      {sorted.map((r) => {
        const start = new Date(r.periodStart).toLocaleDateString("en-US", { month: "short", day: "numeric" });
        const end = new Date(r.periodEnd).toLocaleDateString("en-US", { month: "short", day: "numeric" });
        const filledSections = r.sections.filter((s) => s.content.trim());
        return (
          <button
            key={r.id}
            onClick={() => onSelect({ type: "t5t", id: r.id })}
            className="flex flex-col gap-1 w-full px-4 py-3 rounded-lg hover:bg-hover transition-colors text-left"
          >
            <div className="flex items-center gap-2">
              <ListChecks className={`w-3.5 h-3.5 flex-shrink-0 ${r.status === "draft" ? "text-orange-400" : "text-green-400"}`} />
              <span className="text-sm font-medium text-text-primary truncate flex-1">
                {r.title}
              </span>
              <span
                className={`text-[11px] px-1.5 py-0.5 rounded font-medium ${
                  r.status === "draft"
                    ? "bg-orange-500/15 text-orange-400"
                    : "bg-green-500/15 text-green-400"
                }`}
              >
                {r.status === "draft" ? "Draft" : "Finalized"}
              </span>
            </div>
            <div className="flex items-center gap-3 pl-5.5 text-xs text-text-tertiary">
              <span className="flex items-center gap-1">
                <Calendar className="w-3 h-3" />
                {start} — {end}
              </span>
              {filledSections.length > 0 && (
                <span>{filledSections.length}/{r.sections.length} sections</span>
              )}
            </div>
          </button>
        );
      })}
    </ListShell>
  );
}

// ── Shared shell ───────────────────────────────────────

function ListShell({
  title,
  count,
  icon,
  onNew,
  newLabel,
  emptyIcon,
  emptyText,
  emptyHint,
  children,
}: {
  title: string;
  count: number;
  icon: React.ReactNode;
  onNew?: () => void;
  newLabel?: string;
  emptyIcon: React.ReactNode;
  emptyText: string;
  emptyHint: string;
  children: React.ReactNode;
}) {
  const hasChildren = Array.isArray(children) ? children.length > 0 : !!children;

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-2xl mx-auto px-12 py-10">
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-3">
            {icon}
            <div>
              <h1 className="text-2xl font-bold text-text-primary">{title}</h1>
              <p className="text-sm text-text-tertiary mt-0.5">{count} items</p>
            </div>
          </div>
          {onNew && newLabel && (
            <button
              onClick={onNew}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-accent text-white text-sm font-medium hover:bg-accent/80 transition-colors"
            >
              <Plus className="w-3.5 h-3.5" />
              {newLabel}
            </button>
          )}
        </div>

        {hasChildren ? (
          <div className="space-y-px">{children}</div>
        ) : (
          <div className="flex flex-col items-center justify-center py-20 gap-3">
            {emptyIcon}
            <p className="text-base font-medium text-text-secondary">{emptyText}</p>
            <p className="text-xs text-text-tertiary">{emptyHint}</p>
          </div>
        )}
      </div>
    </div>
  );
}
