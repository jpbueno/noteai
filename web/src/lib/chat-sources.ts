import type { Meeting, Note, SidebarSelection, T5TReport, TodoItem } from "./types";

const MAX_TEXT_CHARS = 360;
const DEFAULT_MAX_PER_TYPE = 6;

type SourceKind = "meeting" | "note" | "task" | "t5t";

interface BuildChatSourceContextInput {
  meetings: Meeting[];
  notes: Note[];
  todos: TodoItem[];
  t5tReports: T5TReport[];
  maxPerType?: number;
}

interface SourceEntry {
  prefix: string;
  kind: SourceKind;
  title: string;
  id: string;
  text: string;
}

export function buildChatSourceContext({
  meetings,
  notes,
  todos,
  t5tReports,
  maxPerType = DEFAULT_MAX_PER_TYPE,
}: BuildChatSourceContextInput): string {
  const entries: SourceEntry[] = [
    ...meetings.slice(0, maxPerType).map((meeting, index) => meetingEntry(meeting, index + 1)),
    ...notes.slice(0, maxPerType).map((note, index) => noteEntry(note, index + 1)),
    ...todos.slice(0, maxPerType).map((todo, index) => todoEntry(todo, index + 1)),
    ...t5tReports.slice(0, maxPerType).map((report, index) => t5tEntry(report, index + 1)),
  ].filter((entry) => entry.title.trim() || entry.text.trim());

  const sourceBlock = entries.length
    ? entries.map(formatEntry).join("\n")
    : "No NoteAI workspace sources are currently available.";

  return `You are NoteAI, an intelligent meeting assistant. Use the NoteAI workspace sources below when answering questions about meetings, notes, tasks, or T5T reports.

Rules:
- If you use a source, cite it with a markdown link using the provided label and noteai:// URL, for example [M1: Roadmap Sync](noteai://meeting/example-id).
- Prefer directly supported answers. If the sources below do not support the answer, say you do not have enough NoteAI source material.
- Keep answers concise and do not invent meetings, owners, dates, or commitments.

NoteAI workspace sources:
${sourceBlock}`;
}

export function sourceSelectionFromUrl(urlString: string): SidebarSelection {
  let url: URL;
  try {
    url = new URL(urlString);
  } catch {
    return null;
  }
  if (url.protocol !== "noteai:") return null;

  const id = decodeURIComponent(url.pathname.replace(/^\//, ""));
  if (!id) return null;

  switch (url.hostname) {
    case "meeting":
      return { type: "meeting", id };
    case "note":
      return { type: "note", id };
    case "task":
    case "todo":
      return { type: "todo", id };
    case "t5t":
      return { type: "t5t", id };
    default:
      return null;
  }
}

function meetingEntry(meeting: Meeting, index: number): SourceEntry {
  const summary = meeting.summary;
  const parts = [
    summary.decisions.length ? `Decisions: ${summary.decisions.join("; ")}` : "",
    summary.actionItems.length ? `Actions: ${summary.actionItems.map((item) => item.task).join("; ")}` : "",
    summary.topics.length ? `Topics: ${summary.topics.join(", ")}` : "",
    summary.openQuestions.length ? `Questions: ${summary.openQuestions.join("; ")}` : "",
    meeting.transcript.length ? `Transcript: ${meeting.transcript.map((segment) => segment.text).join(" ")}` : "",
  ];

  return {
    prefix: `M${index}`,
    kind: "meeting",
    title: meeting.title || "Untitled meeting",
    id: meeting.id,
    text: truncate(parts.filter(Boolean).join(" ")),
  };
}

function noteEntry(note: Note, index: number): SourceEntry {
  return {
    prefix: `N${index}`,
    kind: "note",
    title: note.title || "Untitled note",
    id: note.id,
    text: truncate(note.content),
  };
}

function todoEntry(todo: TodoItem, index: number): SourceEntry {
  const status = todo.completed ? "completed" : "open";
  const due = todo.dueDate ? `Due: ${todo.dueDate}.` : "";
  return {
    prefix: `T${index}`,
    kind: "task",
    title: todo.title || "Untitled task",
    id: todo.id,
    text: truncate([`Status: ${status}.`, due, todo.description].filter(Boolean).join(" ")),
  };
}

function t5tEntry(report: T5TReport, index: number): SourceEntry {
  const sectionText = report.sections
    .map((section) => `${section.name}: ${section.content}`)
    .join(" ");
  return {
    prefix: `R${index}`,
    kind: "t5t",
    title: report.title || "Untitled T5T",
    id: report.id,
    text: truncate(sectionText),
  };
}

function formatEntry(entry: SourceEntry): string {
  const kindLabel: Record<SourceKind, string> = {
    meeting: "Meeting",
    note: "Note",
    task: "Task",
    t5t: "T5T",
  };
  return `- [${entry.prefix}] ${kindLabel[entry.kind]}: ${entry.title} (${sourceUrl(entry.kind, entry.id)}) - ${entry.text || "No excerpt available."}`;
}

function sourceUrl(kind: SourceKind, id: string): string {
  return `noteai://${kind}/${encodeURIComponent(id)}`;
}

function truncate(value: string): string {
  const normalized = value.replace(/\s+/g, " ").trim();
  if (normalized.length <= MAX_TEXT_CHARS) return normalized;
  return `${normalized.slice(0, MAX_TEXT_CHARS - 1).trim()}...`;
}
