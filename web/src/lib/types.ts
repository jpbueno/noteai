export type CoachInsightType = "key_insight" | "talking_point" | "technical_answer" | "action_item" | "follow_up";

export type CoachInsightBasis = "transcript" | "domain_knowledge" | "recommendation";

export type CoachInsightPriority = "low" | "medium" | "high" | "critical";

export type CoachInsightLifecycle = "active" | "dismissed" | "resolved" | "expired";

export interface CoachInsightEvidence {
  segmentId: number;
  startTime: number;
  endTime: number;
}

export interface CoachInsight {
  id: string;
  timestamp: string;
  type: CoachInsightType;
  content: string;
  priority?: CoachInsightPriority;
  basis?: CoachInsightBasis;
  evidence?: CoachInsightEvidence[];
  topic?: string;
  lifecycle?: CoachInsightLifecycle;
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

export type SpeakerLabels = Record<string, string>;

export const FALLBACK_SPEAKER_ID = "speaker-1";
export const LOCAL_SPEAKER_ID = "speaker-local";
export const REMOTE_SPEAKER_ID = "speaker-remote";

export function speakerIDForSegment(segment: Pick<TranscriptSegment, "speaker">): string {
  return normalizeSpeakerID(segment.speaker) ?? FALLBACK_SPEAKER_ID;
}

export function speakerDisplayNameForSegment(
  meeting: Pick<Meeting, "speakerLabels">,
  segment: Pick<TranscriptSegment, "speaker">,
): string {
  const speakerID = speakerIDForSegment(segment);
  const label = normalizeSpeakerLabel(meeting.speakerLabels?.[speakerID]);
  return label ?? defaultSpeakerDisplayName(speakerID);
}

export function setSpeakerLabel<T extends { speakerLabels?: SpeakerLabels }>(
  meeting: T,
  speakerID: string,
  displayName: string,
): T & { speakerLabels: SpeakerLabels } {
  const id = normalizeSpeakerID(speakerID);
  const speakerLabels = normalizeSpeakerLabels(meeting.speakerLabels);
  if (!id) return { ...meeting, speakerLabels };

  const label = normalizeSpeakerLabel(displayName);
  if (label) {
    speakerLabels[id] = label;
  } else {
    delete speakerLabels[id];
  }
  return { ...meeting, speakerLabels };
}

export function withSpeakerPlaceholders<T extends TranscriptSegment>(transcript: T[]): T[] {
  return transcript.map((segment) => ({
    ...segment,
    speaker: speakerIDForSegment(segment),
  }));
}

function normalizeSpeakerLabels(labels: SpeakerLabels | undefined): SpeakerLabels {
  return Object.fromEntries(
    Object.entries(labels ?? {}).flatMap(([rawID, rawLabel]) => {
      const id = normalizeSpeakerID(rawID);
      const label = normalizeSpeakerLabel(rawLabel);
      return id && label ? [[id, label]] : [];
    }),
  );
}

function normalizeSpeakerID(speaker: string | null | undefined): string | null {
  const trimmed = speaker?.trim();
  return trimmed ? trimmed : null;
}

function normalizeSpeakerLabel(label: string | null | undefined): string | null {
  const trimmed = label?.trim();
  return trimmed ? trimmed : null;
}

function defaultSpeakerDisplayName(speakerID: string): string {
  if (speakerID.toLowerCase() === LOCAL_SPEAKER_ID) return "You";
  if (speakerID.toLowerCase() === REMOTE_SPEAKER_ID) return "Remote audio";

  const match = /^speaker-(\d+)$/i.exec(speakerID);
  return match ? `Speaker ${Number(match[1])}` : speakerID;
}

export function buildIncompleteTranscriptWarning(options: {
  id: number;
  message: string;
  startTime: number;
  endTime: number;
}): TranscriptSegment {
  return {
    id: options.id,
    text: `[Transcript may be incomplete: ${options.message}]`,
    startTime: options.startTime,
    endTime: options.endTime,
    speaker: "System",
    confidence: 0,
  };
}

export function shouldAcceptFinalWhisperTranscript(text: string, preservedTextLength: number): boolean {
  const trimmed = text.trim();
  return trimmed.length > 0 && trimmed.length >= preservedTextLength;
}

export function chunkBlobForTranscription(blob: Blob, options: { maxBytes: number }): { chunks: Blob[]; skipped: boolean } {
  if (blob.size > options.maxBytes) {
    return { chunks: [], skipped: true };
  }

  return { chunks: [blob], skipped: false };
}

export interface ActionItem {
  id: string;
  task: string;
  owner: string | null;
  deadline: string | null;
  isCompleted: boolean;
}

export type SummarySectionKey = "decisions" | "actionItems" | "topics" | "openQuestions";
export type SummaryEditState = "generated" | "userEdited";

export interface SummarySectionMetadata {
  state: SummaryEditState;
  modifiedAt: string;
}

export type SummarySectionMetadataMap = Record<SummarySectionKey, SummarySectionMetadata>;

export const SUMMARY_SECTION_KEYS: SummarySectionKey[] = [
  "decisions",
  "actionItems",
  "topics",
  "openQuestions",
];

export interface MeetingSummary {
  decisions: string[];
  actionItems: ActionItem[];
  topics: string[];
  openQuestions: string[];
  wasSummarized: boolean;
  sectionMetadata?: SummarySectionMetadataMap;
}

export interface Meeting {
  id: string;
  title: string;
  date: string; // ISO string
  duration: number; // seconds
  transcript: TranscriptSegment[];
  summary: MeetingSummary;
  speakerLabels?: SpeakerLabels;
  pinned?: number;
}

export interface Note {
  id: string;
  title: string;
  content: string;
  tags: string[];
  space?: string | null;
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
  sourceMeetingID?: string | null;
  sourceActionItemID?: string | null;
  owner?: string | null;
  pinned?: number;
}

type TimestampProvider = () => string;

function defaultTimestamp(): string {
  return new Date().toISOString();
}

function cleanJsonContent(content: string): string {
  return content.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
}

function parseSummaryJson(content: string): unknown {
  return JSON.parse(cleanJsonContent(content));
}

function readStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => (typeof item === "string" ? item.trim() : ""))
    .filter(Boolean);
}

function readNullableString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function normalizeKeyPart(value: string | null | undefined): string {
  return (value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^\w\s-]/g, "")
    .replace(/\s+/g, " ");
}

function stableHash(value: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36);
}

export function normalizeActionItemKey(input: {
  task: string;
  owner?: string | null;
  deadline?: string | null;
}): string {
  return [
    normalizeKeyPart(input.task),
    normalizeKeyPart(input.owner),
    normalizeKeyPart(input.deadline),
  ].join("|");
}

export function actionItemIdFromFields(input: {
  task: string;
  owner?: string | null;
  deadline?: string | null;
}): string {
  return `action-${stableHash(normalizeActionItemKey(input))}`;
}

export function normalizeActionItems(value: unknown): ActionItem[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const record = item as Record<string, unknown>;
    const task = readNullableString(record.task);
    if (!task) return [];
    const owner = readNullableString(record.owner);
    const deadline = readNullableString(record.deadline);
    return [{
      id: actionItemIdFromFields({ task, owner, deadline }),
      task,
      owner,
      deadline,
      isCompleted: record.isCompleted === true,
    }];
  });
}

export function defaultSummarySectionMetadata(
  timestampProvider: TimestampProvider = defaultTimestamp,
): SummarySectionMetadataMap {
  const modifiedAt = timestampProvider();
  return {
    decisions: { state: "generated", modifiedAt },
    actionItems: { state: "generated", modifiedAt },
    topics: { state: "generated", modifiedAt },
    openQuestions: { state: "generated", modifiedAt },
  };
}

export function ensureMeetingSummaryMetadata(
  summary: MeetingSummary,
  timestampProvider: TimestampProvider = defaultTimestamp,
): MeetingSummary {
  const fallback = defaultSummarySectionMetadata(timestampProvider);
  const existing = summary.sectionMetadata;
  return {
    decisions: readStringArray(summary.decisions),
    actionItems: normalizeActionItems(summary.actionItems),
    topics: readStringArray(summary.topics),
    openQuestions: readStringArray(summary.openQuestions),
    wasSummarized: summary.wasSummarized,
    sectionMetadata: {
      decisions: existing?.decisions ?? fallback.decisions,
      actionItems: existing?.actionItems ?? fallback.actionItems,
      topics: existing?.topics ?? fallback.topics,
      openQuestions: existing?.openQuestions ?? fallback.openQuestions,
    },
  };
}

export function markSummarySectionState(
  summary: MeetingSummary,
  section: SummarySectionKey,
  state: SummaryEditState,
  timestampProvider: TimestampProvider = defaultTimestamp,
): MeetingSummary {
  const normalized = ensureMeetingSummaryMetadata(summary, timestampProvider);
  const sectionMetadata = normalized.sectionMetadata ?? defaultSummarySectionMetadata(timestampProvider);
  return {
    ...normalized,
    sectionMetadata: {
      ...sectionMetadata,
      [section]: { state, modifiedAt: timestampProvider() },
    },
  };
}

export function markSummarySectionUserEdited(
  summary: MeetingSummary,
  section: SummarySectionKey,
  timestampProvider: TimestampProvider = defaultTimestamp,
): MeetingSummary {
  return markSummarySectionState(summary, section, "userEdited", timestampProvider);
}

export function parseMeetingSummaryContent(
  content: string,
  timestampProvider: TimestampProvider = defaultTimestamp,
): MeetingSummary {
  try {
    const parsed = parseSummaryJson(content) as Record<string, unknown>;
    return ensureMeetingSummaryMetadata(
      {
        decisions: readStringArray(parsed.decisions),
        actionItems: normalizeActionItems(parsed.actionItems),
        topics: readStringArray(parsed.topics),
        openQuestions: readStringArray(parsed.openQuestions),
        wasSummarized: true,
      },
      timestampProvider,
    );
  } catch {
    return ensureMeetingSummaryMetadata(
      {
        decisions: [],
        actionItems: [],
        topics: [],
        openQuestions: [],
        wasSummarized: false,
      },
      timestampProvider,
    );
  }
}

export function mergeRegeneratedSummarySection(
  current: MeetingSummary,
  section: SummarySectionKey,
  content: string,
  timestampProvider: TimestampProvider = defaultTimestamp,
): MeetingSummary {
  const normalized = ensureMeetingSummaryMetadata(current, timestampProvider);
  const parsed = parseSummaryJson(content) as Record<string, unknown> | unknown[];
  const value = Array.isArray(parsed) ? parsed : parsed[section];
  const nextSection =
    section === "actionItems" ? normalizeActionItems(value) : readStringArray(value);

  return markSummarySectionState(
    {
      ...normalized,
      [section]: nextSection,
      wasSummarized: true,
    },
    section,
    "generated",
    timestampProvider,
  );
}

export function linkedTodoIdForAction(meetingID: string, sourceActionItemID: string): string {
  return `todo-${stableHash(`${meetingID}|${sourceActionItemID}`)}`;
}

function actionLinkedTodoDescription(meeting: Pick<Meeting, "title">, action: ActionItem): string {
  const parts = [`Action item from meeting "${meeting.title}".`];
  if (action.owner) parts.push(`Owner: ${action.owner}.`);
  if (action.deadline) parts.push(`Deadline: ${action.deadline}.`);
  return parts.join("\n");
}

function todoMatchesAction(todo: TodoItem, meetingID: string, action: ActionItem): boolean {
  if (todo.sourceMeetingID !== meetingID) return false;
  if (todo.sourceActionItemID === action.id) return true;
  if (todo.sourceActionItemID) return false;
  return normalizeActionItemKey({
    task: todo.title,
    owner: todo.owner ?? null,
    deadline: todo.dueDate,
  }) === normalizeActionItemKey(action);
}

export interface LinkedTodoSyncPlan {
  upserts: TodoItem[];
  unlinks: TodoItem[];
}

function buildTodoForAction(
  meeting: Meeting,
  action: ActionItem,
  existing: TodoItem | undefined,
  modifiedAt: string,
): TodoItem {
  return {
    ...(existing ?? {}),
    id: existing?.id ?? linkedTodoIdForAction(meeting.id, action.id),
    title: action.task,
    description: actionLinkedTodoDescription(meeting, action),
    completed: action.isCompleted ? 1 : 0,
    dueDate: action.deadline,
    createdDate: existing?.createdDate ?? modifiedAt,
    modifiedDate: modifiedAt,
    sourceMeetingID: meeting.id,
    sourceActionItemID: action.id,
    owner: action.owner,
    pinned: existing?.pinned ?? 0,
  };
}

export function buildLinkedTodoSyncPlanForMeetingActions(
  meeting: Meeting,
  existingTodos: TodoItem[],
  timestampProvider: TimestampProvider = defaultTimestamp,
): LinkedTodoSyncPlan {
  const now = timestampProvider();
  const meetingTodos = existingTodos.filter((todo) => todo.sourceMeetingID === meeting.id);

  if (!meeting.summary.wasSummarized) {
    return {
      upserts: [],
      unlinks: meetingTodos.map((todo) => ({
        ...todo,
        sourceMeetingID: null,
        sourceActionItemID: null,
        modifiedDate: now,
      })),
    };
  }

  const actions = normalizeActionItems(meeting.summary.actionItems);
  const usedTodoIDs = new Set<string>();
  const matchedTodos = actions.map((action) => {
    const exact = meetingTodos.find((todo) => !usedTodoIDs.has(todo.id) && todoMatchesAction(todo, meeting.id, action));
    if (exact) usedTodoIDs.add(exact.id);
    return exact;
  });

  const upserts = actions.map((action, index) => {
    const existing = matchedTodos[index] ?? meetingTodos.find((todo) => !usedTodoIDs.has(todo.id));
    if (existing) usedTodoIDs.add(existing.id);
    return buildTodoForAction(meeting, action, existing, now);
  });

  return {
    upserts,
    unlinks: meetingTodos
      .filter((todo) => !usedTodoIDs.has(todo.id))
      .map((todo) => ({
        ...todo,
        sourceMeetingID: null,
        sourceActionItemID: null,
        modifiedDate: now,
      })),
  };
}

export function buildLinkedTodosForMeetingActions(
  meeting: Meeting,
  existingTodos: TodoItem[],
  timestampProvider: TimestampProvider = defaultTimestamp,
): TodoItem[] {
  return buildLinkedTodoSyncPlanForMeetingActions(meeting, existingTodos, timestampProvider).upserts;
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
  | { type: "settings"; tab?: "general" | "ai" | "privacy" | "t5t" | "export" | "about" }
  | { type: "liveTranscript" }
  | null;
