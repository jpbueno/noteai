"use client";

import { useState, useEffect } from "react";
import {
  Search,
  FileText,
  CheckSquare,
  ListChecks,
  Mic,
  Square,
  Settings,
  StickyNote,
  AudioWaveform,
  Plus,
  X,
  ChevronDown,
} from "lucide-react";

import type {
  Meeting,
  Note,
  TodoItem,
  T5TReport,
  SidebarSelection,
} from "@/lib/types";
import { type RecordingState, getAudioInputDevices } from "@/lib/audio";
import { formatDuration, formatDate, parseDueDate } from "@/lib/hooks";

interface SidebarProps {
  meetings: Meeting[];
  notes: Note[];
  todos: TodoItem[];
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
  onNewTodo: () => void;
  onNewT5T: () => void;
  onDeleteMeeting: (id: string) => void;
  onDeleteNote: (id: string) => void;
  onDeleteTodo: (id: string) => void;
  onDeleteT5T: (id: string) => void;
}

export default function Sidebar({
  meetings,
  notes,
  todos,
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
  onNewTodo,
  onNewT5T,
  onDeleteMeeting,
  onDeleteNote,
  onDeleteTodo,
  onDeleteT5T,
}: SidebarProps) {
  const [mics, setMics] = useState<{ deviceId: string; label: string }[]>([]);
  const [selectedMic, setSelectedMic] = useState<string>("");
  const [captureTab, setCaptureTab] = useState(true);

  useEffect(() => {
    getAudioInputDevices().then((devices) => {
      setMics(devices);
      if (devices.length > 0 && !selectedMic) {
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
              onClick={() => onStartRecording(undefined, true)}
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
        <SidebarSection title="T5T Reports" icon={ListChecks} action={{ label: "New", onClick: onNewT5T }} onTitleClick={() => onSelect({ type: "t5tList" })}>
          {t5tReports.map((r) => (
            <SidebarItem
              key={r.id}
              icon={<ListChecks className={`w-[13px] h-[13px] ${r.status === "draft" ? "text-orange-400" : "text-text-tertiary"}`} />}
              label={`${formatDate(r.createdDate)} T5T — ${r.title}`}
              selected={isSelected("t5t", r.id)}
              onClick={() => onSelect({ type: "t5t", id: r.id })}
              onDelete={() => onDeleteT5T(r.id)}
            />
          ))}
          {t5tReports.length === 0 && <EmptyHint text="No T5T reports yet" />}
        </SidebarSection>

        {/* Notes */}
        <SidebarSection title="Notes" icon={StickyNote} action={{ label: "New", onClick: onNewNote }} onTitleClick={() => onSelect({ type: "noteList" })}>
          {notes.map((n) => (
            <SidebarItem
              key={n.id}
              icon={<StickyNote className="w-[13px] h-[13px] text-text-tertiary" />}
              label={`${formatDate(n.createdDate)} ${n.title}`}
              selected={isSelected("note", n.id)}
              onClick={() => onSelect({ type: "note", id: n.id })}
              onDelete={() => onDeleteNote(n.id)}
            />
          ))}
          {notes.length === 0 && !searchQuery && <EmptyHint text="No notes yet" />}
        </SidebarSection>

        {/* Todos */}
        <SidebarSection title="Todos" icon={CheckSquare} action={{ label: "New", onClick: onNewTodo }} onTitleClick={() => onSelect(null)}>
          {todos.map((t) => {
            const todayMidnight = new Date();
            todayMidnight.setHours(0, 0, 0, 0);
            const overdue = !t.completed && t.dueDate && parseDueDate(t.dueDate) < todayMidnight;
            return (
              <SidebarItem
                key={t.id}
                icon={
                  t.completed ? (
                    <CheckSquare className="w-[13px] h-[13px] text-green-500" />
                  ) : overdue ? (
                    <Square className="w-[13px] h-[13px] text-red-400" />
                  ) : (
                    <Square className="w-[13px] h-[13px] text-text-tertiary" />
                  )
                }
                label={t.title ? `${formatDate(t.createdDate)} ${t.title}` : "New Todo"}
                selected={isSelected("todo", t.id)}
                onClick={() => onSelect({ type: "todo", id: t.id })}
                onDelete={() => onDeleteTodo(t.id)}
                strikethrough={!!t.completed}
              />
            );
          })}
          {todos.length === 0 && !searchQuery && <EmptyHint text="No todos yet" />}
        </SidebarSection>

        {/* Meetings */}
        <SidebarSection title="Meetings" icon={AudioWaveform} onTitleClick={() => onSelect({ type: "meetingList" })}>
          {meetings.map((m) => (
            <SidebarItem
              key={m.id}
              icon={<FileText className="w-[13px] h-[13px] text-text-tertiary" />}
              label={`${formatDate(m.date)} ${m.title}`}
              selected={isSelected("meeting", m.id)}
              onClick={() => onSelect({ type: "meeting", id: m.id })}
              onDelete={() => onDeleteMeeting(m.id)}
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
  onTitleClick,
  children,
}: {
  title: string;
  icon: React.ComponentType<{ className?: string }>;
  action?: { label: string; onClick: () => void };
  onTitleClick?: () => void;
  children: React.ReactNode;
}) {
  return (
    <div>
      <div className="flex items-center px-3.5 pt-3 pb-1">
        <div
          className={`flex items-center gap-1.5 flex-1 ${onTitleClick ? "cursor-pointer hover:opacity-80 transition-opacity" : ""}`}
          onClick={onTitleClick}
        >
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
}: {
  icon: React.ReactNode;
  label: string;
  selected: boolean;
  onClick: () => void;
  onDelete: () => void;
  strikethrough?: boolean;
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
      </button>
      <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
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
