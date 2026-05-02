import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "./types" && context.parentURL?.endsWith("/src/lib/exports.ts")) {
      return nextResolve("./types.ts", context);
    }
    return nextResolve(specifier, context);
  },
});

const {
  generateMeetingMarkdown,
  generateMeetingPdfHtml,
  meetingMarkdownFilename,
  meetingPdfFilename,
} = await import("./src/lib/exports.ts");

const meeting = {
  id: "11111111-1111-1111-1111-111111111111",
  title: "Q3 / Launch: Readout?",
  date: "1970-01-01T00:00:00.000Z",
  duration: 3661,
  transcript: [
    { id: 1, text: "We approved launch.", startTime: 0, endTime: 2, speaker: "Ana", confidence: 0.95 },
    { id: 2, text: "I will update the brief.", startTime: 65, endTime: 68, speaker: null, confidence: 0.9 },
  ],
  summary: {
    decisions: ["Launch next week"],
    actionItems: [
      { id: "a1", task: "Update launch brief", owner: "Dev", deadline: "2026-05-01", isCompleted: false },
      { id: "a2", task: "Publish notes", owner: null, deadline: null, isCompleted: true },
    ],
    topics: ["Launch", "Readout"],
    openQuestions: ["Who sends the customer note?"],
    wasSummarized: true,
  },
  speakerLabels: {
    "speaker-1": "JP",
  },
};

test("meeting markdown export includes shared source fields and task list", () => {
  const markdown = generateMeetingMarkdown(meeting, {
    formatDateTime: () => "January 1, 1970 at 12:00 AM",
  });

  assert.match(markdown, /# Q3 \/ Launch: Readout\?/);
  assert.match(markdown, /\*\*Duration:\*\* 1h 1m/);
  assert.match(markdown, /\*\*Source:\*\* `noteai:\/\/meeting\/11111111-1111-1111-1111-111111111111`/);
  assert.match(markdown, /\*\*Segments:\*\* 2/);
  assert.match(markdown, /- \[ \] Update launch brief — \*\*Dev\*\* \(by 2026-05-01\)/);
  assert.match(markdown, /- \[x\] Publish notes/);
  assert.match(markdown, /\*\*\[01:05\] JP:\*\* I will update the brief\./);
});

test("meeting markdown filename is safe and predictable", () => {
  assert.equal(meetingMarkdownFilename(meeting), "Q3 - Launch- Readout.md");
});

test("meeting PDF HTML includes polished print styles and shared fields", () => {
  const html = generateMeetingPdfHtml(meeting, {
    formatDateTime: () => "January 1, 1970 at 12:00 AM",
  });

  assert.match(html, /<title>Q3 \/ Launch: Readout\?<\/title>/);
  assert.match(html, /@page/);
  assert.match(html, /noteai:\/\/meeting\/11111111-1111-1111-1111-111111111111/);
  assert.match(html, /<h2>Action Items<\/h2>/);
  assert.match(html, /☐ Update launch brief/);
  assert.match(html, /☑ Publish notes/);
  assert.match(html, /\[01:05\] JP/);
  assert.equal(meetingPdfFilename(meeting), "Q3 - Launch- Readout.pdf");
});
