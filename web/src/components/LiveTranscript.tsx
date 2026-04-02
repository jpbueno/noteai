"use client";

import { useEffect, useRef } from "react";
import { Mic, Square } from "lucide-react";
import type { TranscriptSegment } from "@/lib/types";
import { formatDuration } from "@/lib/hooks";

interface LiveTranscriptProps {
  duration: number;
  segments: TranscriptSegment[];
  interimText: string;
  onStop: () => void;
  capturingTabAudio?: boolean;
}

export default function LiveTranscript({
  duration,
  segments,
  interimText,
  onStop,
  capturingTabAudio,
}: LiveTranscriptProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [segments]);

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="flex items-center justify-between px-12 py-6 border-b border-border">
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2">
            <div className="w-3 h-3 rounded-full bg-danger recording-pulse" />
            <span className="text-lg font-semibold text-text-primary">
              Recording
            </span>
          </div>
          <span className="text-2xl font-mono text-danger font-semibold">
            {formatDuration(duration)}
          </span>
        </div>
        <button
          onClick={onStop}
          className="flex items-center gap-2 px-4 py-2 rounded-md bg-danger text-white text-sm font-medium hover:bg-danger/80 transition-colors"
        >
          <Square className="w-3.5 h-3.5 fill-white" />
          Stop Recording
        </button>
      </div>

      {/* Transcript stream */}
      <div ref={scrollRef} className="flex-1 overflow-y-auto px-12 py-8">
        <div className="max-w-3xl">
          {segments.length === 0 && !interimText ? (
            <div className="flex flex-col items-center justify-center py-20 gap-4">
              <div className="relative">
                <Mic className="w-12 h-12 text-text-tertiary" />
                <div className="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-danger recording-pulse" />
              </div>
              <p className="text-text-secondary text-sm">
                {capturingTabAudio
                  ? "Capturing tab audio... Transcript will appear in ~10 seconds."
                  : "Listening... Start speaking and the transcript will appear here in real time."}
              </p>
            </div>
          ) : (
            <div className="space-y-3">
              {segments.map((seg) => (
                <div key={seg.id} className="flex gap-3">
                  <span className="text-xs text-text-tertiary font-mono w-12 pt-0.5 flex-shrink-0 text-right">
                    {formatTimestamp(seg.startTime)}
                  </span>
                  <p className="text-[15px] text-text-primary leading-relaxed">
                    {seg.text}
                  </p>
                </div>
              ))}
              {interimText && (
                <div className="flex gap-3">
                  <span className="text-xs text-text-tertiary font-mono w-12 pt-0.5 flex-shrink-0 text-right">
                    <div className="w-1.5 h-1.5 rounded-full bg-danger recording-pulse ml-auto" />
                  </span>
                  <p className="text-[15px] text-text-secondary leading-relaxed italic">
                    {interimText}
                  </p>
                </div>
              )}
              {!interimText && (
                <div className="flex items-center gap-2 pt-2 pl-[60px]">
                  <div className="w-1.5 h-1.5 rounded-full bg-danger recording-pulse" />
                  <span className="text-xs text-text-tertiary">
                    Listening...
                  </span>
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      {/* Footer stats */}
      <div className="px-12 py-3 border-t border-border flex items-center gap-6 text-xs text-text-tertiary">
        <span>{segments.length} segments transcribed</span>
        <span>Duration: {formatDuration(duration)}</span>
        {capturingTabAudio !== undefined && (
          <span className={capturingTabAudio ? "text-green-500" : "text-orange-400"}>
            {capturingTabAudio ? "Tab audio captured" : "Mic only (no tab shared)"}
          </span>
        )}
      </div>
    </div>
  );
}

function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}
