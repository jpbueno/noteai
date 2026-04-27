import type { Meeting, Note, TodoItem } from "./types";

export type LibraryQuickFilter = "all" | "recent" | "openTodos" | "unreviewed";

export interface LibraryFilterInput {
  meetings: Meeting[];
  notes: Note[];
  todos: TodoItem[];
}

export interface LibraryFilterOptions {
  query: string;
  quickFilter: LibraryQuickFilter;
  now?: Date;
}

const RECENT_DAYS = 7;

export function applyLibraryFilters(
  input: LibraryFilterInput,
  options: LibraryFilterOptions
): LibraryFilterInput {
  const q = options.query.toLowerCase().trim();
  const now = options.now ?? new Date();

  const searchedMeetings = q
    ? input.meetings.filter(
        (m) =>
          m.title.toLowerCase().includes(q) ||
          m.transcript.some((s) => s.text.toLowerCase().includes(q))
      )
    : input.meetings;

  const searchedNotes = q
    ? input.notes.filter(
        (n) =>
          n.title.toLowerCase().includes(q) ||
          n.content.toLowerCase().includes(q) ||
          n.tags.some((t) => t.toLowerCase().includes(q))
      )
    : input.notes;

  const searchedTodos = q
    ? input.todos.filter(
        (t) =>
          t.title.toLowerCase().includes(q) ||
          t.description.toLowerCase().includes(q)
      )
    : input.todos;

  switch (options.quickFilter) {
    case "recent": {
      const cutoff = new Date(now);
      cutoff.setDate(cutoff.getDate() - RECENT_DAYS);
      return {
        meetings: searchedMeetings.filter((m) => new Date(m.date) >= cutoff),
        notes: [],
        todos: [],
      };
    }
    case "openTodos":
      return {
        meetings: [],
        notes: [],
        todos: searchedTodos.filter((todo) => !todo.completed),
      };
    case "unreviewed":
      return {
        meetings: searchedMeetings.filter((meeting) => {
          const summary = meeting.summary;
          return (
            !summary.wasSummarized ||
            (
              summary.decisions.length === 0 &&
              summary.actionItems.length === 0 &&
              summary.topics.length === 0 &&
              summary.openQuestions.length === 0
            )
          );
        }),
        notes: [],
        todos: [],
      };
    case "all":
    default:
      return {
        meetings: searchedMeetings,
        notes: searchedNotes,
        todos: searchedTodos,
      };
  }
}
