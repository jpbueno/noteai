export type RecordingSource = "microphone" | "systemAudio";
export type RecordingCaptureStatus = "idle" | "capturing" | "unavailable";
export type RecordingPermissionStatus = "unknown" | "granted" | "denied" | "prompt";

export interface RecordingSourceDiagnostic {
  status: RecordingCaptureStatus;
  level: number;
  updatedAt: number;
  reason?: string;
}

export interface RecordingDiagnostics {
  microphone: RecordingSourceDiagnostic;
  systemAudio: RecordingSourceDiagnostic;
  microphonePermission: RecordingPermissionStatus;
  systemAudioPermission: RecordingPermissionStatus;
  updatedAt: number;
}

export interface RecordingDiagnosticsInit {
  microphonePermission?: RecordingPermissionStatus;
  systemAudioPermission?: RecordingPermissionStatus;
  microphoneStatus?: RecordingCaptureStatus;
  systemAudioStatus?: RecordingCaptureStatus;
  microphoneReason?: string;
  systemAudioReason?: string;
  now?: number;
}

export const emptyRecordingDiagnostics = createRecordingDiagnostics();

export function createRecordingDiagnostics(init: RecordingDiagnosticsInit = {}): RecordingDiagnostics {
  const now = init.now ?? Date.now();
  return {
    microphone: {
      status: init.microphoneStatus ?? "idle",
      level: 0,
      updatedAt: now,
      reason: init.microphoneReason,
    },
    systemAudio: {
      status: init.systemAudioStatus ?? "idle",
      level: 0,
      updatedAt: now,
      reason: init.systemAudioReason,
    },
    microphonePermission: init.microphonePermission ?? "unknown",
    systemAudioPermission: init.systemAudioPermission ?? "unknown",
    updatedAt: now,
  };
}

export function recordingDiagnosticsWarnings(diagnostics: RecordingDiagnostics): string[] {
  const warnings: string[] = [];

  if (diagnostics.microphonePermission === "denied") {
    warnings.push("Microphone permission is denied.");
  }
  if (diagnostics.microphonePermission !== "denied" && diagnostics.microphone.status === "unavailable") {
    warnings.push(`Microphone is not being captured: ${diagnostics.microphone.reason || "Unavailable"}.`);
  }
  if (diagnostics.systemAudio.status === "unavailable") {
    warnings.push(`System audio is not being captured: ${diagnostics.systemAudio.reason || "Unavailable"}.`);
  }

  return warnings;
}

export function updateRecordingDiagnosticLevel(
  diagnostics: RecordingDiagnostics,
  source: RecordingSource,
  level: number,
  now = Date.now()
): RecordingDiagnostics {
  const clamped = Math.max(0, Math.min(1, level));
  return {
    ...diagnostics,
    [source]: {
      ...diagnostics[source],
      level: clamped,
      updatedAt: now,
    },
    updatedAt: now,
  };
}

export function updateRecordingDiagnosticSource(
  diagnostics: RecordingDiagnostics,
  source: RecordingSource,
  status: RecordingCaptureStatus,
  reason?: string,
  now = Date.now()
): RecordingDiagnostics {
  return {
    ...diagnostics,
    [source]: {
      ...diagnostics[source],
      status,
      reason,
      updatedAt: now,
    },
    updatedAt: now,
  };
}

export function updateRecordingDiagnosticPermission(
  diagnostics: RecordingDiagnostics,
  permission: "microphonePermission" | "systemAudioPermission",
  status: RecordingPermissionStatus,
  now = Date.now()
): RecordingDiagnostics {
  return {
    ...diagnostics,
    [permission]: status,
    updatedAt: now,
  };
}

export function diagnosticLogLines(diagnostics: RecordingDiagnostics): string[] {
  return [
    `updatedAt=${new Date(diagnostics.updatedAt).toISOString()}`,
    `microphone.status=${diagnostics.microphone.status}`,
    `microphone.level=${diagnostics.microphone.level.toFixed(3)}`,
    `systemAudio.status=${diagnostics.systemAudio.status}`,
    `systemAudio.level=${diagnostics.systemAudio.level.toFixed(3)}`,
    `microphone.permission=${diagnostics.microphonePermission}`,
    `systemAudio.permission=${diagnostics.systemAudioPermission}`,
  ];
}
