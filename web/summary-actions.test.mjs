import assert from "node:assert/strict";
import test from "node:test";

import {
  actionItemIdFromFields,
  buildLinkedTodoSyncPlanForMeetingActions,
  buildLinkedTodosForMeetingActions,
  ensureMeetingSummaryMetadata,
  mergeRegeneratedSummarySection,
  parseMeetingSummaryContent,
} from "./src/lib/types.ts";

const NOW = "2026-05-01T12:00:00.000Z";
const LATER = "2026-05-01T13:00:00.000Z";

test("summary parsing assigns stable action IDs and generated section metadata", () => {
  const summary = parseMeetingSummaryContent(
    JSON.stringify({
      decisions: ["Ship the edited summary UI"],
      actionItems: [
        { task: "Send customer recap", owner: "JP", deadline: "2026-05-03" },
      ],
      topics: ["Summary editing"],
      openQuestions: ["Should linked todos surface in exports?"],
    }),
    () => NOW,
  );

  assert.equal(
    summary.actionItems[0].id,
    actionItemIdFromFields({
      task: "Send customer recap",
      owner: "JP",
      deadline: "2026-05-03",
    }),
  );
  assert.equal(summary.sectionMetadata?.decisions.state, "generated");
  assert.equal(summary.sectionMetadata?.actionItems.modifiedAt, NOW);
  assert.equal(summary.wasSummarized, true);
});

test("single-section regeneration replaces one section and preserves user-edited metadata elsewhere", () => {
  const current = ensureMeetingSummaryMetadata(
    {
      decisions: ["Keep the existing user decision"],
      actionItems: [
        {
          id: actionItemIdFromFields({ task: "Send customer recap", owner: "JP", deadline: "2026-05-03" }),
          task: "Send customer recap",
          owner: "JP",
          deadline: "2026-05-03",
          isCompleted: false,
        },
      ],
      topics: ["Old topic"],
      openQuestions: ["Existing question"],
      wasSummarized: true,
      sectionMetadata: {
        decisions: { state: "userEdited", modifiedAt: NOW },
        actionItems: { state: "userEdited", modifiedAt: NOW },
        topics: { state: "generated", modifiedAt: NOW },
        openQuestions: { state: "generated", modifiedAt: NOW },
      },
    },
    () => NOW,
  );

  const next = mergeRegeneratedSummarySection(
    current,
    "topics",
    JSON.stringify({ topics: ["New regenerated topic"] }),
    () => LATER,
  );

  assert.deepEqual(next.decisions, ["Keep the existing user decision"]);
  assert.deepEqual(next.actionItems, current.actionItems);
  assert.deepEqual(next.topics, ["New regenerated topic"]);
  assert.deepEqual(next.openQuestions, ["Existing question"]);
  assert.deepEqual(next.sectionMetadata?.decisions, { state: "userEdited", modifiedAt: NOW });
  assert.deepEqual(next.sectionMetadata?.topics, { state: "generated", modifiedAt: LATER });
});

test("action summaries plan linked todos without duplicating regenerated follow-ups", () => {
  const actionId = actionItemIdFromFields({
    task: "Send customer recap",
    owner: "JP",
    deadline: "2026-05-03",
  });
  const meeting = {
    id: "meeting-1",
    title: "Customer Sync",
    date: NOW,
    duration: 1800,
    transcript: [],
    summary: {
      decisions: [],
      actionItems: [
        {
          id: actionId,
          task: "Send customer recap",
          owner: "JP",
          deadline: "2026-05-03",
          isCompleted: false,
        },
      ],
      topics: [],
      openQuestions: [],
      wasSummarized: true,
    },
  };

  const firstPass = buildLinkedTodosForMeetingActions(meeting, [], () => NOW);
  const secondPass = buildLinkedTodosForMeetingActions(meeting, firstPass, () => LATER);

  assert.equal(firstPass.length, 1);
  assert.equal(secondPass.length, 1);
  assert.equal(secondPass[0].id, firstPass[0].id);
  assert.equal(secondPass[0].title, "Send customer recap");
  assert.equal(secondPass[0].sourceMeetingID, "meeting-1");
  assert.equal(secondPass[0].sourceActionItemID, actionId);
  assert.equal(secondPass[0].owner, "JP");
  assert.equal(secondPass[0].dueDate, "2026-05-03");
  assert.equal(secondPass[0].completed, 0);
  assert.equal(secondPass[0].createdDate, NOW);
  assert.equal(secondPass[0].modifiedDate, LATER);
});

test("changed regenerated action items update the existing linked todo fields", () => {
  const oldActionId = actionItemIdFromFields({
    task: "Send customer recap",
    owner: "JP",
    deadline: "2026-05-03",
  });
  const newActionId = actionItemIdFromFields({
    task: "Send customer recap and benchmark table",
    owner: "Ana",
    deadline: "2026-05-04",
  });
  const existingTodo = {
    id: "todo-existing",
    title: "Send customer recap",
    description: "Old generated description",
    completed: 1,
    dueDate: "2026-05-03",
    owner: "JP",
    sourceMeetingID: "meeting-1",
    sourceActionItemID: oldActionId,
    createdDate: NOW,
    modifiedDate: NOW,
  };
  const meeting = {
    id: "meeting-1",
    title: "Customer Sync",
    date: NOW,
    duration: 1800,
    transcript: [],
    summary: {
      decisions: [],
      actionItems: [
        {
          id: newActionId,
          task: "Send customer recap and benchmark table",
          owner: "Ana",
          deadline: "2026-05-04",
          isCompleted: false,
        },
      ],
      topics: [],
      openQuestions: [],
      wasSummarized: true,
    },
  };

  const [todo] = buildLinkedTodosForMeetingActions(meeting, [existingTodo], () => LATER);

  assert.equal(todo.id, "todo-existing");
  assert.equal(todo.title, "Send customer recap and benchmark table");
  assert.equal(todo.description, "Action item from meeting \"Customer Sync\".\nOwner: Ana.\nDeadline: 2026-05-04.");
  assert.equal(todo.sourceActionItemID, newActionId);
  assert.equal(todo.owner, "Ana");
  assert.equal(todo.dueDate, "2026-05-04");
  assert.equal(todo.completed, 0);
  assert.equal(todo.createdDate, NOW);
  assert.equal(todo.modifiedDate, LATER);
});

test("removed regenerated action items are unlinked from the meeting", () => {
  const staleActionId = actionItemIdFromFields({
    task: "Publish old notes",
    owner: "JP",
    deadline: "2026-05-05",
  });
  const existingTodo = {
    id: "todo-stale",
    title: "Publish old notes",
    description: "Action item from meeting \"Customer Sync\".",
    completed: 0,
    dueDate: "2026-05-05",
    owner: "JP",
    sourceMeetingID: "meeting-1",
    sourceActionItemID: staleActionId,
    createdDate: NOW,
    modifiedDate: NOW,
  };
  const meeting = {
    id: "meeting-1",
    title: "Customer Sync",
    date: NOW,
    duration: 1800,
    transcript: [],
    summary: {
      decisions: [],
      actionItems: [],
      topics: [],
      openQuestions: [],
      wasSummarized: true,
    },
  };

  const plan = buildLinkedTodoSyncPlanForMeetingActions(meeting, [existingTodo], () => LATER);

  assert.deepEqual(plan.upserts, []);
  assert.equal(plan.unlinks.length, 1);
  assert.equal(plan.unlinks[0].id, "todo-stale");
  assert.equal(plan.unlinks[0].sourceMeetingID, null);
  assert.equal(plan.unlinks[0].sourceActionItemID, null);
  assert.equal(plan.unlinks[0].modifiedDate, LATER);
});
