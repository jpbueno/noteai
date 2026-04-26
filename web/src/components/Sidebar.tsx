"use client";

import { useState, useEffect } from "react";
import {
  Search,
  FileText,
  CheckCircle,
  Circle,
  ListChecks,
  Mic,
  Square,
  Settings,
  StickyNote,
  AudioWaveform,
  Plus,
  X,
  Pin,
} from "lucide-react";

import type {
  Meeting,
  Note,
  TaskItem,
  T5TReport,
  SidebarSelection,
} from "@/lib/types";
import { type RecordingState, getAudioInputDevices } from "@/lib/audio";
import { formatDuration, formatDate } from "@/lib/hooks";

interface SidebarProps {
  meetings: Meeting[];
  notes: Note[];
  tasks: TaskItem[];
  t5tReports: T5TReport[];
  selection: SidebarSelection;
  onSelect: (sel: SidebarSelection) => void;
  searchQuery: string;
  onSearchChange: (q: string) => void;
  recordingState: RecordingState;
  recordingDuration: number;
  onStartRecording: (micDeviceId?: string, captureTab?: boolean) => void;
  onStopRecording: () => void;
  onNewNote: () => void;
  onNewTask: () => void;
  onNewT5T: () => void;
  onDeleteMeeting: (id: string) => void;
  onDeleteNote: (id: string) => void;
  onDeleteTask: (id: string) => void;
  onDeleteT5T: (id: string) => void;
  onTogglePin: (type: "meeting" | "note" | "task" | "t5t", id: string) => void;
}

export default function Sidebar({
  meetings,
  notes,
  tasks,
  t5tReports,
  selection,
  onSelect,
  searchQuery,
  onSearchChange,
  recordingState,
  recordingDuration,
  onStartRecording,
  onStopRecording,
  onNewNote,
  onNewTask,
  onNewT5T,
  onDeleteMeeting,
  onDeleteNote,
  onDeleteTask,
  onDeleteT5T,
  onTogglePin,
}: SidebarProps) {
  const [selectedMic, setSelectedMic] = useState<string>("");

  useEffect(() => {
    getAudioInputDevices().then((devices) => {
      if (devices.length > 0) {
        setSelectedMic(devices[0].deviceId);
      }
    });
  }, []);

  const isSelected = (type: string, id: string) =>
    selection?.type === type && "id" in selection && selection.id === id;

  return (
    <div className="flex flex-col h-full bg-sidebar select-none pt-[52px]">
      {/* Recording control */}
      <div className="px-2 pb-1.5">
        {recordingState === "recording" ? (
          <div
            onClick={() => onSelect({ type: "liveTranscript" })}
            className="cursor-pointer"
            role="button"
            tabIndex={0}
          >
            <div className="flex items-center gap-2 px-3.5 py-2 rounded-md bg-danger/12 hover:bg-danger/18 transition-colors">
              <div className="w-2 h-2 rounded-full bg-danger recording-pulse" />
              <span className="text-sm font-semibold text-text-primary flex-1">
                Recording
              </span>
              <span className="text-xs font-mono font-semibold text-danger">
                {formatDuration(recordingDuration)}
              </span>
              <span
                role="button"
                tabIndex={0}
                onClick={(e) => {
                  e.stopPropagation();
                  onStopRecording();
                }}
                onKeyDown={(e) => { if (e.key === "Enter") { e.stopPropagation(); onStopRecording(); } }}
                className="flex items-center justify-center w-[22px] h-[22px] rounded bg-danger hover:bg-danger/80 transition-colors"
              >
                <Square className="w-[9px] h-[9px] text-white fill-white" />
              </span>
            </div>
          </div>
        ) : (
          <div className="space-y-1.5">
            <button
              onClick={() => onStartRecording(selectedMic || undefined, true)}
              disabled={recordingState === "processing"}
              className="flex items-center gap-2 w-full px-3.5 py-2 rounded-md bg-hover hover:bg-selected transition-colors disabled:opacity-50"
            >
              <Mic className="w-3.5 h-3.5 text-danger" />
              <span className="text-sm font-semibold text-text-primary">
                {recordingState === "processing"
                  ? "Processing..."
                  : "Start Recording"}
              </span>
            </button>
          </div>
        )}
      </div>

      <div className="mx-3.5 border-t border-border" />

      {/* Search */}
      <div className="px-2 pt-2">
        <div className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-hover">
          <Search className="w-3.5 h-3.5 text-text-secondary flex-shrink-0" />
          <input
            type="text"
            placeholder="Search..."
            value={searchQuery}
            onChange={(e) => onSearchChange(e.target.value)}
            className="flex-1 bg-transparent border-none text-sm text-text-primary placeholder:text-text-secondary outline-none p-0"
          />
          {searchQuery && (
            <button onClick={() => onSearchChange("")} className="text-text-tertiary hover:text-text-secondary">
              <X className="w-2.5 h-2.5" />
            </button>
          )}
        </div>
      </div>

      {/* Scrollable lists */}
      <div className="flex-1 overflow-y-auto pt-2 pb-2">
        {/* T5T Reports */}
        <SidebarSection title="T5T Reports" icon={ListChecks} action={{ label: "New", onClick: onNewT5T }}>
          {t5tReports.map((r) => (
            <SidebarItem
              key={r.id}
              icon={<ListChecks className={`w-[13px] h-[13px] ${r.status === "draft" ? "text-orange-400" : "text-text-tertiary"}`} />}
              label={`${formatDate(r.createdDate)} T5T — ${r.title}`}
              selected={isSelected("t5t", r.id)}
              onClick={() => onSelect({ type: "t5t", id: r.id })}
              onDelete={() => onDeleteT5T(r.id)}
              pinned={!!r.pinned}
              onTogglePin={() => onTogglePin("t5t", r.id)}
            />
          ))}
          {t5tReports.length === 0 && <EmptyHint text="No T5T reports yet" />}
        </SidebarSection>

        {/* Notes */}
        <SidebarSection title="Notes" icon={StickyNote} action={{ label: "New", onClick: onNewNote }}>
          {notes.map((n) => (
            <SidebarItem
              key={n.id}
              icon={<StickyNote className="w-[13px] h-[13px] text-text-tertiary" />}
              label={`${formatDate(n.createdDate)} ${n.title}`}
              selected={isSelected("note", n.id)}
              onClick={() => onSelect({ type: "note", id: n.id })}
              onDelete={() => onDeleteNote(n.id)}
              pinned={!!n.pinned}
              onTogglePin={() => onTogglePin("note", n.id)}
            />
          ))}
          {notes.length === 0 && !searchQuery && <EmptyHint text="No notes yet" />}
        </SidebarSection>

        {/* Tasks */}
        <SidebarSection title="Tasks" icon={CheckCircle} action={{ label: "New", onClick: onNewTask }}>
          {tasks.map((t) => (
            <SidebarItem
              key={t.id}
              icon={
                t.status === "completed" ? (
                  <CheckCircle className="w-[13px] h-[13px] text-green-500" />
                ) : (
                  <Circle className="w-[13px] h-[13px] text-text-tertiary" />
                )
              }
              label={t.title ? `${formatDate(t.createdDate)} ${t.title}` : "New Task"}
              selected={isSelected("task", t.id)}
              onClick={() => onSelect({ type: "task", id: t.id })}
              onDelete={() => onDeleteTask(t.id)}
              strikethrough={t.status === "completed"}
              pinned={!!t.pinned}
              onTogglePin={() => onTogglePin("task", t.id)}
            />
          ))}
          {tasks.length === 0 && !searchQuery && <EmptyHint text="No tasks yet" />}
        </SidebarSection>

        {/* Meetings */}
        <SidebarSection title="Meetings" icon={AudioWaveform}>
          {meetings.map((m) => (
            <SidebarItem
              key={m.id}
              icon={<FileText className="w-[13px] h-[13px] text-text-tertiary" />}
              label={`${formatDate(m.date)} ${m.title}`}
              selected={isSelected("meeting", m.id)}
              onClick={() => onSelect({ type: "meeting", id: m.id })}
              onDelete={() => onDeleteMeeting(m.id)}
              pinned={!!m.pinned}
              onTogglePin={() => onTogglePin("meeting", m.id)}
            />
          ))}
          {meetings.length === 0 && (
            <EmptyHint text={searchQuery ? "No results" : "No meetings yet"} />
          )}
        </SidebarSection>
      </div>

      {/* Bottom actions */}
      <div className="border-t border-border">
        <button
          onClick={() => onSelect({ type: "settings" })}
          className="flex items-center gap-2 w-full px-3.5 py-1.5 hover:bg-hover transition-colors"
        >
          <Settings className="w-4 h-4 text-text-secondary" />
          <span className="text-sm font-medium text-text-primary">Settings</span>
        </button>
      </div>
    </div>
  );
}

function SidebarSection({
  title,
  icon: Icon,
  action,
  children,
}: {
  title: string;
  icon: React.ComponentType<{ className?: string }>;
  action?: { label: string; onClick: () => void };
  children: React.ReactNode;
}) {
  return (
    <div>
      <div className="flex items-center px-3.5 pt-3 pb-1">
        <div className="flex items-center gap-1.5 flex-1">
          <Icon className="w-3.5 h-3.5 text-text-secondary" />
          <span className="text-xs font-semibold text-text-secondary uppercase tracking-wide">
            {title}
          </span>
        </div>
        {action && (
          <button
            onClick={action.onClick}
            className="flex items-center gap-0.5 text-text-secondary hover:text-text-primary px-1.5 py-0.5 rounded bg-hover text-[11px] font-semibold transition-colors"
          >
            <Plus className="w-3 h-3" />
            {action.label}
          </button>
        )}
      </div>
      {children}
    </div>
  );
}

function SidebarItem({
  icon,
  label,
  selected,
  onClick,
  onDelete,
  strikethrough,
  pinned,
  onTogglePin,
}: {
  icon: React.ReactNode;
  label: string;
  selected: boolean;
  onClick: () => void;
  onDelete: () => void;
  strikethrough?: boolean;
  pinned?: boolean;
  onTogglePin?: () => void;
}) {
  return (
    <div className="group px-1 relative">
      <button
        onClick={onClick}
        className={`flex items-center gap-2 w-full px-3.5 py-1.5 rounded text-left transition-colors ${
          selected ? "bg-selected" : "hover:bg-hover"
        }`}
      >
        {icon}
        <span
          className={`text-sm font-medium truncate flex-1 ${
            strikethrough
              ? "text-text-tertiary line-through"
              : "text-text-primary"
          }`}
        >
          {label}
        </span>
        {pinned && <Pin className="w-3 h-3 text-accent flex-shrink-0 rotate-45" />}
      </button>
      <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
        {onTogglePin && (
          <button
            onClick={(e) => { e.stopPropagation(); onTogglePin(); }}
            className={`${pinned ? "text-accent" : "text-text-tertiary hover:text-accent"}`}
            title={pinned ? "Unpin" : "Pin"}
          >
            <Pin className="w-3 h-3 rotate-45" />
          </button>
        )}
        <button
          onClick={(e) => {
            e.stopPropagation();
            if (confirm("Delete this item?")) onDelete();
          }}
          className="text-text-tertiary hover:text-danger"
        >
          <X className="w-3 h-3" />
        </button>
      </div>
    </div>
  );
}

function EmptyHint({ text }: { text: string }) {
  return (
    <p className="text-sm text-text-tertiary px-3.5 py-1">{text}</p>
  );
}
