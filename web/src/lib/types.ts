export interface TranscriptSegment {
  id: number;
  text: string;
  startTime: number;
  endTime: number;
  speaker: string | null;
  confidence: number;
}

export interface ActionItem {
  id: string;
  task: string;
  owner: string | null;
  deadline: string | null;
  isCompleted: boolean;
}

export interface MeetingSummary {
  decisions: string[];
  actionItems: ActionItem[];
  topics: string[];
  openQuestions: string[];
  wasSummarized: boolean;
}

export interface Meeting {
  id: string;
  title: string;
  date: string; // ISO string
  duration: number; // seconds
  transcript: TranscriptSegment[];
  summary: MeetingSummary;
  pinned?: number;
}

export interface Note {
  id: string;
  title: string;
  content: string;
  tags: string[];
  createdDate: string;
  modifiedDate: string;
  sourceMeetingID: string | null;
  pinned?: number;
}

export interface TaskItem {
  id: string;
  title: string;
  description: string;
  rawInput: string;
  tags: string[];
  status: "pending" | "completed";
  createdDate: string;
  modifiedDate: string;
  sourceMeetingID: string | null;
  sourceNoteID: string | null;
  pinned?: number;
}

export interface T5TEntry {
  id: string;
  headline: string;
  explanation: string;
}

export interface T5TSections {
  insights: T5TEntry[];
  accountUpdates: T5TEntry[];
  futurePlans: T5TEntry[];
}

export interface T5TReport {
  id: string;
  title: string;
  createdDate: string;
  periodStart: string;
  periodEnd: string;
  meetingIDs: string[];
  noteIDs: string[];
  taskIDs: string[];
  sections: T5TSections;
  status: "draft" | "finalized";
  pinned?: number;
}

export interface BacklinkItem {
  id: string;
  type: "meeting" | "note" | "task" | "t5t";
  title: string;
  date: string;
  matchedTerms: string[];
}

export interface BacklinkResult {
  meetings: BacklinkItem[];
  notes: BacklinkItem[];
  tasks: BacklinkItem[];
  t5tReports: BacklinkItem[];
}

export interface T5TConfig {
  vertical: string;
  region: string;
  jobFunction: string;
  subjectLine: string;
}

export interface ChatMessage {
  id: string;
  role: "user" | "assistant" | "system";
  content: string;
  timestamp: string;
}

export type MeetingTemplate =
  | "auto"
  | "general"
  | "standup"
  | "sales"
  | "oneOnOne"
  | "brainstorm";

export const MEETING_TEMPLATES: Record<
  MeetingTemplate,
  { displayName: string; icon: string; promptInstruction: string }
> = {
  auto: {
    displayName: "Auto-Detect",
    icon: "Sparkles",
    promptInstruction:
      "Detect the meeting type and adapt your output format accordingly.",
  },
  general: {
    displayName: "General Meeting",
    icon: "Users",
    promptInstruction:
      "Format as a standard meeting summary with decisions, action items, topics discussed, and open questions.",
  },
  standup: {
    displayName: "Stand-up",
    icon: "UserCheck",
    promptInstruction:
      "Format as a stand-up summary: what each person completed, what they're working on next, and any blockers.",
  },
  sales: {
    displayName: "Sales / Customer Call",
    icon: "TrendingUp",
    promptInstruction:
      "Format as a sales call summary: customer pain points, objections raised, commitments made, and deal signals.",
  },
  oneOnOne: {
    displayName: "1:1",
    icon: "UserPlus",
    promptInstruction:
      "Format as a 1:1 summary: feedback shared, career development topics, and personal action items.",
  },
  brainstorm: {
    displayName: "Brainstorm",
    icon: "Lightbulb",
    promptInstruction:
      "Format as a brainstorm summary: all ideas proposed, directions chosen, and research tasks assigned.",
  },
};

export type LLMProvider = "openrouter" | "anthropic" | "openai" | "nvidia";

export const LLM_PROVIDERS: Record<
  LLMProvider,
  { displayName: string; keyHint: string }
> = {
  openrouter: {
    displayName: "OpenRouter",
    keyHint: "Get your key at openrouter.ai/keys",
  },
  anthropic: {
    displayName: "Anthropic",
    keyHint: "Get your key at console.anthropic.com",
  },
  openai: {
    displayName: "OpenAI",
    keyHint: "Get your key at platform.openai.com/api-keys",
  },
  nvidia: {
    displayName: "NVIDIA",
    keyHint: "Get your key at inference.nvidia.com/key-management",
  },
};

export type SidebarSelection =
  | { type: "meeting"; id: string }
  | { type: "note"; id: string }
  | { type: "task"; id: string }
  | { type: "t5t"; id: string }
  | { type: "settings" }
  | { type: "liveTranscript" }
  | null;
