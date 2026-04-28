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
  description: "Use the NoteAI macOS helper to diagnose Microsoft Teams desktop capture readiness.",
  icon: "teams",
  availability: "requires-helper",
  supportsRecording: false,
  statusLabel: "Helper needed",
  disabledReason: "Open the NoteAI macOS app to enable Teams Desktop diagnostics.",
};

export function buildRecordingSourceOptions(
  helperDetection?: LocalCaptureHelperDetection | null
): RecordingSourceOption[] {
  let teams = TEAMS_DESKTOP_RECORDING_SOURCE;

  if (helperDetection?.state === "connected") {
    const paired = Boolean(helperDetection.status);
    teams = {
      ...TEAMS_DESKTOP_RECORDING_SOURCE,
      availability: "diagnostics",
      statusLabel: paired ? "Diagnostics connected" : "Pairing needed",
      disabledReason: paired
        ? "Teams Desktop recording is diagnostics-only in this milestone."
        : "Teams Desktop recording is diagnostics-only until helper pairing and capture control ship.",
    };
  }

  return [BROWSER_TAB_RECORDING_SOURCE, teams];
}
