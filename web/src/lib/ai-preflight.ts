import type { LLMProvider } from "./types";

const PROVIDER_DISPLAY_NAMES: Record<LLMProvider, string> = {
  openrouter: "OpenRouter",
  anthropic: "Anthropic",
  openai: "OpenAI",
  nvidia: "NVIDIA",
};

export interface CopilotPreflightInput {
  provider: LLMProvider;
  providerKeyConfigured: boolean;
}

export interface RecordingPreflightInput extends CopilotPreflightInput {
  transcriptionKeyConfigured: boolean;
  microphoneStatus: string;
}

export interface RecordingSetupBlocker {
  message: string;
  target: "settings-ai";
}

export interface AISettingReader {
  getSetting: (key: string) => Promise<string | null | undefined>;
  isSettingConfigured: (key: string) => Promise<boolean>;
}

export function copilotSetupMessage(input: CopilotPreflightInput): string | null {
  if (input.providerKeyConfigured) return null;
  return `Add your ${PROVIDER_DISPLAY_NAMES[input.provider]} API key in AI settings before using AI copilot.`;
}

export function recordingSetupBlocker(input: RecordingPreflightInput): RecordingSetupBlocker | null {
  if (!input.providerKeyConfigured) {
    return {
      message: `Add your ${PROVIDER_DISPLAY_NAMES[input.provider]} summaries API key before recording.`,
      target: "settings-ai",
    };
  }

  if (!input.transcriptionKeyConfigured) {
    return {
      message: "Add a Groq or OpenAI transcription key before recording.",
      target: "settings-ai",
    };
  }

  if (input.microphoneStatus === "unsupported") {
    return {
      message: "This browser does not support microphone capture for recording.",
      target: "settings-ai",
    };
  }

  return null;
}

export async function loadCopilotSetupMessage(readSettings: AISettingReader): Promise<string | null> {
  const provider = ((await readSettings.getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const providerKeyConfigured = await readSettings.isSettingConfigured(`api_key_${provider}`);
  return copilotSetupMessage({ provider, providerKeyConfigured });
}
