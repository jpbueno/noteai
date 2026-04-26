import type {
  LLMProvider,
  Meeting,
  MeetingSummary,
  MeetingTemplate,
  Note,
  T5TSections,
  TaskItem,
} from "./types";
import { getSetting } from "./db";

export type ChatMessageInput = { role: string; content: string };
export type ChatCompletion = (options: {
  provider: LLMProvider;
  model: string;
  messages: ChatMessageInput[];
  temperature?: number;
  maxTokens?: number;
}) => Promise<string>;

export function extractJSONObject(raw: string): string {
  const cleaned = raw
    .replace(/```json\s*/gi, "")
    .replace(/```\s*/g, "")
    .trim();

  let depth = 0;
  let start = -1;
  for (let i = 0; i < cleaned.length; i++) {
    if (cleaned[i] === "{") {
      if (depth === 0) start = i;
      depth += 1;
    } else if (cleaned[i] === "}") {
      depth -= 1;
      if (depth === 0 && start !== -1) {
        return cleaned.slice(start, i + 1);
      }
    }
  }
  return cleaned;
}

export function parseMeetingSummary(raw: string): MeetingSummary {
  const parsed = JSON.parse(extractJSONObject(raw));
  return {
    decisions: Array.isArray(parsed.decisions) ? parsed.decisions : [],
    actionItems: (Array.isArray(parsed.actionItems) ? parsed.actionItems : []).map(
      (item: { task?: string; owner?: string | null; deadline?: string | null }) => ({
        id: crypto.randomUUID(),
        task: String(item.task || ""),
        owner: item.owner || null,
        deadline: item.deadline || null,
        isCompleted: false,
      })
    ),
    topics: Array.isArray(parsed.topics) ? parsed.topics : [],
    openQuestions: Array.isArray(parsed.openQuestions) ? parsed.openQuestions : [],
    wasSummarized: true,
  };
}

export function emptyMeetingSummary(wasSummarized = false): MeetingSummary {
  return {
    decisions: [],
    actionItems: [],
    topics: [],
    openQuestions: [],
    wasSummarized,
  };
}

export function parseTaskAccomplishment(raw: string): { title: string; description: string } {
  try {
    const parsed = JSON.parse(extractJSONObject(raw));
    if (parsed.title && parsed.description) {
      return {
        title: String(parsed.title),
        description: String(parsed.description),
      };
    }
  } catch {
    // Fall through to forgiving extraction.
  }

  const titleMatch = raw.match(/"title"\s*:\s*"([^"]+)"/);
  const descMatch = raw.match(/"description"\s*:\s*"([^"]+)"/);
  return {
    title: titleMatch?.[1] || raw.split("\n")[0].slice(0, 60),
    description: descMatch?.[1] || raw,
  };
}

export function parseT5TSections(raw: string): T5TSections {
  const parsed = JSON.parse(extractJSONObject(raw));
  const mapEntries = (items: unknown) =>
    (Array.isArray(items) ? items : []).map(
      (entry: { headline?: string; explanation?: string }) => ({
        id: crypto.randomUUID(),
        headline: String(entry.headline || ""),
        explanation: String(entry.explanation || ""),
      })
    );

  return {
    insights: mapEntries(parsed.insights),
    accountUpdates: mapEntries(parsed.accountUpdates),
    futurePlans: mapEntries(parsed.futurePlans),
  };
}

export function buildT5TContext(
  meetings: Meeting[],
  notes: Note[],
  tasks: TaskItem[]
): string {
  const parts: string[] = [];

  if (meetings.length) {
    parts.push("MEETINGS:");
    for (const meeting of meetings) {
      parts.push(
        [
          `${meeting.title} (${new Date(meeting.date).toLocaleDateString()})`,
          `Decisions: ${meeting.summary.decisions.join("; ")}`,
          `Actions: ${meeting.summary.actionItems.map((a) => a.task).join("; ")}`,
          `Topics: ${meeting.summary.topics.join("; ")}`,
        ].join("\n")
      );
    }
  }

  if (notes.length) {
    parts.push("NOTES:");
    for (const note of notes) {
      parts.push(`${note.title}\n${note.content.slice(0, 2000)}`);
    }
  }

  if (tasks.length) {
    parts.push("TASKS:");
    for (const task of tasks) {
      parts.push(`${task.title} (${task.status})\n${task.rawInput || task.description}`);
    }
  }

  return parts.join("\n\n---\n\n");
}

export function buildMeetingSummaryMessages(
  transcript: string,
  template: MeetingTemplate
): ChatMessageInput[] {
  const templateInfo: Record<MeetingTemplate, string> = {
    auto: "Detect the meeting type and adapt your output format accordingly.",
    general: "Format as a standard meeting summary with decisions, action items, topics discussed, and open questions.",
    standup: "Format as a stand-up summary: what each person completed, what they're working on next, and any blockers.",
    sales: "Format as a sales call summary: customer pain points, objections raised, commitments made, and deal signals.",
    oneOnOne: "Format as a 1:1 summary: feedback shared, career development topics, and personal action items.",
    brainstorm: "Format as a brainstorm summary: all ideas proposed, directions chosen, and research tasks assigned.",
  };

  return [
    {
      role: "system",
      content: `You are an expert meeting summarizer. ${templateInfo[template]}

Return your response as valid JSON with this exact structure:
{"decisions": ["..."], "actionItems": [{"task": "...", "owner": "...", "deadline": "..."}], "topics": ["..."], "openQuestions": ["..."]}

Only return the JSON object, no markdown fences or additional text.`,
    },
    { role: "user", content: `Here is the meeting transcript:\n\n${transcript}` },
  ];
}

export function buildTaskAccomplishmentMessages(rawInput: string): ChatMessageInput[] {
  return [
    {
      role: "user",
      content: `Extract the key accomplishment from this email/message. Write everything in FIRST PERSON ("I configured...", "I resolved...", "I enabled...").

Return ONLY a single JSON object. No markdown fences, no extra text, no commentary. Just the JSON.

{"title": "...", "description": "..."}

TITLE: Very short label (3-6 words max). Just enough to identify the task at a glance. Like a filename or tag.
DESCRIPTION: A 2-3 sentence first-person explanation with full detail -- what I accomplished, why it matters, the outcome, names, projects, tools. This is the main content.

INPUT:
${rawInput.slice(0, 4000)}`,
    },
  ];
}

export function buildT5TMessages(
  periodStart: string,
  periodEnd: string,
  context: string
): { systemContext: string; messages: ChatMessageInput[] } {
  return {
    systemContext:
      "You are a technical account manager writing a T5T (Top 5 in Top 5) report. Be concise and executive-focused.",
    messages: [
      {
        role: "user",
        content: `Based on the following meetings, notes, and tasks from ${new Date(periodStart).toLocaleDateString()} to ${new Date(periodEnd).toLocaleDateString()}, generate a T5T report with three sections: Insights (management escalations, market & competition), Account Updates (industry business development), and Future Plans.

Return valid JSON: {"insights": [{"headline": "...", "explanation": "..."}], "accountUpdates": [{"headline": "...", "explanation": "..."}], "futurePlans": [{"headline": "...", "explanation": "..."}]}

Context:
${context}`,
      },
    ],
  };
}

export async function selectedLLMSettings(): Promise<{
  provider: LLMProvider;
  model: string;
}> {
  return {
    provider: ((await getSetting("llm_provider")) || "openrouter") as LLMProvider,
    model: (await getSetting("llm_model")) || "anthropic/claude-sonnet-4",
  };
}

