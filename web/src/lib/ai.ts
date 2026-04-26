import type { LLMProvider, MeetingTemplate, MeetingSummary } from "./types";
import {
  buildMeetingSummaryMessages,
  emptyMeetingSummary,
  parseMeetingSummary,
  selectedLLMSettings,
} from "./ai-tasks";

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
  const { provider, model } = await selectedLLMSettings();

  const content = await chatCompletion({
    provider,
    model,
    messages: buildMeetingSummaryMessages(transcript, template),
  });

  try {
    return parseMeetingSummary(content);
  } catch {
    return emptyMeetingSummary(false);
  }
}

export async function chatWithAI(
  messages: { role: string; content: string }[],
  systemContext?: string
): Promise<string> {
  const { provider, model } = await selectedLLMSettings();

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
  const { provider } = await selectedLLMSettings();

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
