import type { LocalCaptureHelperDetection } from "./local-helper";

export type RecordingSourceId = "browser-tab" | "teams-desktop";
export type RecordingSourceAvailability = "available" | "diagnostics" | "requires-helper";
export type RecordingSourceIcon = "browser" | "teams";

export interface RecordingSourceOption {
  id: RecordingSourceId;
  label: string;
  description: string;
  icon: RecordingSourceIcon;
  availability: RecordingSourceAvailability;
  supportsRecording: boolean;
  statusLabel: string;
  disabledReason?: string;
}

export const BROWSER_TAB_RECORDING_SOURCE: RecordingSourceOption = {
  id: "browser-tab",
  label: "Browser Tab",
  description: "Capture the browser microphone and optional shared tab audio.",
  icon: "browser",
  availability: "available",
  supportsRecording: true,
  statusLabel: "Ready",
};

export const TEAMS_DESKTOP_RECORDING_SOURCE: RecordingSourceOption = {
  id: "teams-desktop",
  label: "Teams Desktop",
  description: "Use the NoteAI macOS helper to capture Microsoft Teams desktop meetings.",
  icon: "teams",
  availability: "requires-helper",
  supportsRecording: false,
  statusLabel: "Helper needed",
  disabledReason: "Open the NoteAI macOS app to enable Teams Desktop recording.",
};

export function buildRecordingSourceOptions(
  helperDetection?: LocalCaptureHelperDetection | null
): RecordingSourceOption[] {
  let teams = TEAMS_DESKTOP_RECORDING_SOURCE;

  if (helperDetection?.state === "connected") {
    const paired = Boolean(helperDetection.status);
    const captureControl = Boolean(helperDetection.health?.capabilities.captureControl);
    const recording = helperDetection.status?.captureState === "recording";
    teams = {
      ...TEAMS_DESKTOP_RECORDING_SOURCE,
      availability: paired && captureControl ? "available" : "diagnostics",
      supportsRecording: paired && captureControl,
      statusLabel: paired && captureControl
        ? recording ? "Recording" : "Ready"
        : paired
          ? "Update helper"
          : "Pair helper",
      disabledReason: paired && captureControl
        ? undefined
        : paired
          ? "Reopen or update the NoteAI macOS app to enable Teams Desktop capture control."
          : "Pair the NoteAI web app with the local helper before recording Teams Desktop.",
    };
  }

  return [BROWSER_TAB_RECORDING_SOURCE, teams];
}
