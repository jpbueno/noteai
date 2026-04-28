import assert from "node:assert/strict";
import test from "node:test";

import {
  buildImportSql,
  macMeeting,
  macT5TReport,
  macTodo,
  parseDotEnv,
  swiftReferenceSeconds,
  unixSeconds,
} from "./turso-to-macos-sync.mjs";

const meetingId = "11111111-1111-1111-1111-111111111111";
const noteId = "22222222-2222-2222-2222-222222222222";
const todoId = "33333333-3333-3333-3333-333333333333";
const reportId = "44444444-4444-4444-4444-444444444444";

test("parseDotEnv handles literal newline escaped production env files", () => {
  const env = parseDotEnv("TURSO_DATABASE_URL=libsql://example.turso.io\\nTURSO_AUTH_TOKEN='secret'\\n");

  assert.equal(env.TURSO_DATABASE_URL, "libsql://example.turso.io");
  assert.equal(env.TURSO_AUTH_TOKEN, "secret");
});

test("date helpers write mac index dates as Unix seconds and Swift JSON dates as reference seconds", () => {
  const iso = "2026-04-20T12:00:00.000Z";

  assert.equal(unixSeconds(iso), Date.parse(iso) / 1000);
  assert.equal(swiftReferenceSeconds(iso), Date.parse(iso) / 1000 - 978307200);
});

test("macMeeting converts web row shape into Swift Codable meeting JSON shape", () => {
  const meeting = macMeeting({
    id: meetingId,
    title: "Roadmap Sync",
    date: "2026-04-20T12:00:00.000Z",
    duration: 42,
    transcript: [{ text: "Ship it", startTime: 0, endTime: 1, speaker: "JP", confidence: 0.9 }],
    summary: {
      decisions: ["Mirror web data"],
      actionItems: [{ task: "Verify mac app", owner: "JP", deadline: null, isCompleted: true }],
      topics: ["Sync"],
      openQuestions: ["Bidirectional later?"],
      wasSummarized: true,
    },
  });

  assert.equal(meeting.id, meetingId.toUpperCase());
  assert.equal(meeting.date, swiftReferenceSeconds("2026-04-20T12:00:00.000Z"));
  assert.equal(meeting.transcript[0].speaker, "JP");
  assert.equal(meeting.summary.actionItems[0].isCompleted, true);
});

test("macTodo maps Turso integer completion and optional due date into Swift JSON fields", () => {
  const todo = macTodo({
    id: todoId,
    title: "Study ModelOpt",
    description: "",
    completed: 1,
    dueDate: "2026-04-27T00:00:00.000Z",
    createdDate: "2026-04-26T10:00:00.000Z",
    modifiedDate: "2026-04-26T11:00:00.000Z",
  });

  assert.equal(todo.completed, true);
  assert.equal(todo.dueDate, swiftReferenceSeconds("2026-04-27T00:00:00.000Z"));
});

test("macT5TReport adapts web section list to mac grouped T5T sections", () => {
  const report = macT5TReport({
    id: reportId,
    title: "Top 5 Things",
    createdDate: "2026-04-20T12:00:00.000Z",
    periodStart: "2026-04-13T00:00:00.000Z",
    periodEnd: "2026-04-20T00:00:00.000Z",
    meetingIDs: [meetingId],
    noteIDs: [noteId],
    taskIDs: [],
    todoIDs: [todoId],
    sections: [
      { id: "account-updates", name: "Industry Business Development / Account Updates", content: "Account work" },
      { id: "future-plans", name: "Future Plans", content: "Next work" },
    ],
    status: "draft",
  });

  assert.equal(report.meetingIDs[0], meetingId.toUpperCase());
  assert.equal(report.todoIDs[0], todoId.toUpperCase());
  assert.equal(report.sections.accountUpdates[0].headline, "Industry Business Development / Account Updates");
  assert.equal(report.sections.futurePlans[0].explanation, "Next work");
});

test("buildImportSql mirrors supported tables and stores Swift JSON payloads", () => {
  const sql = buildImportSql({
    meetings: [{
      id: meetingId,
      title: "Roadmap Sync",
      date: "2026-04-20T12:00:00.000Z",
      duration: 42,
      transcript: [],
      summary: {},
    }],
    notes: [{
      id: noteId,
      title: "Sync Note",
      content: "O'Hara",
      tags: ["sync"],
      createdDate: "2026-04-20T12:00:00.000Z",
      modifiedDate: "2026-04-20T12:30:00.000Z",
      sourceMeetingID: meetingId,
    }],
    tasks: [],
    todos: [],
    t5tReports: [],
  });

  assert.match(sql, /BEGIN IMMEDIATE;/);
  assert.match(sql, /DELETE FROM meetings;/);
  assert.match(sql, /DELETE FROM todos;/);
  assert.match(sql, /INSERT OR REPLACE INTO meetings/);
  assert.match(sql, new RegExp(`"date":${swiftReferenceSeconds("2026-04-20T12:00:00.000Z")}`));
  assert.match(sql, /O''Hara/);
  assert.match(sql, /COMMIT;/);
});
