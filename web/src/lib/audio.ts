export type RecordingState = "idle" | "recording" | "processing";

type TranscriptCallback = (text: string, isFinal: boolean) => void;
type LevelCallback = (level: number) => void;

/* eslint-disable @typescript-eslint/no-explicit-any */
type SpeechRecognitionInstance = any;
/* eslint-enable @typescript-eslint/no-explicit-any */

async function whisperTranscribe(blob: Blob, prompt?: string, signal?: AbortSignal): Promise<string> {
  const formData = new FormData();
  formData.append("file", blob, "chunk.webm");
  if (prompt) formData.append("prompt", prompt);
  const res = await fetch("/api/transcribe", { method: "POST", body: formData, signal });
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
  private whisperOversizeNotified = false;
  private whisperDisabled = false;
  private whisperFailureCount = 0;
  private lastResultTime = 0;
  private micDeviceId: string | undefined;
  private systemStream: MediaStream | null = null;
  private micSourceNode: MediaStreamAudioSourceNode | null = null;
  private deviceChangeHandler: (() => void) | null = null;
  private levelAnalyser: AnalyserNode | null = null;
  private levelCtx: AudioContext | null = null;
  private levelRafId: number = 0;
  private onLevel: LevelCallback | null = null;
  private activeMicLabel: string = "";

  /**
   * @param onTranscript - callback for live transcript segments
   * @param micDeviceId - specific mic device ID (or undefined for default)
   * @param captureTab - if true, prompt user to share a tab for system audio capture
   * @param onLevel - optional callback for mic level (0-1) — useful for UI meters
   */
  async start(onTranscript?: TranscriptCallback, micDeviceId?: string, captureTab = false, onLevel?: LevelCallback): Promise<void> {
    this.onLevel = onLevel || null;
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

    // 1. Get mic permission first so enumerateDevices() returns labels.
    //    If the requested device is gone (stale ID), fall back to default mic.
    let micStream: MediaStream;
    const tryGetMic = async (constraints: MediaStreamConstraints): Promise<MediaStream> => {
      return navigator.mediaDevices.getUserMedia(constraints);
    };

    // Try multiple approaches to get mic access
    const attempts: { constraints: MediaStreamConstraints; label: string }[] = [
      ...(micDeviceId
        ? [{ constraints: { audio: { deviceId: { exact: micDeviceId } } } as MediaStreamConstraints, label: "requested device" }]
        : []),
      { constraints: { audio: true }, label: "default audio" },
      { constraints: { audio: { echoCancellation: true, noiseSuppression: true } }, label: "with processing" },
      { constraints: { audio: { sampleRate: 44100 } }, label: "explicit sample rate" },
    ];

    let lastErr: unknown = null;
    for (const attempt of attempts) {
      try {
        micStream = await tryGetMic(attempt.constraints);
        break;
      } catch (err) {
        lastErr = err;
        // If permission denied, no point retrying with different constraints
        if (err instanceof DOMException && err.name === "NotAllowedError") break;
      }
    }

    if (!micStream!) {
      const errName = lastErr instanceof DOMException ? lastErr.name : "";
      const errMsg = lastErr instanceof Error ? lastErr.message : String(lastErr);

      if (errName === "NotAllowedError") {
        throw new Error(
          "Microphone permission denied.\n\n" +
          "1. Click the lock/tune icon in Chrome's address bar → Microphone → Allow\n" +
          "2. macOS: System Settings → Privacy & Security → Microphone → Chrome ON\n" +
          "3. Reload this page"
        );
      }

      // Check devices for diagnostics
      let mics: MediaDeviceInfo[] = [];
      try {
        const devices = await navigator.mediaDevices.enumerateDevices();
        mics = devices.filter((d) => d.kind === "audioinput");
      } catch { /* ignore */ }

      if (mics.length === 0) {
        throw new Error(
          "Chrome cannot see any microphones.\n\n" +
          "Fix: Quit Chrome completely (Cmd+Q), then relaunch it.\n\n" +
          "If that doesn't work:\n" +
          "• macOS System Settings → Privacy & Security → Microphone → toggle Chrome OFF then ON\n" +
          "• Relaunch Chrome"
        );
      }

      throw new Error(
        `Mic access failed: ${errName || errMsg}\n\n` +
        `${mics.length} mic(s) detected: ${mics.map((m) => m.label || "unnamed").join(", ")}\n\n` +
        "Try: Quit Chrome (Cmd+Q) and relaunch, or click lock icon → Microphone → Allow."
      );
    }
    this.micStream = micStream;

    // Diagnostics: figure out which mic we actually got
    try {
      const activeTrack = micStream.getAudioTracks()[0];
      const settings = activeTrack?.getSettings?.();
      const allDevices = await navigator.mediaDevices.enumerateDevices();
      const match = allDevices.find((d) => d.deviceId === settings?.deviceId);
      this.activeMicLabel = match?.label || activeTrack?.label || "unknown mic";
      if (this.onTranscript) {
        this.onTranscript(`[Mic active: ${this.activeMicLabel}]`, true);
      }
    } catch { /* ignore */ }

    // Set up level monitoring — always runs so the UI can show audio presence
    if (this.onLevel) {
      try {
        const levelCtx = new AudioContext();
        const source = levelCtx.createMediaStreamSource(micStream);
        const analyser = levelCtx.createAnalyser();
        analyser.fftSize = 512;
        analyser.smoothingTimeConstant = 0.4;
        source.connect(analyser);
        this.levelCtx = levelCtx;
        this.levelAnalyser = analyser;

        const data = new Uint8Array(analyser.frequencyBinCount);
        const tick = () => {
          if (this.stopped || !this.levelAnalyser) return;
          this.levelAnalyser.getByteTimeDomainData(data);
          // Compute RMS around 128 (silent center)
          let sumSq = 0;
          for (let i = 0; i < data.length; i++) {
            const v = (data[i] - 128) / 128;
            sumSq += v * v;
          }
          const rms = Math.sqrt(sumSq / data.length);
          // Normalize roughly — human speech typically ~0.05-0.3 RMS
          const level = Math.min(1, rms * 4);
          if (this.onLevel) this.onLevel(level);
          this.levelRafId = requestAnimationFrame(tick);
        };
        tick();
      } catch (err) {
        console.warn("[NoteAI] Level meter setup failed:", err);
      }
    }

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
    // Only poll Whisper when we have system/tab audio (both speakers).
    // With mic-only, SpeechRecognition is sufficient and Whisper would
    // just produce duplicates.
    if (!this.hasTabAudio) return;

    // First poll after 10s, then every 15s
    setTimeout(() => {
      if (!this.stopped) this.sendToWhisper();
    }, 10000);
    if (this.workerTimer) {
      this.whisperId = this.workerTimer.setInterval(() => {
        if (!this.stopped) this.sendToWhisper();
      }, 15000);
    }
  }

  private async sendToWhisper(): Promise<void> {
    if (this.whisperBusy || this.chunks.length === 0) return;
    if (this.chunks.length <= this.lastWhisperChunkCount) return;

    this.whisperBusy = true;
    this.lastWhisperChunkCount = this.chunks.length;

    // Hard timeout so a hung upstream can't deadlock future polls. Without this,
    // a single stuck fetch freezes all subsequent transcription — and since
    // SpeechRecognition finals are dropped while Whisper is active, the UI
    // stops updating entirely.
    const controller = new AbortController();
    const timeoutHandle = setTimeout(() => controller.abort(), 45000);

    try {
      // Always send the full recording from chunk 0 — webm container headers live
      // in the first chunk and later chunks are not valid standalone files.
      // The deduplication logic below strips already-transcribed text.
      const blob = new Blob(this.chunks, { type: "audio/webm" });

      // Whisper API file size limit is 25 MB. For long recordings we eventually
      // exceed this. When we do, skip this poll — SpeechRecognition still runs
      // in the background for fresh content.
      const WHISPER_MAX_BYTES = 24 * 1024 * 1024; // 24 MB safety margin
      if (blob.size > WHISPER_MAX_BYTES) {
        console.warn(`[NoteAI] Whisper blob too large (${(blob.size / 1024 / 1024).toFixed(1)} MB) — disabling Whisper polling`);
        this.whisperDisabled = true; // Let SpeechRecognition emit finals from now on
        if (this.onTranscript && !this.whisperOversizeNotified) {
          this.whisperOversizeNotified = true;
          this.onTranscript("[Recording long — switched to mic-only transcription for remainder]", true);
        }
        return;
      }

      // Use last transcription as prompt context to maintain coherence
      const promptContext = this.lastWhisperText.slice(-150) || undefined;

      const text = await whisperTranscribe(blob, promptContext, controller.signal);
      console.log(`[NoteAI] Whisper poll OK — ${text.length} chars returned`);
      this.whisperFailureCount = 0;

      if (text && this.onTranscript) {
        // Whisper returns the FULL cumulative transcript each poll.
        // Extract only the NEW text appended since last call.
        const newTail = this.extractNewTranscriptTail(text.trim());
        this.lastWhisperText = text.trim();

        if (newTail) {
          this.onTranscript(newTail, true);
        }
      }
    } catch (err) {
      this.whisperFailureCount++;
      console.warn(`[NoteAI] Whisper poll failed (${this.whisperFailureCount}):`, err);

      // After repeated failures, assume Whisper is unreachable and let
      // SpeechRecognition take over finals for the rest of the recording.
      // Better to lose remote audio than lose everything.
      if (this.whisperFailureCount >= 3) {
        this.whisperDisabled = true;
        if (this.onTranscript && !this.whisperOversizeNotified) {
          this.whisperOversizeNotified = true;
          this.onTranscript("[Whisper unavailable — switched to mic-only transcription for remainder]", true);
        }
      }
    } finally {
      clearTimeout(timeoutHandle);
      // CRITICAL: always reset this flag, otherwise future polls deadlock
      this.whisperBusy = false;
    }
  }

  /**
   * Given a fresh cumulative Whisper transcript, return only the portion that
   * was NOT already present in lastWhisperText. Whisper always returns the full
   * cumulative text, so we need to find the overlap and emit only new content.
   *
   * Strategy: find a tail of the old transcript (progressively shorter) within
   * the new transcript using substring search on a normalized form. Once found,
   * everything after it in the new text is the "new tail" to emit.
   *
   * If no tail match is found (Whisper heavily re-interpreted), fall back to
   * emitting the last N words, where N is the word-count delta.
   *
   * Returns the new tail in original casing, or '' if there's genuinely nothing new.
   */
  private extractNewTranscriptTail(fullText: string): string {
    if (!this.lastWhisperText.trim()) return fullText;

    const norm = (s: string) =>
      s.toLowerCase().replace(/[^\w\s]/g, " ").replace(/\s+/g, " ").trim();

    const oldN = norm(this.lastWhisperText);
    const newN = norm(fullText);

    // Nothing new — new transcript is shorter/equal to old in normalized form
    if (!newN || newN.length <= oldN.length) return "";

    const oldNormWords = oldN.split(" ").filter(Boolean);
    const newOrigWords = fullText.split(/\s+/).filter(Boolean);

    // Try progressively shorter tails of old text to find in new text.
    // Start long so we get precise matches; fall back to shorter if needed.
    for (let tailN = Math.min(20, oldNormWords.length); tailN >= 3; tailN -= 2) {
      const tailPhrase = oldNormWords.slice(-tailN).join(" ");
      if (!tailPhrase) continue;
      const idx = newN.lastIndexOf(tailPhrase);
      if (idx !== -1) {
        // Count normalized words up to and including the found tail
        const endCharPos = idx + tailPhrase.length;
        const prefixWordCount = newN
          .slice(0, endCharPos)
          .split(" ")
          .filter(Boolean).length;
        return newOrigWords.slice(prefixWordCount).join(" ").trim();
      }
    }

    // Fallback: substring match failed (Whisper heavily re-worded earlier content).
    // Emit the last N words where N = word-count delta between new and old.
    // This may double-emit a few words but avoids losing new content entirely.
    const oldWordCount = oldNormWords.length;
    const newWordCount = newOrigWords.length;
    const delta = newWordCount - oldWordCount;
    if (delta > 0 && delta < newWordCount) {
      return newOrigWords.slice(-delta).join(" ").trim();
    }

    return "";
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
    if (this.levelRafId) { cancelAnimationFrame(this.levelRafId); this.levelRafId = 0; }
    if (this.levelCtx) { this.levelCtx.close().catch(() => {}); this.levelCtx = null; }
    this.levelAnalyser = null;
    this.micSourceNode = null;
    this.onTranscript = null;
    this.onLevel = null;
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
