import assert from "node:assert/strict";
import test from "node:test";

import { buildChatSourceContext, sourceSelectionFromUrl } from "./src/lib/chat-sources.ts";

test("buildChatSourceContext labels workspace sources with noteai links", () => {
  const context = buildChatSourceContext({
    meetings: [
      {
        id: "meeting-1",
        title: "Roadmap Sync",
        date: "2026-04-26T15:00:00.000Z",
        duration: 1800,
        transcript: [{ id: 1, text: "Grace Blackwell rollout is blocked on QA.", startTime: 0, endTime: 1, speaker: null, confidence: 1 }],
        summary: {
          decisions: ["Ship the rollout preview"],
          actionItems: [],
          topics: ["Grace Blackwell"],
          openQuestions: [],
          wasSummarized: true,
        },
      },
    ],
    notes: [
      {
        id: "note-1",
        title: "Customer Brief",
        content: "Crusoe wants benchmarks before the readout.",
        tags: ["customer"],
        createdDate: "2026-04-27T10:00:00.000Z",
        modifiedDate: "2026-04-27T10:00:00.000Z",
        sourceMeetingID: null,
      },
    ],
    todos: [
      {
        id: "todo-1",
        title: "Send benchmark deck",
        description: "Include the updated latency chart.",
        completed: 0,
        dueDate: "2026-04-29",
        createdDate: "2026-04-27T09:00:00.000Z",
        modifiedDate: "2026-04-27T09:00:00.000Z",
      },
    ],
    t5tReports: [
      {
        id: "report-1",
        title: "Top 5 Things",
        createdDate: "2026-04-27T08:00:00.000Z",
        periodStart: "2026-04-20T00:00:00.000Z",
        periodEnd: "2026-04-27T00:00:00.000Z",
        meetingIDs: [],
        noteIDs: [],
        taskIDs: [],
        todoIDs: [],
        dailyLogIDs: [],
        sections: [{ id: "s1", name: "Account Updates", content: "Enabled Crusoe benchmarking." }],
        status: "draft",
      },
    ],
  });

  assert.match(context, /\[M1\] Meeting: Roadmap Sync \(noteai:\/\/meeting\/meeting-1\)/);
  assert.match(context, /\[N1\] Note: Customer Brief \(noteai:\/\/note\/note-1\)/);
  assert.match(context, /\[T1\] Task: Send benchmark deck \(noteai:\/\/task\/todo-1\)/);
  assert.match(context, /\[R1\] T5T: Top 5 Things \(noteai:\/\/t5t\/report-1\)/);
  assert.match(context, /cite it with a markdown link/);
  assert.match(context, /do not have enough NoteAI source material/i);
});

test("sourceSelectionFromUrl maps shared noteai links to web selections", () => {
  assert.deepEqual(sourceSelectionFromUrl("noteai://meeting/meeting-1"), { type: "meeting", id: "meeting-1" });
  assert.deepEqual(sourceSelectionFromUrl("noteai://note/note-1"), { type: "note", id: "note-1" });
  assert.deepEqual(sourceSelectionFromUrl("noteai://task/todo-1"), { type: "todo", id: "todo-1" });
  assert.deepEqual(sourceSelectionFromUrl("noteai://t5t/report-1"), { type: "t5t", id: "report-1" });
  assert.equal(sourceSelectionFromUrl("https://example.com"), null);
});
