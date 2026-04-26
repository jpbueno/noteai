export type CoachInsightType = "key_insight" | "talking_point" | "technical_answer" | "action_item" | "follow_up";

export interface CoachInsight {
  id: string;
  timestamp: string;
  type: CoachInsightType;
  content: string;
  /** When set, this entry is a chat message rather than an auto-generated insight. */
  role?: "user" | "assistant";
}

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

export interface TodoItem {
  id: string;
  title: string;
  description: string;
  completed: number; // 0 or 1
  dueDate: string | null;
  createdDate: string;
  modifiedDate: string;
  pinned?: number;
  // Google Docs sync tracking (manager's running log). 0/1 flag + ISO timestamp.
  syncedToGoogleDocs?: number;
  googleDocsSyncedAt?: string | null;
}

// ===== Daily Logs =====

export interface DailyLogSection {
  name: string;
  content: string;
}

export interface DailyLog {
  id: string;
  date: string; // YYYY-MM-DD
  sections: DailyLogSection[];
  linkedMeetingIDs: string[];
  createdDate: string;
  modifiedDate: string;
  pinned?: number;
}

// ===== T5T Report =====

export interface T5TReportSection {
  id: string;
  name: string;
  content: string; // markdown
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
  todoIDs: string[];
  dailyLogIDs: string[];
  sections: T5TReportSection[];
  status: "draft" | "finalized";
  pinned?: number;
}

// ===== T5T Configuration =====

export interface T5TManager {
  name: string;
  email: string;
}

export interface T5TIdentity {
  name: string;
  email: string;
  role: string;
  team: string;
  managers: T5TManager[];
  // New fields for the Top 5 Things email format
  focus?: string;      // e.g. "Inference Ops"
  region?: string;     // e.g. "NALA"
  roleShort?: string;  // e.g. "SA" (used in subject line)
  mobile?: string;     // e.g. "+1 407 725-1322"
}

export interface T5TEmailSettings {
  subjectFormat: string;
  greeting: string;
  closing: string;
}

export interface T5TReportTemplateSection {
  id: string;
  name: string;
  type: "bullets" | "table" | "freeform";
  placeholder: string;
}

export interface T5TSectionMapping {
  dailySection: string;
  reportSection: string;
}

export interface T5TDailyTemplateSection {
  name: string;
  classification: "report-worthy" | "personal";
  hint: string;
}

export interface T5TWritingPrinciples {
  audience: string;
  tone: string;
  person: string;
  detailDepth: string;
  dataStyle: string;
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
  identity: T5TIdentity;
  emailSettings: T5TEmailSettings;
  reportTemplate: T5TReportTemplateSection[];
  dailyTemplate: T5TDailyTemplateSection[];
  sectionMapping: T5TSectionMapping[];
  writingPrinciples: T5TWritingPrinciples;
  jiraBaseUrl: string;
  jiraProjectKeys: string[];
  nvbugBaseUrl: string;
}

export const DEFAULT_T5T_CONFIG: T5TConfig = {
  identity: {
    name: "JP Santana",
    email: "jbuenosantan@nvidia.com",
    role: "Senior Solutions Architect",
    team: "",
    managers: [],
    focus: "Inference Ops",
    region: "NALA",
    roleShort: "SA",
    mobile: "+1 407 725-1322",
  },
  emailSettings: {
    subjectFormat: "Top 5 Things - {{focus}} | {{region}} | {{roleShort}}",
    greeting: "",
    closing: "Thank you,\n \n{{name}} | {{role}}\nEmail: {{email}}\nMobile: {{mobile}}",
  },
  reportTemplate: [
    {
      id: "account-updates",
      name: "Industry Business Development / Account Updates",
      type: "freeform",
      placeholder: "4-5 outcome-focused updates, each with a bold headline + substantive paragraph.",
    },
    {
      id: "future-plans",
      name: "Future Plans",
      type: "bullets",
      placeholder: "3-5 short, concrete upcoming priorities.",
    },
  ],
  dailyTemplate: [
    { name: "Morning Plan", classification: "personal", hint: "Top priorities for the day" },
    { name: "Project Work", classification: "report-worthy", hint: "Main project tasks, deliverables, progress" },
    { name: "Automation / Tooling", classification: "report-worthy", hint: "Scripts, tools, CI/CD, automation work" },
    { name: "Meetings & Collaboration", classification: "report-worthy", hint: "Meeting notes, discussion outcomes" },
    { name: "Other", classification: "report-worthy", hint: "Knowledge sharing, process improvements" },
    { name: "In-Progress & Carry-Over", classification: "report-worthy", hint: "Items needing follow-up" },
    { name: "Blockers", classification: "report-worthy", hint: "Anything blocking progress" },
    { name: "Personal Notes", classification: "personal", hint: "Learning notes, brainstorms, ideas" },
    { name: "Issues/Bugs", classification: "report-worthy", hint: "Bug IDs, impact, status" },
  ],
  sectionMapping: [
    { dailySection: "Project Work", reportSection: "Projects" },
    { dailySection: "Automation / Tooling", reportSection: "Automation / Tooling" },
    { dailySection: "Meetings & Collaboration", reportSection: "Other Activities" },
    { dailySection: "Other", reportSection: "Other Activities" },
    { dailySection: "Issues/Bugs", reportSection: "Key Issues" },
    { dailySection: "In-Progress & Carry-Over", reportSection: "Next Week" },
    { dailySection: "Blockers", reportSection: "Key Issues" },
  ],
  writingPrinciples: {
    audience: "Busy managers (2-3 minute read)",
    tone: "Professional, first-person, concise",
    person: "first",
    detailDepth: "High-level outcomes with sub-bullet details",
    dataStyle: "Data-driven — lead with metrics where possible",
  },
  jiraBaseUrl: "https://jirasw.nvidia.com/browse",
  jiraProjectKeys: ["EQT", "SWQA"],
  nvbugBaseUrl: "https://nvbugspro.nvidia.com/bug",
};

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
  | { type: "t5t"; id: string }
  | { type: "todo"; id: string }
  | { type: "dailyLog"; id: string }
  | { type: "meetingList" }
  | { type: "noteList" }
  | { type: "t5tList" }
  | { type: "settings" }
  | { type: "liveTranscript" }
  | null;
