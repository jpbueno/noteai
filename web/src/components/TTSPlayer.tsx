"use client";

import { Volume2, Pause, Play, Square, X, Loader2 } from "lucide-react";
import type { TTSState } from "@/lib/tts";

interface TTSPlayerProps {
  state: TTSState;
  progress: number;
  error: string | null;
  voice: string;
  onTogglePlayPause: () => void;
  onStop: () => void;
  onDismissError: () => void;
}

export function TTSPlayer({
  state,
  progress,
  error,
  voice,
  onTogglePlayPause,
  onStop,
  onDismissError,
}: TTSPlayerProps) {
  return (
    <>
      {state !== "idle" && (
        <div className="flex items-center gap-3 px-4 py-2.5 bg-hover rounded-lg mx-4 mb-2">
          {state === "loading" ? (
            <>
              <Loader2 className="w-4 h-4 text-accent animate-spin flex-shrink-0" />
              <span className="text-xs text-text-secondary">
                Generating speech...
              </span>
            </>
          ) : (
            <>
              <button
                onClick={onTogglePlayPause}
                className="flex-shrink-0 text-white hover:text-accent transition-colors"
              >
                {state === "playing" ? (
                  <Pause className="w-4 h-4" />
                ) : (
                  <Play className="w-4 h-4" />
                )}
              </button>

              <div className="flex-1 h-1.5 bg-border rounded-full overflow-hidden">
                <div
                  className="h-full bg-accent rounded-full transition-[width] duration-200"
                  style={{ width: `${Math.min(progress * 100, 100)}%` }}
                />
              </div>

              <span className="text-[11px] text-text-tertiary flex-shrink-0 capitalize">
                {voice}
              </span>
            </>
          )}

          <button
            onClick={onStop}
            className="flex-shrink-0 text-text-tertiary hover:text-text-secondary transition-colors ml-1"
          >
            {state === "loading" ? (
              <X className="w-3.5 h-3.5" />
            ) : (
              <Square className="w-3.5 h-3.5" />
            )}
          </button>
        </div>
      )}

      {error && (
        <div className="flex items-center gap-2 px-4 py-1.5 mx-4 mb-2">
          <span className="text-orange-400 text-xs">⚠</span>
          <span className="text-[11px] text-text-tertiary flex-1 line-clamp-2">
            {error}
          </span>
          <button
            onClick={onDismissError}
            className="text-[11px] text-text-secondary hover:text-text-primary flex-shrink-0"
          >
            Dismiss
          </button>
        </div>
      )}
    </>
  );
}

interface ReadAloudButtonProps {
  state: TTSState;
  onSpeak: () => void;
  onStop: () => void;
}

export function ReadAloudButton({ state, onSpeak, onStop }: ReadAloudButtonProps) {
  const active = state !== "idle";
  return (
    <button
      onClick={active ? onStop : onSpeak}
      className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm transition-colors ${
        active
          ? "bg-orange-500/20 text-orange-400 hover:bg-orange-500/30"
          : "bg-hover hover:bg-selected text-text-secondary"
      }`}
    >
      <Volume2 className="w-3.5 h-3.5" />
      {active ? "Stop" : "Read Aloud"}
    </button>
  );
}
