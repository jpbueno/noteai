import type { LLMProvider, MeetingTemplate, MeetingSummary, CoachInsight, CoachInsightType } from "./types";
import { getSetting } from "./db";

async function proxyChat(params: {
  provider: string;
  model: string;
  messages: { role: string; content: string }[];
  temperature?: number;
  maxTokens?: number;
}): Promise<string> {
  const response = await fetch("/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(params),
  });

  const data = await response.json();

  if (!response.ok || data.error) {
    throw new Error(data.error || `Request failed (${response.status})`);
  }

  return data.content;
}

export async function chatCompletion(options: {
  provider: LLMProvider;
  model: string;
  messages: { role: string; content: string }[];
  temperature?: number;
  maxTokens?: number;
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

  try {
    const cleaned = content.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
    const parsed = JSON.parse(cleaned);
    return {
      decisions: parsed.decisions || [],
      actionItems: (parsed.actionItems || []).map(
        (ai: { task: string; owner?: string; deadline?: string }) => ({
          id: crypto.randomUUID(),
          task: ai.task,
          owner: ai.owner || null,
          deadline: ai.deadline || null,
          isCompleted: false,
        })
      ),
      topics: parsed.topics || [],
      openQuestions: parsed.openQuestions || [],
      wasSummarized: true,
    };
  } catch {
    return {
      decisions: [],
      actionItems: [],
      topics: [],
      openQuestions: [],
      wasSummarized: false,
    };
  }
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

  const formData = new FormData();
  formData.append("file", audioBlob, "recording.webm");
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

const COACH_SYSTEM_PROMPT = `You are a real-time AI meeting coach for an NVIDIA engineer. Analyze the live meeting transcript and provide NEW, actionable insights. Your role is to help the user contribute effectively during the call.

Categories (use exactly these type values):
- key_insight: Important observations, patterns, or context about what's being discussed
- talking_point: Suggested things the user could say or ask right now
- technical_answer: When a technical question is raised, provide a concise answer
- action_item: When someone commits to something or an action item is mentioned
- follow_up: Things that should be followed up on after the meeting

Rules:
- Be concise — each insight should be 1-3 sentences max
- Focus on what's ACTIONABLE right now during the meeting
- Do NOT repeat insights already provided
- Prioritize quality over quantity — 1-4 new insights per analysis
- If there's nothing new or useful to add, return an empty array

Return ONLY a JSON array (no markdown fences, no extra text):
[{"type": "key_insight", "content": "..."}, ...]`;

export async function analyzeTranscriptLive(
  fullTranscript: string,
  previousInsights: string[],
): Promise<CoachInsight[]> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const previousSummary = previousInsights.length > 0
    ? `\n\nPreviously identified insights (do NOT repeat):\n${previousInsights.map((p, i) => `${i + 1}. ${p}`).join("\n")}`
    : "";

  const content = await chatCompletion({
    provider,
    model,
    messages: [
      { role: "system", content: COACH_SYSTEM_PROMPT },
      { role: "user", content: `Live transcript so far:\n\n${fullTranscript}${previousSummary}\n\nProvide new insights only.` },
    ],
    temperature: 0.3,
    maxTokens: 1000,
  });

  try {
    const cleaned = content.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
    const parsed = JSON.parse(cleaned);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((item: { type?: string; content?: string }) => item.type && item.content)
      .map((item: { type: string; content: string }) => ({
        id: crypto.randomUUID(),
        timestamp: new Date().toISOString(),
        type: item.type as CoachInsightType,
        content: item.content,
      }));
  } catch {
    return [];
  }
}
