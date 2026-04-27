import type { Meeting } from "./types";

interface MeetingMarkdownOptions {
  formatDateTime?: (iso: string) => string;
}

export function generateMeetingMarkdown(meeting: Meeting, options: MeetingMarkdownOptions = {}): string {
  const lines: string[] = [];
  const formatDateTime = options.formatDateTime ?? defaultFormatDateTime;

  lines.push(`# ${meeting.title}\n`);
  lines.push(`**Date:** ${formatDateTime(meeting.date)}`);
  lines.push(`**Duration:** ${formatDuration(meeting.duration)}`);
  lines.push(`**Source:** \`${sourceLink(meeting)}\``);
  lines.push(`**Segments:** ${meeting.transcript.length}\n`);

  const { summary } = meeting;
  if (summary.wasSummarized && !summaryEmpty(summary)) {
    lines.push("## Summary\n");
    if (summary.decisions.length > 0) {
      lines.push("### Key Decisions");
      summary.decisions.forEach((decision) => lines.push(`- ${decision}`));
      lines.push("");
    }
    if (summary.actionItems.length > 0) {
      lines.push("### Action Items");
      summary.actionItems.forEach((item) => {
        let line = `- [${item.isCompleted ? "x" : " "}] ${item.task}`;
        if (item.owner) line += ` — **${item.owner}**`;
        if (item.deadline) line += ` (by ${item.deadline})`;
        lines.push(line);
      });
      lines.push("");
    }
    if (summary.topics.length > 0) {
      lines.push("### Topics Discussed");
      summary.topics.forEach((topic) => lines.push(`- ${topic}`));
      lines.push("");
    }
    if (summary.openQuestions.length > 0) {
      lines.push("### Open Questions");
      summary.openQuestions.forEach((question) => lines.push(`- ${question}`));
      lines.push("");
    }
  }

  lines.push("## Transcript\n");
  meeting.transcript.forEach((segment) => {
    const timestamp = `[${formatTimestamp(segment.startTime)}]`;
    const speaker = segment.speaker ?? "Speaker";
    lines.push(`**${timestamp} ${speaker}:** ${segment.text}\n`);
  });

  return lines.join("\n");
}

export function meetingMarkdownFilename(meeting: Meeting): string {
  return `${safeFilenameStem(meeting.title)}.md`;
}

export function meetingPdfFilename(meeting: Meeting): string {
  return `${safeFilenameStem(meeting.title)}.pdf`;
}

export function generateMeetingPdfHtml(meeting: Meeting, options: MeetingMarkdownOptions = {}): string {
  const formatDateTime = options.formatDateTime ?? defaultFormatDateTime;
  const summary = meeting.summary;
  const title = escapeHtml(meeting.title);
  const source = sourceLink(meeting);
  const summaryBlocks = summary.wasSummarized && !summaryEmpty(summary)
    ? [
        sectionHtml("Key Decisions", summary.decisions.map((decision) => `<li>${escapeHtml(decision)}</li>`)),
        sectionHtml(
          "Action Items",
          summary.actionItems.map((item) => {
            const owner = item.owner ? ` <strong>${escapeHtml(item.owner)}</strong>` : "";
            const deadline = item.deadline ? ` <span class="muted">(by ${escapeHtml(item.deadline)})</span>` : "";
            return `<li>${item.isCompleted ? "☑" : "☐"} ${escapeHtml(item.task)}${owner}${deadline}</li>`;
          })
        ),
        sectionHtml("Topics Discussed", summary.topics.map((topic) => `<li>${escapeHtml(topic)}</li>`)),
        sectionHtml("Open Questions", summary.openQuestions.map((question) => `<li>${escapeHtml(question)}</li>`)),
      ].join("")
    : "";

  const transcript = meeting.transcript
    .map((segment) => {
      const speaker = escapeHtml(segment.speaker ?? "Speaker");
      return `<p><strong>[${formatTimestamp(segment.startTime)}] ${speaker}:</strong> ${escapeHtml(segment.text)}</p>`;
    })
    .join("");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>${title}</title>
  <style>
    @page { margin: 0.65in; }
    body { color: #111827; font: 13px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    h1 { font-size: 28px; line-height: 1.15; margin: 0 0 12px; }
    h2 { border-bottom: 1px solid #d1d5db; font-size: 17px; margin: 28px 0 10px; padding-bottom: 5px; }
    h3 { font-size: 13px; letter-spacing: 0.06em; margin: 18px 0 8px; text-transform: uppercase; }
    ul { margin: 0 0 14px 20px; padding: 0; }
    li { margin: 4px 0; }
    p { margin: 0 0 9px; }
    .meta { color: #4b5563; margin-bottom: 18px; }
    .muted { color: #6b7280; }
    .source { font-family: "SFMono-Regular", Consolas, monospace; font-size: 11px; }
  </style>
</head>
<body>
  <h1>${title}</h1>
  <div class="meta">
    <div><strong>Date:</strong> ${escapeHtml(formatDateTime(meeting.date))}</div>
    <div><strong>Duration:</strong> ${escapeHtml(formatDuration(meeting.duration))}</div>
    <div><strong>Source:</strong> <span class="source">${escapeHtml(source)}</span></div>
    <div><strong>Segments:</strong> ${meeting.transcript.length}</div>
  </div>
  ${summaryBlocks}
  <h2>Transcript</h2>
  ${transcript || `<p class="muted">No transcript segments recorded.</p>`}
</body>
</html>`;
}

export function printMeetingPdf(meeting: Meeting, options: MeetingMarkdownOptions = {}): void {
  const printWindow = window.open("", "_blank", "noopener,noreferrer,width=900,height=700");
  if (!printWindow) return;
  printWindow.document.write(generateMeetingPdfHtml(meeting, options));
  printWindow.document.close();
  printWindow.focus();
  printWindow.print();
}

function safeFilenameStem(title: string): string {
  const stem = title
    .replace(/[\\/:*"<>|]+/g, "-")
    .replace(/\?/g, "")
    .trim()
    .replace(/\s+/g, " ");
  return stem || "Meeting Export";
}

function sourceLink(meeting: Meeting): string {
  return `noteai://meeting/${meeting.id}`;
}

function summaryEmpty(summary: Meeting["summary"]): boolean {
  return (
    summary.decisions.length === 0 &&
    summary.actionItems.length === 0 &&
    summary.topics.length === 0 &&
    summary.openQuestions.length === 0
  );
}

function formatTimestamp(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = Math.floor(seconds % 60);
  return `${String(minutes).padStart(2, "0")}:${String(remainingSeconds).padStart(2, "0")}`;
}

function formatDuration(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = Math.floor(seconds % 60);
  if (minutes >= 60) {
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    return `${hours}h ${mins}m`;
  }
  return `${minutes}m ${remainingSeconds}s`;
}

function sectionHtml(title: string, items: string[]): string {
  if (items.length === 0) return "";
  return `<h2>${escapeHtml(title)}</h2><ul>${items.join("")}</ul>`;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function defaultFormatDateTime(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}
