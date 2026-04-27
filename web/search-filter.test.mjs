import assert from "node:assert/strict";
import test from "node:test";

import { applyLibraryFilters } from "./src/lib/search.ts";

const now = new Date("2026-04-27T12:00:00.000Z");

const meetingSummary = (wasSummarized, decisions = []) => ({
  decisions,
  actionItems: [],
  topics: [],
  openQuestions: [],
  wasSummarized,
});

const meetings = [
  {
    id: "recent-reviewed",
    title: "Recent Reviewed Meeting",
    date: "2026-04-26T15:00:00.000Z",
    duration: 1800,
    transcript: [{ id: 1, text: "Reviewed roadmap", startTime: 0, endTime: 1, speaker: null, confidence: 1 }],
    summary: meetingSummary(true, ["Ship v4"]),
  },
  {
    id: "recent-unreviewed",
    title: "Recent Unreviewed Meeting",
    date: "2026-04-25T15:00:00.000Z",
    duration: 1800,
    transcript: [{ id: 1, text: "Needs summary", startTime: 0, endTime: 1, speaker: null, confidence: 1 }],
    summary: meetingSummary(false),
  },
  {
    id: "old-meeting",
    title: "Old Meeting",
    date: "2026-04-12T15:00:00.000Z",
    duration: 1800,
    transcript: [{ id: 1, text: "Archived topic", startTime: 0, endTime: 1, speaker: null, confidence: 1 }],
    summary: meetingSummary(true, ["Old decision"]),
  },
];

const notes = [
  {
    id: "note-1",
    title: "Roadmap note",
    content: "Follow up on v4",
    tags: ["planning"],
    createdDate: "2026-04-27T10:00:00.000Z",
    modifiedDate: "2026-04-27T10:00:00.000Z",
    sourceMeetingID: null,
  },
];

const todos = [
  {
    id: "open-todo",
    title: "Follow up",
    description: "Send the v4 notes",
    completed: 0,
    dueDate: "2026-04-27",
    createdDate: "2026-04-27T09:00:00.000Z",
    modifiedDate: "2026-04-27T09:00:00.000Z",
  },
  {
    id: "done-todo",
    title: "Closed item",
    description: "Already handled",
    completed: 1,
    dueDate: null,
    createdDate: "2026-04-27T08:00:00.000Z",
    modifiedDate: "2026-04-27T08:00:00.000Z",
  },
];

test("recent quick filter keeps only meetings from the last seven days", () => {
  const result = applyLibraryFilters({ meetings, notes, todos }, { query: "", quickFilter: "recent", now });

  assert.deepEqual(result.meetings.map((m) => m.id), ["recent-reviewed", "recent-unreviewed"]);
  assert.deepEqual(result.notes, []);
  assert.deepEqual(result.todos, []);
});

test("open todos quick filter keeps incomplete todos only", () => {
  const result = applyLibraryFilters({ meetings, notes, todos }, { query: "", quickFilter: "openTodos", now });

  assert.deepEqual(result.meetings, []);
  assert.deepEqual(result.notes, []);
  assert.deepEqual(result.todos.map((todo) => todo.id), ["open-todo"]);
});

test("unreviewed quick filter keeps meetings without useful summaries", () => {
  const result = applyLibraryFilters({ meetings, notes, todos }, { query: "", quickFilter: "unreviewed", now });

  assert.deepEqual(result.meetings.map((m) => m.id), ["recent-unreviewed"]);
  assert.deepEqual(result.notes, []);
  assert.deepEqual(result.todos, []);
});

test("text query combines with quick filters", () => {
  const result = applyLibraryFilters({ meetings, notes, todos }, { query: "reviewed", quickFilter: "recent", now });

  assert.deepEqual(result.meetings.map((m) => m.id), ["recent-reviewed", "recent-unreviewed"]);
  assert.deepEqual(result.notes, []);
  assert.deepEqual(result.todos, []);
});
