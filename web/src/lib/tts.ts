"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { getSetting } from "./db";

export type TTSState = "idle" | "loading" | "playing" | "paused";

export const TTS_VOICES = [
  "alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer",
] as const;
export type TTSVoice = (typeof TTS_VOICES)[number];

const TARGET_CHUNK_CHARS = 250;

function splitIntoChunks(text: string): string[] {
  const sentences = text.match(/[^.!?\n]+[.!?\n]?\s*/g) || [text];
  const chunks: string[] = [];
  let buf = "";

  for (const s of sentences) {
    if (buf.length + s.length > TARGET_CHUNK_CHARS && buf.length > 0) {
      chunks.push(buf.trim());
      buf = "";
    }
    buf += s;
  }
  if (buf.trim()) chunks.push(buf.trim());
  return chunks.length > 0 ? chunks : [text.trim()];
}

async function fetchChunkAudio(
  chunk: string,
  voice: string,
  signal: AbortSignal,
): Promise<Blob> {
  const res = await fetch("/api/tts", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: chunk, voice }),
    signal,
  });

  if (!res.ok) {
    const data = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
    throw new Error(data.error || `TTS failed (${res.status})`);
  }

  return res.blob();
}

export function useTTS() {
  const [state, setState] = useState<TTSState>("idle");
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [voice, setVoice] = useState<TTSVoice>("nova");

  const audioRef = useRef<HTMLAudioElement | null>(null);
  const urlsRef = useRef<string[]>([]);
  const rafRef = useRef<number>(0);
  const abortRef = useRef<AbortController | null>(null);
  const playingRef = useRef(false);

  useEffect(() => {
    getSetting("tts_voice").then((v) => {
      if (v && TTS_VOICES.includes(v as TTSVoice)) setVoice(v as TTSVoice);
    });
  }, []);

  const cleanup = useCallback(() => {
    cancelAnimationFrame(rafRef.current);
    playingRef.current = false;
    abortRef.current?.abort();
    abortRef.current = null;
    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current.removeAttribute("src");
      audioRef.current.load();
      audioRef.current = null;
    }
    for (const u of urlsRef.current) URL.revokeObjectURL(u);
    urlsRef.current = [];
  }, []);

  useEffect(() => cleanup, [cleanup]);

  const stop = useCallback(() => {
    cleanup();
    setState("idle");
    setProgress(0);
  }, [cleanup]);

  const speak = useCallback(
    async (text: string) => {
      stop();
      const trimmed = text.trim();
      if (!trimmed) return;

      setState("loading");
      setError(null);

      try {
        const currentVoice = ((await getSetting("tts_voice")) as TTSVoice) || voice;

        const controller = new AbortController();
        abortRef.current = controller;
        playingRef.current = true;

        const chunks = splitIntoChunks(trimmed);
        const totalChunks = chunks.length;
        const blobCache = new Map<number, Blob>();
        const PREFETCH_AHEAD = 2;

        const prefetch = (idx: number) => {
          for (let i = idx; i < Math.min(idx + PREFETCH_AHEAD, totalChunks); i++) {
            if (!blobCache.has(i)) {
              const promise = fetchChunkAudio(
                chunks[i], currentVoice, controller.signal,
              );
              blobCache.set(i, undefined as unknown as Blob);
              promise.then((b) => blobCache.set(i, b)).catch(() => {});
            }
          }
        };

        const getBlob = async (idx: number): Promise<Blob> => {
          if (blobCache.has(idx) && blobCache.get(idx)) {
            return blobCache.get(idx)!;
          }
          const blob = await fetchChunkAudio(
            chunks[idx], currentVoice, controller.signal,
          );
          blobCache.set(idx, blob);
          return blob;
        };

        prefetch(0);

        for (let i = 0; i < totalChunks; i++) {
          if (!playingRef.current) return;

          const blob = await getBlob(i);
          if (!playingRef.current) return;

          prefetch(i + 1);

          const url = URL.createObjectURL(blob);
          urlsRef.current.push(url);

          await new Promise<void>((resolve, reject) => {
            const audio = new Audio(url);
            audioRef.current = audio;

            const trackProgress = () => {
              if (audio.duration > 0 && isFinite(audio.duration)) {
                const chunkProgress = audio.currentTime / audio.duration;
                setProgress((i + chunkProgress) / totalChunks);
              }
              if (!audio.paused && !audio.ended) {
                rafRef.current = requestAnimationFrame(trackProgress);
              }
            };

            audio.addEventListener("play", () => {
              setState("playing");
              rafRef.current = requestAnimationFrame(trackProgress);
            });

            audio.addEventListener("pause", () => {
              cancelAnimationFrame(rafRef.current);
              if (!audio.ended && playingRef.current) setState("paused");
            });

            audio.addEventListener("ended", () => {
              cancelAnimationFrame(rafRef.current);
              resolve();
            });

            audio.addEventListener("error", () => {
              reject(new Error("Audio playback failed"));
            });

            audio.play().catch(reject);
          });
        }

        setState("idle");
        setProgress(0);
        cleanup();
      } catch (err) {
        if ((err as Error).name === "AbortError") return;
        if (!playingRef.current) return;
        const msg = err instanceof Error ? err.message : "TTS failed";
        setError(msg);
        setState("idle");
      }
    },
    [stop, voice, cleanup],
  );

  const togglePlayPause = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;
    if (audio.paused) {
      audio.play();
    } else {
      audio.pause();
    }
  }, []);

  const dismissError = useCallback(() => setError(null), []);

  return { state, progress, error, voice, speak, stop, togglePlayPause, dismissError };
}
