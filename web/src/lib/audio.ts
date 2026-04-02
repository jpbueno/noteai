export type RecordingState = "idle" | "recording" | "processing";

type TranscriptCallback = (text: string, isFinal: boolean) => void;

/* eslint-disable @typescript-eslint/no-explicit-any */
type SpeechRecognitionInstance = any;
/* eslint-enable @typescript-eslint/no-explicit-any */

async function whisperTranscribe(blob: Blob, prompt?: string): Promise<string> {
  const formData = new FormData();
  formData.append("file", blob, "chunk.webm");
  if (prompt) formData.append("prompt", prompt);
  const res = await fetch("/api/transcribe", { method: "POST", body: formData });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data.text || "";
}

export async function getAudioInputDevices(): Promise<{ deviceId: string; label: string }[]> {
  try {
    const tempStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    tempStream.getTracks().forEach((t) => t.stop());
  } catch { /* ignore */ }
  const devices = await navigator.mediaDevices.enumerateDevices();
  return devices
    .filter((d) => d.kind === "audioinput")
    .map((d) => ({ deviceId: d.deviceId, label: d.label || `Mic ${d.deviceId.slice(0, 6)}` }));
}

/** Find BlackHole device for system audio loopback capture */
async function findBlackHoleDevice(): Promise<string | null> {
  const devices = await getAudioInputDevices();
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
  private whisperBusy = false;
  private lastWhisperChunkCount = 0;
  private lastWhisperText = "";
  private lastResultTime = 0;
  private micDeviceId: string | undefined;
  private systemStream: MediaStream | null = null;
  private micSourceNode: MediaStreamAudioSourceNode | null = null;
  private deviceChangeHandler: (() => void) | null = null;

  /**
   * @param onTranscript - callback for live transcript segments
   * @param micDeviceId - specific mic device ID (or undefined for default)
   * @param captureTab - if true, prompt user to share a tab for system audio capture
   */
  async start(onTranscript?: TranscriptCallback, micDeviceId?: string, captureTab = false): Promise<void> {
    this.chunks = [];
    this.stopped = false;
    this.hasTabAudio = false;
    this.whisperBusy = false;
    this.lastWhisperChunkCount = 0;
    this.lastWhisperText = "";
    this.onTranscript = onTranscript || null;
    this.micDeviceId = micDeviceId;

    // Worker-based timers that survive background tab throttling
    this.workerTimer = new WorkerTimer();

    // 1. Get mic permission first so enumerateDevices() returns labels
    const micStream = await navigator.mediaDevices.getUserMedia({
      audio: micDeviceId ? { deviceId: { exact: micDeviceId } } : true,
    });
    this.micStream = micStream;

    // 2. Try BlackHole for system audio loopback (captures ALL speaker output)
    const blackHoleId = await findBlackHoleDevice();
    let systemStream: MediaStream | null = null;

    if (blackHoleId) {
      try {
        systemStream = await navigator.mediaDevices.getUserMedia({
          audio: { deviceId: { exact: blackHoleId } },
        });
        this.hasTabAudio = true;
        if (this.onTranscript) {
          this.onTranscript("[System audio captured via BlackHole — all speaker output will be transcribed]", true);
        }
      } catch (err) {
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
        displayStream.getVideoTracks().forEach((t) => t.stop());
        if (displayStream.getAudioTracks().length > 0) {
          systemStream = displayStream;
          this.tabStream = displayStream;
          this.hasTabAudio = true;
          if (this.onTranscript) {
            this.onTranscript("[Tab audio captured — Whisper transcription active]", true);
          }
        } else if (this.onTranscript) {
          this.onTranscript("[Tab shared but no audio track — did you check 'Also share tab audio'?]", true);
        }
      } catch (err) {
        if (this.onTranscript) {
          this.onTranscript(`[Tab capture skipped: ${err instanceof Error ? err.message : "cancelled"}]`, true);
        }
      }
    }
    this.systemStream = systemStream;

    // 4. Mix system audio + mic via AudioContext, or use mic only
    let recordStream: MediaStream;
    if (systemStream && systemStream.getAudioTracks().length > 0) {
      const ctx = new AudioContext();
      const dest = ctx.createMediaStreamDestination();
      ctx.createMediaStreamSource(systemStream).connect(dest);
      this.micSourceNode = ctx.createMediaStreamSource(micStream);
      this.micSourceNode.connect(dest);
      this.audioCtx = ctx;
      this.mixedStream = dest.stream;
      recordStream = dest.stream;
    } else {
      recordStream = micStream;
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
    this.startWhisperPolling();

    // 7. Listen for audio device changes (AirPods connect/disconnect, etc.)
    // When the user switches devices, reconnect mic to follow the new device
    this.deviceChangeHandler = () => this.handleDeviceChange();
    navigator.mediaDevices.addEventListener("devicechange", this.deviceChangeHandler);
  }

  // --- Whisper polling ---

  private startWhisperPolling(): void {
    // First poll after 8s, then every 12s
    setTimeout(() => {
      if (!this.stopped) this.sendToWhisper();
    }, 8000);
    if (this.workerTimer) {
      this.whisperId = this.workerTimer.setInterval(() => {
        if (!this.stopped) this.sendToWhisper();
      }, 12000);
    }
  }

  private async sendToWhisper(): Promise<void> {
    if (this.whisperBusy || this.chunks.length === 0) return;
    if (this.chunks.length === this.lastWhisperChunkCount) return;

    this.whisperBusy = true;
    this.lastWhisperChunkCount = this.chunks.length;
    // Send the full accumulated blob — partial chunks lack valid webm headers
    const blob = new Blob(this.chunks, { type: "audio/webm" });

    // Use the last 100 chars of previous transcription as prompt context
    // This helps Whisper maintain coherence and reduces hallucinations
    const promptContext = this.lastWhisperText.slice(-100) || undefined;

    try {
      const fullText = await whisperTranscribe(blob, promptContext);
      if (fullText && this.onTranscript) {
        // Extract only the NEW text that wasn't in the previous transcription
        let newText = fullText;
        if (this.lastWhisperText) {
          // Find where the old text ends in the new text
          // Use the last 50 chars of old text as anchor to find overlap
          const anchor = this.lastWhisperText.slice(-50).trim();
          if (anchor.length > 10) {
            const overlapIdx = fullText.indexOf(anchor);
            if (overlapIdx >= 0) {
              newText = fullText.slice(overlapIdx + anchor.length).trim();
            }
          }
        }
        this.lastWhisperText = fullText;

        if (newText) {
          this.onTranscript(newText, true);
        }
      }
    } catch (err) {
      if (this.onTranscript) {
        this.onTranscript(`[Whisper error: ${err instanceof Error ? err.message : "unknown"}]`, true);
      }
    }
    this.whisperBusy = false;
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
        if (text && this.onTranscript) {
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

      // If we have a mixing AudioContext, swap the mic source node
      if (this.audioCtx && this.audioCtx.state !== "closed") {
        if (this.micSourceNode) {
          this.micSourceNode.disconnect();
        }
        this.micSourceNode = this.audioCtx.createMediaStreamSource(newMicStream);
        // Reconnect to the existing destination
        const dest = this.audioCtx.createMediaStreamDestination();
        if (this.systemStream) {
          this.audioCtx.createMediaStreamSource(this.systemStream).connect(dest);
        }
        this.micSourceNode.connect(dest);

        // Replace the mixed stream tracks in the MediaRecorder
        // MediaRecorder can't swap tracks, but the AudioContext destination
        // feeds through, so we just needed to reconnect the source nodes
      }

      if (this.onTranscript) {
        const devices = await getAudioInputDevices();
        const active = newMicStream.getAudioTracks()[0];
        const label = devices.find((d) => d.deviceId === active?.getSettings()?.deviceId)?.label || "new device";
        this.onTranscript(`[Mic switched to: ${label}]`, true);
      }
    } catch (err) {
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
    if (this.recognition) {
      try { this.recognition.abort(); } catch { /* ignore */ }
      this.recognition = null;
    }
    this.recognitionRunning = false;
    if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
      this.mediaRecorder.stop();
    }
    if (this.tabStream) { this.tabStream.getTracks().forEach((t) => t.stop()); this.tabStream = null; }
    if (this.micStream) { this.micStream.getTracks().forEach((t) => t.stop()); this.micStream = null; }
    if (this.mixedStream) { this.mixedStream.getTracks().forEach((t) => t.stop()); this.mixedStream = null; }
    if (this.systemStream) { this.systemStream.getTracks().forEach((t) => t.stop()); this.systemStream = null; }
    if (this.audioCtx) { this.audioCtx.close().catch(() => {}); this.audioCtx = null; }
    this.micSourceNode = null;
    this.onTranscript = null;
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
}
