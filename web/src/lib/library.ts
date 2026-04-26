import type { Meeting, Note, SidebarSelection, T5TReport, TaskItem } from "./types";

export type LibraryEntityType = "meeting" | "note" | "task" | "t5t";

export type LibrarySnapshot = {
  meetings: Meeting[];
  notes: Note[];
  tasks: TaskItem[];
  t5tReports: T5TReport[];
};

export function createNoteDraft(now = new Date(), id: string): Note {
  return {
    id,
    title: "Untitled",
    content: "",
    tags: [],
    createdDate: now.toISOString(),
    modifiedDate: now.toISOString(),
    sourceMeetingID: null,
  };
}

export function createTaskDraft(now = new Date(), id: string): TaskItem {
  return {
    id,
    title: "",
    description: "",
    rawInput: "",
    tags: [],
    status: "pending",
    createdDate: now.toISOString(),
    modifiedDate: now.toISOString(),
    sourceMeetingID: null,
    sourceNoteID: null,
  };
}

export function t5tDefaultTitle() {
  return "Top 5 Things - Inference Ops | NALA | SA";
}

export function createT5TReportDraft(
  meetings: Meeting[],
  now = new Date(),
  id: string
): T5TReport {
  const periodEnd = new Date(now);
  const periodStart = new Date(now);
  periodStart.setDate(periodStart.getDate() - 14);

  const meetingIDs = meetings
    .filter((meeting) => {
      const meetingDate = new Date(meeting.date);
      return meetingDate >= periodStart && meetingDate <= periodEnd;
    })
    .map((meeting) => meeting.id);

  return {
    id,
    title: t5tDefaultTitle(),
    createdDate: now.toISOString(),
    periodStart: periodStart.toISOString(),
    periodEnd: periodEnd.toISOString(),
    meetingIDs,
    noteIDs: [],
    taskIDs: [],
    sections: { insights: [], accountUpdates: [], futurePlans: [] },
    status: "draft",
  };
}

export function clearSelectionAfterDelete(
  selection: SidebarSelection,
  deleted: { type: LibraryEntityType; id: string }
): SidebarSelection {
  if (!selection || selection.type === "settings" || selection.type === "liveTranscript") {
    return selection;
  }
  return selection.type === deleted.type && selection.id === deleted.id ? null : selection;
}

export function filterLibrary(snapshot: LibrarySnapshot, rawQuery: string): LibrarySnapshot {
  const query = rawQuery.toLowerCase().trim();
  if (!query) return snapshot;

  return {
    ...snapshot,
    meetings: snapshot.meetings.filter(
      (meeting) =>
        meeting.title.toLowerCase().includes(query) ||
        meeting.summary.topics.some((topic) => topic.toLowerCase().includes(query)) ||
        meeting.summary.decisions.some((decision) => decision.toLowerCase().includes(query)) ||
        meeting.summary.actionItems.some((item) => item.task.toLowerCase().includes(query)) ||
        meeting.transcript.some((segment) => segment.text.toLowerCase().includes(query))
    ),
    notes: snapshot.notes.filter(
      (note) =>
        note.title.toLowerCase().includes(query) ||
        note.content.toLowerCase().includes(query) ||
        note.tags.some((tag) => tag.toLowerCase().includes(query))
    ),
    tasks: snapshot.tasks.filter(
      (task) =>
        task.title.toLowerCase().includes(query) ||
        task.description.toLowerCase().includes(query) ||
        task.rawInput.toLowerCase().includes(query) ||
        task.tags.some((tag) => tag.toLowerCase().includes(query))
    ),
  };
}

export function selectedSources(
  snapshot: Pick<LibrarySnapshot, "meetings" | "notes" | "tasks">,
  ids: { meetingIDs: Set<string>; noteIDs: Set<string>; taskIDs: Set<string> }
) {
  return {
    meetings: snapshot.meetings.filter((meeting) => ids.meetingIDs.has(meeting.id)),
    notes: snapshot.notes.filter((note) => ids.noteIDs.has(note.id)),
    tasks: snapshot.tasks.filter((task) => ids.taskIDs.has(task.id)),
  };
}

