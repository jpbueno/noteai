import {
  chunkBlobForTranscription,
  mergeRegeneratedSummarySection,
  parseMeetingSummaryContent,
  type LLMProvider,
  type Meeting,
  type MeetingTemplate,
  type MeetingSummary,
  type SummarySectionKey,
} from "./types";
import { getSetting } from "./db";
import {
  coachPolicy,
  type CoachContext,
  type CoachGenerationOutcome,
} from "./ai-coach-policy";

const CLIENT_CHAT_TIMEOUT_MS = 75_000;

async function proxyChat(params: {
  provider: string;
  model: string;
  messages: { role: string; content: string }[];
  temperature?: number;
  maxTokens?: number;
  signal?: AbortSignal;
}): Promise<string> {
  const { signal, ...request } = params;
  const controller = new AbortController();
  let timedOut = false;
  const abortFromCaller = () => controller.abort();
  if (signal?.aborted) abortFromCaller();
  else signal?.addEventListener("abort", abortFromCaller, { once: true });
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, CLIENT_CHAT_TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(request),
      signal: controller.signal,
    });
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError" && timedOut) {
      throw new Error("AI copilot request timed out. Try again or choose a faster model.");
    }
    throw err;
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", abortFromCaller);
  }

  const data = await response.json().catch(() => null);

  if (!response.ok || data?.error) {
    throw new Error(data?.error || `Request failed (${response.status})`);
  }

  if (typeof data?.content !== "string" || !data.content) {
    throw new Error("AI copilot returned an empty response.");
  }

  return data.content;
}

export async function chatCompletion(options: {
  provider: LLMProvider;
  model: string;
  messages: { role: string; content: string }[];
  temperature?: number;
  maxTokens?: number;
  signal?: AbortSignal;
}): Promise<string> {
  return proxyChat(options);
}

export async function summarizeTranscript(
  transcript: string,
  template: MeetingTemplate = "auto"
): Promise<MeetingSummary> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const templateInfo = {
    auto: "Detect the meeting type and adapt your output format accordingly.",
    general: "Format as a standard meeting summary with decisions, action items, topics discussed, and open questions.",
    standup: "Format as a stand-up summary: what each person completed, what they're working on next, and any blockers.",
    sales: "Format as a sales call summary: customer pain points, objections raised, commitments made, and deal signals.",
    oneOnOne: "Format as a 1:1 summary: feedback shared, career development topics, and personal action items.",
    brainstorm: "Format as a brainstorm summary: all ideas proposed, directions chosen, and research tasks assigned.",
  };

  const systemPrompt = `You are an expert meeting summarizer. ${templateInfo[template]}

Return your response as valid JSON with this exact structure:
{"decisions": ["..."], "actionItems": [{"task": "...", "owner": "...", "deadline": "..."}], "topics": ["..."], "openQuestions": ["..."]}

Only return the JSON object, no markdown fences or additional text.`;

  const content = await chatCompletion({
    provider,
    model,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: `Here is the meeting transcript:\n\n${transcript}` },
    ],
  });

  return parseMeetingSummaryContent(content);
}

export async function regenerateSummarySection(
  meeting: Meeting,
  section: SummarySectionKey,
  template: MeetingTemplate = "auto",
): Promise<MeetingSummary> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";
  const transcript = meeting.transcript.map((segment) => segment.text).join("\n");
  const sectionShape =
    section === "actionItems"
      ? `{"actionItems": [{"task": "...", "owner": "...", "deadline": "..."}]}`
      : `{"${section}": ["..."]}`;

  const content = await chatCompletion({
    provider,
    model,
    messages: [
      {
        role: "system",
        content: `You are an expert meeting summarizer. Regenerate only the requested section for the ${template} template.

Return valid JSON with exactly this shape:
${sectionShape}

Do not include any other summary section. For action items, include task, owner, and deadline when known. Use null or omit unknown owner/deadline values. Only return the JSON object, no markdown fences or extra text.`,
      },
      {
        role: "user",
        content: `Meeting title: ${meeting.title}

Current summary JSON:
${JSON.stringify(meeting.summary)}

Transcript:
${transcript}`,
      },
    ],
  });

  return mergeRegeneratedSummarySection(meeting.summary, section, content);
}

export async function chatWithAI(
  messages: { role: string; content: string }[],
  systemContext?: string
): Promise<string> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const allMessages = [
    {
      role: "system",
      content:
        systemContext ||
        "You are NoteAI, an intelligent meeting assistant. You help users understand their meetings, notes, and tasks. Be concise and helpful.",
    },
    ...messages,
  ];

  return chatCompletion({ provider, model, messages: allMessages });
}

export async function transcribeAudio(audioBlob: Blob): Promise<string> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const plan = chunkBlobForTranscription(audioBlob, { maxBytes: 24 * 1024 * 1024 });
  if (plan.skipped) {
    throw new Error("Recording is too large for one transcription request; preserved live transcript instead.");
  }

  const formData = new FormData();
  formData.append("file", plan.chunks[0], "recording.webm");
  formData.append("model", "whisper-1");
  formData.append("provider", provider);

  const response = await fetch("/api/transcribe", {
    method: "POST",
    body: formData,
  });

  const data = await response.json();

  if (!response.ok || data.error) {
    throw new Error(data.error || `Transcription failed (${response.status})`);
  }

  return data.text || "";
}

export async function analyzeTranscriptLive(
  context: CoachContext,
  options: { signal?: AbortSignal } = {},
): Promise<CoachGenerationOutcome> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const content = await chatCompletion({
    provider,
    model,
    messages: coachPolicy.buildAutoMessages(context),
    temperature: 0.3,
    maxTokens: 1000,
    signal: options.signal,
  });

  return coachPolicy.admit(content, context);
}

/**
 * Interactive chat with the AI Solutions Architect. The user asks a question or
 * clarification; the SA responds using the live transcript and prior insights
 * as context. Responses can be conversational and longer than auto-insights.
 */
export async function askAISA(
  question: string,
  context: CoachContext,
  history: { role: "user" | "assistant"; content: string }[],
  options: { signal?: AbortSignal } = {},
): Promise<string> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  return chatCompletion({
    provider,
    model,
    messages: coachPolicy.buildChatMessages({ question, context, history }),
    temperature: 0.4,
    maxTokens: 600,
    signal: options.signal,
  });
}
