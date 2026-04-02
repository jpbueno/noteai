import type { LLMProvider, MeetingTemplate, MeetingSummary } from "./types";
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
