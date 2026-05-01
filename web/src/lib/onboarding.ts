import type { LLMProvider } from "./types";

export type OnboardingPermission =
  | "granted"
  | "denied"
  | "prompt"
  | "default"
  | "unsupported"
  | "unknown";

export type OnboardingStatus =
  | "complete"
  | "needs-action"
  | "blocked"
  | "unsupported";

export interface OnboardingChecklistInput {
  provider: LLMProvider;
  providerKeyConfigured: boolean;
  transcriptionKeyConfigured: boolean;
  authConfigured: boolean;
  microphonePermission: OnboardingPermission;
  notificationPermission: OnboardingPermission;
  supportsMediaDevices: boolean;
  supportsNotifications: boolean;
  meetingCount: number;
}

export interface OnboardingChecklistItem {
  id:
    | "microphone"
    | "notifications"
    | "auth"
    | "ai-provider"
    | "transcription"
    | "privacy"
    | "first-recording";
  label: string;
  detail: string;
  actionLabel?: string;
  target?: "recording" | "settings-ai" | "settings-privacy" | "settings-general";
  status: OnboardingStatus;
  required: boolean;
}

export interface OnboardingChecklist {
  items: OnboardingChecklistItem[];
  completedCount: number;
  totalCount: number;
  requiredReady: boolean;
  firstRecordingBlocker: string | null;
}

function permissionStatus(
  permission: OnboardingPermission,
  supported: boolean,
): OnboardingStatus {
  if (!supported || permission === "unsupported") return "unsupported";
  if (permission === "granted") return "complete";
  if (permission === "denied") return "blocked";
  return "needs-action";
}

export function buildOnboardingChecklist(
  input: OnboardingChecklistInput,
): OnboardingChecklist {
  const microphoneStatus = permissionStatus(
    input.microphonePermission,
    input.supportsMediaDevices,
  );
  const notificationStatus = permissionStatus(
    input.notificationPermission,
    input.supportsNotifications,
  );
  const providerDisplayName = input.provider === "nvidia"
    ? "NVIDIA"
    : input.provider === "openrouter"
      ? "OpenRouter"
      : input.provider === "anthropic"
        ? "Anthropic"
        : "OpenAI";

  const requiredReady =
    microphoneStatus === "complete" &&
    input.providerKeyConfigured &&
    input.transcriptionKeyConfigured;
  const firstRecordingBlocker = !input.providerKeyConfigured
    ? `Add your ${providerDisplayName} summaries API key before recording.`
    : !input.transcriptionKeyConfigured
      ? "Add a Groq or OpenAI transcription key before recording."
      : microphoneStatus === "unsupported"
        ? "This browser does not support microphone capture for recording."
        : null;

  const items: OnboardingChecklistItem[] = [
    {
      id: "microphone",
      label: "Microphone access",
      detail:
        microphoneStatus === "unsupported"
          ? "This browser does not expose microphone capture to NoteAI."
          : "Required before recording a meeting.",
      actionLabel: "Start recording",
      target: "recording",
      status: microphoneStatus,
      required: true,
    },
    {
      id: "notifications",
      label: "Notifications",
      detail:
        notificationStatus === "unsupported"
          ? "Browser notifications are not available in this session."
          : "Optional alerts for finished processing and reminders.",
      actionLabel: "Review privacy",
      target: "settings-privacy",
      status: notificationStatus,
      required: false,
    },
    {
      id: "auth",
      label: "Workspace access",
      detail: "Optional Google sign-in keeps browser access tied to your authorized account.",
      actionLabel: "Review access",
      target: "settings-general",
      status: input.authConfigured ? "complete" : "needs-action",
      required: false,
    },
    {
      id: "ai-provider",
      label: `${providerDisplayName} summaries`,
      detail: "Choose a cloud AI provider and save its API key.",
      actionLabel: "Open AI settings",
      target: "settings-ai",
      status: input.providerKeyConfigured ? "complete" : "needs-action",
      required: true,
    },
    {
      id: "transcription",
      label: "Transcription key",
      detail: "Add a Groq or OpenAI key for web audio transcription.",
      actionLabel: "Open AI settings",
      target: "settings-ai",
      status: input.transcriptionKeyConfigured ? "complete" : "needs-action",
      required: true,
    },
    {
      id: "privacy",
      label: "Privacy controls",
      detail: "Review retention and cloud usage before sending audio or notes.",
      actionLabel: "Open privacy",
      target: "settings-privacy",
      status: "complete",
      required: false,
    },
    {
      id: "first-recording",
      label: "First recording",
      detail: firstRecordingBlocker ?? (requiredReady
        ? "You can record, transcribe, and summarize meetings."
        : "Complete required setup to avoid a failed first capture."),
      actionLabel: "Start recording",
      target: "recording",
      status: firstRecordingBlocker ? "blocked" : input.meetingCount > 0 ? "complete" : "needs-action",
      required: false,
    },
  ];

  return {
    items,
    completedCount: items.filter((item) => item.status === "complete").length,
    totalCount: items.length,
    requiredReady,
    firstRecordingBlocker,
  };
}
