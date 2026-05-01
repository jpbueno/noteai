import {
  createRecordingDiagnostics,
  diagnosticLogLines,
  updateRecordingDiagnosticLevel,
  updateRecordingDiagnosticPermission,
  updateRecordingDiagnosticSource,
  type RecordingDiagnostics,
  type RecordingSource,
} from "./recording-diagnostics";
import {
  MicrophoneStartupError,
  acquireMicrophoneStream,
  canContinueWithoutMicrophone,
  enumerateAudioInputDevices,
  formatMicrophoneStartupError,
} from "./microphone-startup";
import {
  connectMicrophoneToCaptureMix,
  createCaptureMixGraph,
  type CaptureMixGraph,
} from "./audio-mixing";
import { buildIncompleteTranscriptWarning } from "./types";

export type RecordingState = "idle" | "starting" | "recording" | "processing";

type TranscriptCallback = (text: string, isFinal: boolean) => void;
type LevelCallback = (level: number) => void;
type DiagnosticsCallback = (diagnostics: RecordingDiagnostics) => void;

/* eslint-disable @typescript-eslint/no-explicit-any */
type SpeechRecognitionInstance = any;
/* eslint-enable @typescript-eslint/no-explicit-any */

const WHISPER_MAX_BYTES = 24 * 1024 * 1024;
const WHISPER_WINDOW_MS = 20_000;
const WHISPER_FETCH_TIMEOUT_MS = 45_000;
const WHISPER_MAX_FAILURES = 3;
const WHISPER_WINDOW_ATTEMPTS = 2;

async function whisperTranscribe(blob: Blob, prompt?: string, signal?: AbortSignal): Promise<string> {
  const formData = new FormData();
  formData.append("file", blob, "chunk.webm");
  if (prompt) formData.append("prompt", prompt);
  const res = await fetch("/api/transcribe", { method: "POST", body: formData, signal });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data.text || "";
}

export async function getAudioInputDevices(options: { requestPermission?: boolean } = {}): Promise<{ deviceId: string; label: string }[]> {
  if (options.requestPermission ?? true) {
    try {
      const tempStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      tempStream.getTracks().forEach((t) => t.stop());
    } catch { /* ignore */ }
  }
  const devices = await enumerateAudioInputDevices(navigator.mediaDevices);
  return devices
    .map((d) => ({ deviceId: d.deviceId, label: d.label || `Mic ${d.deviceId.slice(0, 6)}` }));
}

/** Find BlackHole device for system audio loopback capture */
async function findBlackHoleDevice(): Promise<string | null> {
  const devices = await getAudioInputDevices({ requestPermission: false });
  const bh = devices.find((d) => d.label.toLowerCase().includes("blackhole"));
  return bh?.deviceId ?? null;
}

/**
 * Reliable timer using a Web Worker — immune to Chrome background tab throttling.
 * Falls back to setInterval if Worker creation fails.
 */
class WorkerTimer {
  private worker: Worker | null = null;
  private callbacks = new Map<number, () => void>();
  private fallbackTimers = new Map<number, ReturnType<typeof setInterval>>();
  private nextId = 1;

  constructor() {
    try {
      this.worker = new Worker("/timer-worker.js");
      this.worker.onmessage = (e) => {
        const cb = this.callbacks.get(e.data.id);
        if (cb) cb();
      };
    } catch {
      this.worker = null;
    }
  }

  setInterval(callback: () => void, ms: number): number {
    const id = this.nextId++;
    this.callbacks.set(id, callback);

    if (this.worker) {
      this.worker.postMessage({ type: "start", id, interval: ms });
    } else {
      this.fallbackTimers.set(id, setInterval(callback, ms));
    }
    return id;
  }

  clearInterval(id: number): void {
    this.callbacks.delete(id);
    if (this.worker) {
      this.worker.postMessage({ type: "stop", id });
    }
    const fb = this.fallbackTimers.get(id);
    if (fb != null) {
      globalThis.clearInterval(fb);
      this.fallbackTimers.delete(id);
    }
  }

  terminate(): void {
    if (this.worker) {
      this.worker.postMessage({ type: "stopAll" });
      this.worker.terminate();
      this.worker = null;
    }
    this.fallbackTimers.forEach((t) => globalThis.clearInterval(t));
    this.fallbackTimers.clear();
    this.callbacks.clear();
  }
}

export class AudioRecorder {
  private mediaRecorder: MediaRecorder | null = null;
  private chunks: Blob[] = [];
  private tabStream: MediaStream | null = null;
  private micStream: MediaStream | null = null;
  private mixedStream: MediaStream | null = null;
  private whisperWindowRecorder: MediaRecorder | null = null;
  private pendingWhisperWindows: Blob[] = [];
  private audioCtx: AudioContext | null = null;
  private recognition: SpeechRecognitionInstance = null;
  private workerTimer: WorkerTimer | null = null;
  private watchdogId = 0;
  private whisperId = 0;
  private startTime = 0;
  private onTranscript: TranscriptCallback | null = null;
  private recognitionRunning = false;
  private stopped = false;
  private hasTabAudio = false;
  private lastWhisperText = "";
  private whisperOversizeNotified = false;
  private whisperDisabled = false;
  private whisperFailureCount = 0;
  private whisperWindowBusy = false;
  private whisperWarningSegmentId = 0;
  private lastResultTime = 0;
  private micDeviceId: string | undefined;
  private systemStream: MediaStream | null = null;
  private micSourceNode: MediaStreamAudioSourceNode | null = null;
  private mixGraph: CaptureMixGraph | null = null;
  private deviceChangeHandler: (() => void) | null = null;
  private micRecoveryTimerId = 0;
  private micRecoveryInFlight = false;
  private micRecoveryAttempts = 0;
  private levelAnalyser: AnalyserNode | null = null;
  private levelCtx: AudioContext | null = null;
  private levelRafId: number = 0;
  private diagnosticLevelContexts: AudioContext[] = [];
  private diagnosticLevelRafIds: number[] = [];
  private onLevel: LevelCallback | null = null;
  private onDiagnostics: DiagnosticsCallback | null = null;
  private diagnostics: RecordingDiagnostics = createRecordingDiagnostics();
  private activeMicLabel: string = "";

  private ensureStartupActive(stream?: MediaStream | null): void {
    if (!this.stopped) return;

    stream?.getTracks().forEach((track) => track.stop());
    throw new Error("Recording startup cancelled.");
  }

  /**
   * @param onTranscript - callback for live transcript segments
   * @param micDeviceId - specific mic device ID (or undefined for default)
   * @param captureTab - if true, prompt user to share a tab for system audio capture
   * @param onLevel - optional callback for mic level (0-1) — useful for UI meters
   * @param onDiagnostics - optional callback for permission/capture/level diagnostics
   */
  async start(onTranscript?: TranscriptCallback, micDeviceId?: string, captureTab = false, onLevel?: LevelCallback, onDiagnostics?: DiagnosticsCallback): Promise<void> {
    this.onLevel = onLevel || null;
    this.onDiagnostics = onDiagnostics || null;
    this.diagnostics = createRecordingDiagnostics();
    await this.refreshPermissionDiagnostics();
    this.emitDiagnostics();
    this.chunks = [];
    this.stopped = false;
    this.hasTabAudio = false;
    this.lastWhisperText = "";
    this.pendingWhisperWindows = [];
    this.whisperWindowBusy = false;
    this.whisperWarningSegmentId = 0;
    this.onTranscript = onTranscript || null;
    this.micDeviceId = micDeviceId;

    // Worker-based timers that survive background tab throttling
    this.workerTimer = new WorkerTimer();

    // 1. Start with mic capture. If Chrome temporarily loses its mic device
    //    list after refresh, tab/system audio can still carry the recording.
    let micStream: MediaStream | null = null;
    let availableMics: MediaDeviceInfo[] = [];
    let micStartupError: MicrophoneStartupError | null = null;
    try {
      const micResult = await acquireMicrophoneStream(navigator.mediaDevices, { micDeviceId });
      micStream = micResult.stream;
      availableMics = micResult.devices;
      this.ensureStartupActive(micStream);
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticPermission(
          updateRecordingDiagnosticSource(current, "microphone", "capturing"),
          "microphonePermission",
          "granted"
        )
      );
    } catch (err) {
      const micError = err instanceof MicrophoneStartupError
        ? err
        : new MicrophoneStartupError(
          "access-failed",
          err instanceof Error ? err.message : String(err),
          { cause: err }
        );
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticSource(
          updateRecordingDiagnosticPermission(
            current,
            "microphonePermission",
            micError.kind === "permission-denied" ? "denied" : current.microphonePermission
          ),
          "microphone",
          "unavailable",
          micError.message
        )
      );
      this.writeDiagnosticsLog("Microphone unavailable");
      if (!canContinueWithoutMicrophone(micError, captureTab)) {
        throw new Error(formatMicrophoneStartupError(micError));
      }
      micStartupError = micError;
    }
    this.micStream = micStream;

    // Diagnostics: figure out which mic we actually got
    if (micStream) {
      try {
        const activeTrack = micStream.getAudioTracks()[0];
        const settings = activeTrack?.getSettings?.();
        const allDevices = availableMics.length > 0 ? availableMics : await enumerateAudioInputDevices(navigator.mediaDevices);
        this.ensureStartupActive();
        const match = allDevices.find((d) => d.deviceId === settings?.deviceId);
        this.activeMicLabel = match?.label || activeTrack?.label || "unknown mic";
        if (this.onTranscript) {
          this.onTranscript(`[Mic active: ${this.activeMicLabel}]`, true);
        }
      } catch { /* ignore */ }
    }

    this.ensureStartupActive();

    // Set up level monitoring — always runs so the UI can show audio presence
    if (micStream) {
      this.startLevelMeter(micStream, "microphone", this.onLevel || undefined);
    }

    // 2. Try BlackHole for system audio loopback (captures ALL speaker output)
    const blackHoleId = await findBlackHoleDevice();
    this.ensureStartupActive();
    let systemStream: MediaStream | null = null;

    if (blackHoleId) {
      try {
        systemStream = await navigator.mediaDevices.getUserMedia({
          audio: { deviceId: { exact: blackHoleId } },
        });
        this.ensureStartupActive(systemStream);
        this.hasTabAudio = true;
        this.updateDiagnostics((current) =>
          updateRecordingDiagnosticPermission(
            updateRecordingDiagnosticSource(current, "systemAudio", "capturing"),
            "systemAudioPermission",
            "granted"
          )
        );
        if (this.onTranscript) {
          this.onTranscript("[System audio captured via BlackHole — all speaker output will be transcribed]", true);
        }
      } catch (err) {
        this.updateDiagnostics((current) =>
          updateRecordingDiagnosticSource(current, "systemAudio", "unavailable", err instanceof Error ? err.message : "BlackHole capture failed")
        );
        console.warn("[NoteAI] BlackHole capture failed:", err);
      }
    }

    // 3. Fall back to getDisplayMedia for system audio capture
    //    Always try this if no BlackHole — captureTab just controls whether we prompt
    if (!systemStream && captureTab) {
      try {
        const displayStream = await navigator.mediaDevices.getDisplayMedia({
          video: true,
          audio: true,
        });
        this.ensureStartupActive(displayStream);
        displayStream.getVideoTracks().forEach((t) => t.stop());
        if (displayStream.getAudioTracks().length > 0) {
          systemStream = displayStream;
          this.tabStream = displayStream;
          this.hasTabAudio = true;
          this.updateDiagnostics((current) =>
            updateRecordingDiagnosticPermission(
              updateRecordingDiagnosticSource(current, "systemAudio", "capturing"),
              "systemAudioPermission",
              "granted"
            )
          );
          if (this.onTranscript) {
            const prefix = micStartupError
              ? "[Mic unavailable - recording tab audio only. "
              : "[";
            const suffix = micStartupError
              ? "Whisper transcription active]"
              : "Tab audio captured — Whisper transcription active]";
            this.onTranscript(`${prefix}${suffix}`, true);
          }
        } else {
          this.updateDiagnostics((current) =>
            updateRecordingDiagnosticSource(current, "systemAudio", "unavailable", "Tab audio was not shared")
          );
          if (this.onTranscript) {
            this.onTranscript("[Tab shared but no audio track — did you check 'Also share tab audio'?]", true);
          }
        }
      } catch (err) {
        this.updateDiagnostics((current) =>
          updateRecordingDiagnosticSource(current, "systemAudio", "unavailable", err instanceof Error ? err.message : "Tab capture cancelled")
        );
        if (this.onTranscript) {
          this.onTranscript(`[Tab capture skipped: ${err instanceof Error ? err.message : "cancelled"}]`, true);
        }
      }
    }
    this.systemStream = systemStream;
    if (!systemStream && !captureTab && !blackHoleId) {
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticSource(current, "systemAudio", "unavailable", "Start with tab audio to capture system sound")
      );
    }
    if (systemStream) {
      this.startLevelMeter(systemStream, "systemAudio");
    }

    // 4. Mix system audio through a stable AudioContext destination. Even when
    // the mic is unavailable at startup, this leaves a live place to attach it
    // later if Chrome/macOS exposes the device during the recording.
    let recordStream: MediaStream;
    if (systemStream && systemStream.getAudioTracks().length > 0) {
      const ctx = new AudioContext();
      const graph = createCaptureMixGraph(ctx, { systemStream, microphoneStream: micStream });
      this.audioCtx = ctx;
      this.mixGraph = graph;
      this.micSourceNode = graph.microphoneSource;
      this.mixedStream = graph.recordStream;
      recordStream = graph.recordStream;
    } else if (micStream) {
      recordStream = micStream;
    } else if (micStartupError) {
      throw new Error(formatMicrophoneStartupError(micStartupError));
    } else {
      throw new Error("No audio source is available for recording.");
    }

    // 5. Single recorder
    const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
      ? "audio/webm;codecs=opus"
      : "audio/webm";

    this.mediaRecorder = new MediaRecorder(recordStream, { mimeType });
    this.mediaRecorder.ondataavailable = (e) => {
      if (e.data.size > 0) this.chunks.push(e.data);
    };
    this.mediaRecorder.start(1000);
    this.startTime = Date.now();

    if (!micStream && micStartupError && systemStream) {
      this.startDeferredMicrophoneRecovery(micStartupError);
    }

    // 6. Live transcription via SpeechRecognition + Whisper polling
    this.startSpeechRecognition();
    this.lastResultTime = Date.now();

    // Watchdog: restart SpeechRecognition if it dies or stalls (Worker-based, throttle-proof)
    this.watchdogId = this.workerTimer.setInterval(() => {
      if (this.stopped || this.mediaRecorder?.state !== "recording") return;
      const stale = Date.now() - this.lastResultTime > 10000;
      if (!this.recognitionRunning || stale) {
        console.log(`[NoteAI] Restarting SpeechRecognition (running=${this.recognitionRunning}, stale=${stale})`);
        this.restartRecognition();
      }
    }, 3000);

    // Whisper polling for better accuracy (Worker-based timer)
    this.startWhisperPolling(recordStream, mimeType);

    // 7. Listen for audio device changes (AirPods connect/disconnect, etc.)
    // When the user switches devices, reconnect mic to follow the new device
    this.deviceChangeHandler = () => this.handleDeviceChange();
    navigator.mediaDevices.addEventListener("devicechange", this.deviceChangeHandler);
    this.writeDiagnosticsLog("Capture started");
  }

  // --- Whisper polling ---

  private startWhisperPolling(recordStream: MediaStream, mimeType: string): void {
    // Only poll Whisper when we have system/tab audio (both speakers).
    // With mic-only, SpeechRecognition is sufficient and Whisper would
    // just produce duplicates.
    if (!this.hasTabAudio) return;

    // Use short standalone MediaRecorder windows instead of ever-growing blobs.
    // Each stopped window has its own WebM headers, so long meetings stay under
    // proxy limits and earlier transcript segments remain preserved if one
    // window fails.
    this.startWhisperWindow(recordStream, mimeType);
    setTimeout(() => {
      if (!this.stopped) this.rotateWhisperWindow(recordStream, mimeType);
    }, WHISPER_WINDOW_MS);
    if (this.workerTimer) {
      this.whisperId = this.workerTimer.setInterval(() => {
        if (!this.stopped) this.rotateWhisperWindow(recordStream, mimeType);
      }, WHISPER_WINDOW_MS);
    }
  }

  private startWhisperWindow(recordStream: MediaStream, mimeType: string): void {
    if (this.stopped || this.whisperDisabled) return;
    if (this.whisperWindowRecorder && this.whisperWindowRecorder.state !== "inactive") return;

    try {
      const windowChunks: Blob[] = [];
      const recorder = new MediaRecorder(recordStream, { mimeType });
      this.whisperWindowRecorder = recorder;
      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) windowChunks.push(event.data);
      };
      recorder.onstop = () => {
        if (windowChunks.length > 0) {
          this.pendingWhisperWindows.push(new Blob(windowChunks, { type: mimeType }));
          void this.drainWhisperWindows();
        }
      };
      recorder.start(1000);
    } catch (err) {
      this.handleWhisperWindowFailure(err);
    }
  }

  private rotateWhisperWindow(recordStream: MediaStream, mimeType: string): void {
    if (this.stopped || this.whisperDisabled) return;

    const recorder = this.whisperWindowRecorder;
    if (!recorder || recorder.state === "inactive") {
      this.startWhisperWindow(recordStream, mimeType);
      return;
    }

    try {
      recorder.requestData();
      recorder.stop();
    } catch (err) {
      this.handleWhisperWindowFailure(err);
    } finally {
      this.whisperWindowRecorder = null;
      setTimeout(() => this.startWhisperWindow(recordStream, mimeType), 0);
    }
  }

  private async drainWhisperWindows(): Promise<void> {
    if (this.whisperWindowBusy) return;
    const blob = this.pendingWhisperWindows.shift();
    if (!blob) return;

    this.whisperWindowBusy = true;
    try {
      if (blob.size > WHISPER_MAX_BYTES) {
        throw new Error(`Whisper window exceeded ${(WHISPER_MAX_BYTES / 1024 / 1024).toFixed(0)} MB`);
      }

      const text = await this.transcribeWhisperWindow(blob);
      this.whisperFailureCount = 0;
      if (text && this.onTranscript) {
        this.lastWhisperText = `${this.lastWhisperText} ${text}`.trim();
        this.onTranscript(text, true);
      }
    } catch (err) {
      this.handleWhisperWindowFailure(err);
    } finally {
      this.whisperWindowBusy = false;
      if (this.pendingWhisperWindows.length > 0) {
        void this.drainWhisperWindows();
      }
    }
  }

  private async transcribeWhisperWindow(blob: Blob): Promise<string> {
    let lastError: unknown;

    for (let attempt = 1; attempt <= WHISPER_WINDOW_ATTEMPTS; attempt++) {
      const controller = new AbortController();
      const timeoutHandle = setTimeout(() => controller.abort(), WHISPER_FETCH_TIMEOUT_MS);
      try {
        const promptContext = this.lastWhisperText.slice(-150) || undefined;
        return (await whisperTranscribe(blob, promptContext, controller.signal)).trim();
      } catch (err) {
        lastError = err;
        console.warn(`[NoteAI] Whisper window attempt ${attempt} failed:`, err);
      } finally {
        clearTimeout(timeoutHandle);
      }
    }

    throw lastError instanceof Error ? lastError : new Error("Whisper window failed");
  }

  private handleWhisperWindowFailure(err: unknown): void {
    this.whisperFailureCount++;
    console.warn(`[NoteAI] Whisper window failed (${this.whisperFailureCount}):`, err);

    if (this.onTranscript) {
      const warning = buildIncompleteTranscriptWarning({
        id: this.whisperWarningSegmentId++,
        message: "Whisper chunk failed; live transcript preserved",
        startTime: this.elapsed,
        endTime: this.elapsed,
      });
      this.onTranscript(warning.text, true);
    }

    if (this.whisperFailureCount >= WHISPER_MAX_FAILURES) {
      this.whisperDisabled = true;
      if (this.onTranscript && !this.whisperOversizeNotified) {
        this.whisperOversizeNotified = true;
        this.onTranscript("[Whisper unavailable — switched to mic-only transcription for remainder]", true);
      }
    }
  }

  // --- SpeechRecognition (always active) ---

  private restartRecognition(): void {
    if (this.stopped) return;
    if (this.recognition) {
      try { this.recognition.abort(); } catch { /* ignore */ }
      this.recognition = null;
    }
    this.recognitionRunning = false;
    setTimeout(() => {
      if (!this.stopped && this.mediaRecorder?.state === "recording") {
        this.startSpeechRecognition();
      }
    }, 100);
  }

  private startSpeechRecognition(): void {
    /* eslint-disable @typescript-eslint/no-explicit-any */
    const W = window as any;
    const SpeechRecognitionCtor = W.SpeechRecognition || W.webkitSpeechRecognition;
    /* eslint-enable @typescript-eslint/no-explicit-any */
    if (!SpeechRecognitionCtor) return;

    const recognition = new SpeechRecognitionCtor();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = "en-US";
    recognition.maxAlternatives = 1;

    recognition.onstart = () => { this.recognitionRunning = true; };

    recognition.onresult = (event: { resultIndex: number; results: { length: number; [i: number]: { isFinal: boolean; 0: { transcript: string } } } }) => {
      this.lastResultTime = Date.now();
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const result = event.results[i];
        const text = result[0].transcript.trim();
        if (!text || !this.onTranscript) continue;

        if (this.hasTabAudio && !this.whisperDisabled) {
          // When we have system audio AND Whisper is still running, Whisper
          // handles final segments (it hears both speakers). SpeechRecognition
          // only provides interim previews.
          if (!result.isFinal) {
            this.onTranscript(text, false);
          }
          // Drop SpeechRecognition finals — Whisper will produce them.
        } else {
          // Mic-only mode, OR Whisper disabled (blob too large): SpeechRecognition
          // is the transcription source.
          this.onTranscript(text, result.isFinal);
        }
      }
    };

    recognition.onerror = (event: { error: string }) => {
      if (event.error === "aborted" || event.error === "no-speech" || event.error === "network") return;
      console.warn("Speech recognition error:", event.error);
    };

    recognition.onend = () => {
      this.recognitionRunning = false;
      if (!this.stopped && this.mediaRecorder?.state === "recording") {
        try { recognition.start(); } catch { /* watchdog */ }
      }
    };

    try {
      recognition.start();
      this.recognition = recognition;
    } catch {
      this.recognitionRunning = false;
    }
  }

  // --- Device change handling ---

  private async handleDeviceChange(): Promise<void> {
    if (this.stopped || !this.mediaRecorder || this.mediaRecorder.state !== "recording") return;

    // Check if our current mic track is still alive
    const micTrack = this.micStream?.getAudioTracks()[0];
    if (micTrack && micTrack.readyState === "live") return; // still good

    console.log("[NoteAI] Audio device changed — reconnecting mic");

    try {
      // Get a new mic stream from the (now-current) default device
      const newMicStream = await navigator.mediaDevices.getUserMedia({
        audio: this.micDeviceId ? { deviceId: { exact: this.micDeviceId } } : true,
      });

      // Stop old mic tracks
      if (this.micStream) {
        this.micStream.getTracks().forEach((t) => t.stop());
      }
      this.micStream = newMicStream;
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticSource(current, "microphone", "capturing")
      );
      this.startLevelMeter(newMicStream, "microphone", this.onLevel || undefined);

      if (this.mixGraph && this.audioCtx?.state !== "closed") {
        this.micSourceNode = connectMicrophoneToCaptureMix(this.mixGraph, newMicStream);
      }

      if (this.onTranscript) {
        const devices = await getAudioInputDevices();
        const active = newMicStream.getAudioTracks()[0];
        const label = devices.find((d) => d.deviceId === active?.getSettings()?.deviceId)?.label || "new device";
        this.onTranscript(`[Mic switched to: ${label}]`, true);
      }
    } catch (err) {
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticSource(current, "microphone", "unavailable", err instanceof Error ? err.message : "Device reconnect failed")
      );
      console.warn("[NoteAI] Failed to reconnect mic after device change:", err);
    }
  }

  // --- Stop ---

  stop(): Blob {
    this.stopped = true;
    if (this.deviceChangeHandler) {
      navigator.mediaDevices.removeEventListener("devicechange", this.deviceChangeHandler);
      this.deviceChangeHandler = null;
    }
    if (this.workerTimer) {
      this.workerTimer.terminate();
      this.workerTimer = null;
    }
    this.micRecoveryTimerId = 0;
    this.micRecoveryInFlight = false;
    this.micRecoveryAttempts = 0;
    if (this.recognition) {
      try { this.recognition.abort(); } catch { /* ignore */ }
      this.recognition = null;
    }
    this.recognitionRunning = false;
    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
      this.mediaRecorder.stop();
    }
    if (this.whisperWindowRecorder && this.whisperWindowRecorder.state !== "inactive") {
      try {
        this.whisperWindowRecorder.stop();
      } catch { /* ignore */ }
    }
    this.whisperWindowRecorder = null;
    this.pendingWhisperWindows = [];
    if (this.tabStream) { this.tabStream.getTracks().forEach((t) => t.stop()); this.tabStream = null; }
    if (this.micStream) { this.micStream.getTracks().forEach((t) => t.stop()); this.micStream = null; }
    if (this.mixedStream) { this.mixedStream.getTracks().forEach((t) => t.stop()); this.mixedStream = null; }
    if (this.systemStream) { this.systemStream.getTracks().forEach((t) => t.stop()); this.systemStream = null; }
    if (this.audioCtx) { this.audioCtx.close().catch(() => {}); this.audioCtx = null; }
    if (this.levelRafId) { cancelAnimationFrame(this.levelRafId); this.levelRafId = 0; }
    if (this.levelCtx) { this.levelCtx.close().catch(() => {}); this.levelCtx = null; }
    this.diagnosticLevelRafIds.forEach((id) => cancelAnimationFrame(id));
    this.diagnosticLevelRafIds = [];
    this.diagnosticLevelContexts.forEach((ctx) => ctx.close().catch(() => {}));
    this.diagnosticLevelContexts = [];
    this.levelAnalyser = null;
    this.micSourceNode = null;
    this.mixGraph = null;
    this.onTranscript = null;
    this.onLevel = null;
    this.updateDiagnostics((current) =>
      updateRecordingDiagnosticSource(
        updateRecordingDiagnosticSource(current, "microphone", "idle"),
        "systemAudio",
        "idle"
      )
    );
    this.writeDiagnosticsLog("Capture stopped");
    this.onDiagnostics = null;
    const blob = new Blob(this.chunks, { type: "audio/webm" });
    this.chunks = [];
    return blob;
  }

  get elapsed(): number {
    if (!this.startTime) return 0;
    return Math.floor((Date.now() - this.startTime) / 1000);
  }

  get isRecording(): boolean {
    return this.mediaRecorder?.state === "recording";
  }

  get capturingTabAudio(): boolean {
    return this.hasTabAudio;
  }

  get diagnosticSnapshot(): RecordingDiagnostics {
    return this.diagnostics;
  }

  private async refreshPermissionDiagnostics(): Promise<void> {
    if (!("permissions" in navigator) || !navigator.permissions?.query) return;

    try {
      const micPermission = await navigator.permissions.query({ name: "microphone" as PermissionName });
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticPermission(
          current,
          "microphonePermission",
          micPermission.state === "granted" ? "granted" : micPermission.state === "denied" ? "denied" : "prompt"
        )
      );
    } catch { /* Browser may not support microphone permission query. */ }
  }

  private startLevelMeter(stream: MediaStream, source: RecordingSource, onLevel?: LevelCallback): void {
    try {
      const ctx = new AudioContext();
      const mediaSource = ctx.createMediaStreamSource(stream);
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 512;
      analyser.smoothingTimeConstant = 0.4;
      mediaSource.connect(analyser);
      this.diagnosticLevelContexts.push(ctx);

      const data = new Uint8Array(analyser.frequencyBinCount);
      let rafId = 0;
      const tick = () => {
        if (this.stopped) return;
        analyser.getByteTimeDomainData(data);
        let sumSq = 0;
        for (let i = 0; i < data.length; i++) {
          const v = (data[i] - 128) / 128;
          sumSq += v * v;
        }
        const rms = Math.sqrt(sumSq / data.length);
        const level = Math.min(1, rms * 4);
        onLevel?.(level);
        this.updateDiagnostics((current) => updateRecordingDiagnosticLevel(current, source, level));
        rafId = requestAnimationFrame(tick);
      };
      tick();
      this.diagnosticLevelRafIds.push(rafId);
    } catch (err) {
      console.warn("[NoteAI] Diagnostic level meter setup failed:", err);
    }
  }

  private startDeferredMicrophoneRecovery(initialError: MicrophoneStartupError): void {
    if (!this.workerTimer || initialError.kind === "permission-denied" || this.micRecoveryTimerId) return;

    this.updateDiagnostics((current) =>
      updateRecordingDiagnosticSource(
        current,
        "microphone",
        "unavailable",
        `${initialError.message}; retrying while tab audio records`
      )
    );

    this.micRecoveryTimerId = this.workerTimer.setInterval(() => {
      if (this.stopped || this.micStream || this.micRecoveryAttempts >= 12) {
        this.clearMicrophoneRecoveryTimer();
        return;
      }
      void this.tryRecoverMicrophone();
    }, 5000);

    void this.tryRecoverMicrophone();
  }

  private clearMicrophoneRecoveryTimer(): void {
    if (this.workerTimer && this.micRecoveryTimerId) {
      this.workerTimer.clearInterval(this.micRecoveryTimerId);
    }
    this.micRecoveryTimerId = 0;
  }

  private async tryRecoverMicrophone(): Promise<void> {
    if (this.stopped || this.micStream || this.micRecoveryInFlight) return;
    this.micRecoveryInFlight = true;
    this.micRecoveryAttempts += 1;

    try {
      const micResult = await acquireMicrophoneStream(navigator.mediaDevices, {
        micDeviceId: this.micDeviceId,
        maxNoDeviceRetries: 0,
      });
      this.ensureStartupActive(micResult.stream);
      this.micStream = micResult.stream;
      if (this.mixGraph && this.audioCtx?.state !== "closed") {
        this.micSourceNode = connectMicrophoneToCaptureMix(this.mixGraph, micResult.stream);
      }
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticPermission(
          updateRecordingDiagnosticSource(current, "microphone", "capturing"),
          "microphonePermission",
          "granted"
        )
      );
      this.startLevelMeter(micResult.stream, "microphone", this.onLevel || undefined);
      this.clearMicrophoneRecoveryTimer();

      const label = await this.resolveMicrophoneLabel(micResult.stream, micResult.devices);
      if (this.onTranscript) {
        this.onTranscript(`[Mic recovered: ${label}]`, true);
      }
    } catch (err) {
      const micError = err instanceof MicrophoneStartupError
        ? err
        : new MicrophoneStartupError(
          "access-failed",
          err instanceof Error ? err.message : String(err),
          { cause: err }
        );
      this.updateDiagnostics((current) =>
        updateRecordingDiagnosticSource(
          updateRecordingDiagnosticPermission(
            current,
            "microphonePermission",
            micError.kind === "permission-denied" ? "denied" : current.microphonePermission
          ),
          "microphone",
          "unavailable",
          micError.kind === "permission-denied"
            ? micError.message
            : `${micError.message}; retrying while tab audio records`
        )
      );
      if (micError.kind === "permission-denied") {
        this.clearMicrophoneRecoveryTimer();
      }
    } finally {
      this.micRecoveryInFlight = false;
    }
  }

  private async resolveMicrophoneLabel(stream: MediaStream, devices: MediaDeviceInfo[] = []): Promise<string> {
    const activeTrack = stream.getAudioTracks()[0];
    const settings = activeTrack?.getSettings?.();
    const allDevices = devices.length > 0 ? devices : await enumerateAudioInputDevices(navigator.mediaDevices).catch(() => []);
    const match = allDevices.find((device) => device.deviceId === settings?.deviceId);
    this.activeMicLabel = match?.label || activeTrack?.label || "unknown mic";
    return this.activeMicLabel;
  }

  private updateDiagnostics(update: (current: RecordingDiagnostics) => RecordingDiagnostics): void {
    this.diagnostics = update(this.diagnostics);
    this.emitDiagnostics();
  }

  private emitDiagnostics(): void {
    this.onDiagnostics?.(this.diagnostics);
  }

  private writeDiagnosticsLog(event: string): void {
    console.info(`[NoteAI] Recording diagnostics ${event}: ${diagnosticLogLines(this.diagnostics).join(" | ")}`);
  }
}
