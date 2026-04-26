"use client";

import { useEffect, useRef, useState } from "react";
import { Mic, Square, BrainCircuit } from "lucide-react";
import type { TranscriptSegment, CoachInsight } from "@/lib/types";
import { formatDuration } from "@/lib/hooks";
import CoachPanel from "@/components/CoachPanel";

const COACH_WIDTH_KEY = "noteai_coach_width";

interface LiveTranscriptProps {
  duration: number;
  segments: TranscriptSegment[];
  interimText: string;
  onStop: () => void;
  capturingTabAudio?: boolean;
  micLevel?: number;
  coachInsights: CoachInsight[];
  coachAnalyzing: boolean;
  coachReplying?: boolean;
  coachEnabled: boolean;
  onToggleCoach: () => void;
  onCoachSendMessage?: (question: string) => void;
}

export default function LiveTranscript({
  duration,
  segments,
  interimText,
  onStop,
  capturingTabAudio,
  micLevel = 0,
  coachInsights,
  coachAnalyzing,
  coachReplying,
  coachEnabled,
  onToggleCoach,
  onCoachSendMessage,
}: LiveTranscriptProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [coachWidth, setCoachWidth] = useState(() => {
    if (typeof window === "undefined") return 300;
    const saved = localStorage.getItem(COACH_WIDTH_KEY);
    if (!saved) return 300;
    const width = parseInt(saved, 10);
    return !isNaN(width) && width >= 220 && width <= 700 ? width : 300;
  });
  const isDraggingRef = useRef(false);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [segments]);

  const coachWidthRef = useRef(coachWidth);
  useEffect(() => {
    coachWidthRef.current = coachWidth;
  }, [coachWidth]);

  const startResize = (e: React.MouseEvent) => {
    e.preventDefault();
    isDraggingRef.current = true;
    const startX = e.clientX;
    const startWidth = coachWidth;
    const onMove = (ev: MouseEvent) => {
      // Drag LEFT (negative dx) expands the panel
      const newWidth = Math.max(220, Math.min(700, startWidth - (ev.clientX - startX)));
      setCoachWidth(newWidth);
    };
    const onUp = () => {
      isDraggingRef.current = false;
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
      localStorage.setItem(COACH_WIDTH_KEY, String(coachWidthRef.current));
    };
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  };

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="flex items-center justify-between px-8 py-4 border-b border-border flex-shrink-0">
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
          {/* Mic level meter */}
          <div className="flex items-center gap-1.5" title="Mic level — bars should move when you speak">
            <Mic className={`w-4 h-4 ${micLevel > 0.02 ? "text-green-400" : "text-text-tertiary"}`} />
            <div className="flex items-end gap-[2px] h-5 w-[70px]">
              {[0.08, 0.18, 0.3, 0.45, 0.6, 0.75].map((threshold, i) => (
                <div
                  key={i}
                  className={`w-[8px] rounded-sm transition-colors ${
                    micLevel >= threshold
                      ? i < 3 ? "bg-green-400" : i < 5 ? "bg-yellow-400" : "bg-red-400"
                      : "bg-border"
                  }`}
                  style={{ height: `${(i + 1) * 15}%` }}
                />
              ))}
            </div>
            {micLevel < 0.02 && (
              <span className="text-[11px] text-orange-400 font-medium">Silent</span>
            )}
          </div>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={onToggleCoach}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
              coachEnabled
                ? "bg-accent/15 text-accent border border-accent/30"
                : "bg-hover text-text-tertiary border border-border hover:text-text-secondary"
            }`}
            title={coachEnabled ? "Disable AI Solutions Architect" : "Enable AI Solutions Architect"}
          >
            <BrainCircuit className="w-3.5 h-3.5" />
            AI Solutions Architect
            {coachInsights.length > 0 && (
              <span className="text-[10px] bg-accent/20 px-1 rounded ml-0.5">
                {coachInsights.length}
              </span>
            )}
          </button>
          <button
            onClick={onStop}
            className="flex items-center gap-2 px-4 py-1.5 rounded-md bg-danger text-white text-sm font-medium hover:bg-danger/80 transition-colors"
          >
            <Square className="w-3.5 h-3.5 fill-white" />
            Stop
          </button>
        </div>
      </div>

      {/* Main content — split pane when coach is enabled */}
      <div className="flex-1 flex overflow-hidden">
        {/* Transcript stream */}
        <div ref={scrollRef} className="flex-1 overflow-y-auto px-8 py-6">
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

        {/* Coach panel — right side */}
        {coachEnabled && (
          <>
            {/* Resize handle */}
            <div
              onMouseDown={startResize}
              className="w-1 cursor-col-resize bg-border hover:bg-accent/40 active:bg-accent/60 flex-shrink-0 transition-colors relative group"
              title="Drag to resize"
            >
              <div className="absolute inset-y-0 -left-1 -right-1" />
            </div>
            <div className="flex-shrink-0 bg-sidebar" style={{ width: coachWidth }}>
              <CoachPanel
                insights={coachInsights}
                isAnalyzing={coachAnalyzing}
                isReplying={coachReplying}
                onSendMessage={onCoachSendMessage}
              />
            </div>
          </>
        )}
      </div>

      {/* Footer stats */}
      <div className="px-8 py-2.5 border-t border-border flex items-center gap-6 text-xs text-text-tertiary flex-shrink-0">
        <span>{segments.length} segments</span>
        <span>{formatDuration(duration)}</span>
        {capturingTabAudio !== undefined && (
          <span className={capturingTabAudio ? "text-green-500" : "text-orange-400"}>
            {capturingTabAudio ? "Tab audio captured" : "Mic only"}
          </span>
        )}
        {coachEnabled && coachInsights.length > 0 && (
          <span className="text-accent">{coachInsights.length} insights</span>
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
