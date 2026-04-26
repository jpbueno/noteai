import { v4 as uuid } from "uuid";
import { repositories } from "./repositories";
import { createNoteDraft, createTaskDraft, createT5TReportDraft, type LibrarySnapshot } from "./library";
import type { ChatMessage } from "./types";

type AssistantAction =
  | { action: "create_note"; title?: string; content?: string; tags?: string[] }
  | { action: "create_task"; title?: string; description?: string; tags?: string[] }
  | { action: "create_t5t" }
  | { action: "search"; query?: string }
  | { action: "list_meetings" }
  | { action: "list_notes" }
  | { action: "list_tasks" };

export const assistantSystemPrompt = `You are NoteAI Assistant, an AI helper embedded in a productivity app. You help the user manage meetings, notes, tasks, and T5T reports.

When the user asks you to perform an action, include a JSON action block in your response like this:
\`\`\`json
{"action": "action_name", "param": "value"}
\`\`\`

Available actions:
- create_note: {"action":"create_note", "title":"...", "content":"...", "tags":["..."]}
- create_task: {"action":"create_task", "title":"...", "description":"...", "tags":["..."]}
- create_t5t: {"action":"create_t5t"}
- search: {"action":"search", "query":"..."}
- list_meetings: {"action":"list_meetings"}
- list_notes: {"action":"list_notes"}
- list_tasks: {"action":"list_tasks"}

Always respond conversationally and include the action block when taking an action.`;

export function stripAssistantActionBlocks(text: string): string {
  return text
    .replace(/```json\s*\{[\s\S]*?"action"[\s\S]*?\}\s*```/gi, "")
    .trim();
}

export function parseAssistantAction(response: string): AssistantAction | null {
  const block = response.match(/```json\s*([\s\S]*?)\s*```/i)?.[1];
  if (!block) return null;
  try {
    const parsed = JSON.parse(block);
    return typeof parsed.action === "string" ? (parsed as AssistantAction) : null;
  } catch {
    return null;
  }
}

export async function executeAssistantAction(
  action: AssistantAction | null,
  snapshot: LibrarySnapshot
): Promise<ChatMessage | null> {
  if (!action) return null;
  const timestamp = new Date().toISOString();

  const systemMessage = (content: string): ChatMessage => ({
    id: uuid(),
    role: "system",
    content,
    timestamp,
  });

  switch (action.action) {
    case "create_note": {
      const note = createNoteDraft(new Date(), uuid());
      note.title = action.title || note.title;
      note.content = action.content || "";
      note.tags = action.tags || [];
      await repositories.notes.save(note);
      return systemMessage(`Created note: ${note.title}`);
    }
    case "create_task": {
      const task = createTaskDraft(new Date(), uuid());
      task.title = action.title || "";
      task.description = action.description || "";
      task.rawInput = action.description || "";
      task.tags = action.tags || [];
      await repositories.tasks.save(task);
      return systemMessage(`Created task: ${task.title || "Untitled task"}`);
    }
    case "create_t5t": {
      const report = createT5TReportDraft(snapshot.meetings, new Date(), uuid());
      await repositories.t5tReports.save(report);
      return systemMessage(`Created T5T report: ${report.title}`);
    }
    case "search": {
      const query = (action.query || "").toLowerCase();
      const results = [
        ...snapshot.meetings.filter((m) => m.title.toLowerCase().includes(query)).slice(0, 5).map((m) => `Meeting: ${m.title}`),
        ...snapshot.notes.filter((n) => `${n.title} ${n.content}`.toLowerCase().includes(query)).slice(0, 5).map((n) => `Note: ${n.title}`),
        ...snapshot.tasks.filter((t) => t.title.toLowerCase().includes(query)).slice(0, 5).map((t) => `Task: ${t.title}`),
      ];
      return systemMessage(results.length ? results.join("\n") : `No results for '${action.query || ""}'`);
    }
    case "list_meetings":
      return systemMessage(snapshot.meetings.slice(0, 10).map((m) => m.title).join("\n") || "No meetings yet.");
    case "list_notes":
      return systemMessage(snapshot.notes.slice(0, 10).map((n) => n.title).join("\n") || "No notes yet.");
    case "list_tasks":
      return systemMessage(snapshot.tasks.map((t) => `${t.status} ${t.title}`).join("\n") || "No tasks yet.");
    default:
      return null;
  }
}

