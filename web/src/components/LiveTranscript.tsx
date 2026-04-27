"use client";

import { useEffect, useRef, useState } from "react";
import { BrainCircuit, Mic, MonitorSpeaker, Square, TriangleAlert } from "lucide-react";
import type { TranscriptSegment, CoachInsight } from "@/lib/types";
import { formatDuration } from "@/lib/hooks";
import CoachPanel from "@/components/CoachPanel";
import {
  emptyRecordingDiagnostics,
  recordingDiagnosticsWarnings,
  type RecordingDiagnostics,
  type RecordingSourceDiagnostic,
} from "@/lib/recording-diagnostics";

const COACH_WIDTH_KEY = "noteai_coach_width";

interface LiveTranscriptProps {
  duration: number;
  segments: TranscriptSegment[];
  interimText: string;
  onStop: () => void;
  capturingTabAudio?: boolean;
  micLevel?: number;
  diagnostics?: RecordingDiagnostics;
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
  diagnostics = emptyRecordingDiagnostics,
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
  const warnings = recordingDiagnosticsWarnings(diagnostics);

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
          <div className="flex items-center gap-2">
            <LevelPill
              label="Mic"
              icon={<Mic className={`h-3.5 w-3.5 ${micLevel > 0.02 ? "text-green-400" : "text-text-tertiary"}`} />}
              diagnostic={{ ...diagnostics.microphone, level: Math.max(diagnostics.microphone.level, micLevel) }}
            />
            <LevelPill
              label="System"
              icon={<MonitorSpeaker className={`h-3.5 w-3.5 ${diagnostics.systemAudio.level > 0.02 ? "text-green-400" : "text-text-tertiary"}`} />}
              diagnostic={diagnostics.systemAudio}
            />
            {warnings.length > 0 && (
              <TriangleAlert
                className="h-4 w-4 text-orange-400"
                aria-label="Recording diagnostics warning"
              />
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
        {warnings.slice(0, 2).map((warning) => (
          <span key={warning} className="text-orange-400">
            {warning}
          </span>
        ))}
        {coachEnabled && coachInsights.length > 0 && (
          <span className="text-accent">{coachInsights.length} insights</span>
        )}
      </div>
    </div>
  );
}

function LevelPill({
  label,
  icon,
  diagnostic,
}: {
  label: string;
  icon: React.ReactNode;
  diagnostic: RecordingSourceDiagnostic;
}) {
  const active = diagnostic.status === "capturing";
  return (
    <div
      className={`flex h-8 items-center gap-1.5 rounded-md border px-2 text-[11px] ${
        active
          ? "border-border bg-hover text-text-secondary"
          : "border-orange-400/30 bg-hover/70 text-text-tertiary"
      }`}
      title={`${label}: ${diagnostic.status}${diagnostic.reason ? ` — ${diagnostic.reason}` : ""}`}
    >
      {icon}
      <span className="font-medium">{label}</span>
      <div className="h-1.5 w-12 overflow-hidden rounded-full bg-border">
        <div
          className={`h-full rounded-full transition-[width] ${
            active ? "bg-green-400" : "bg-text-tertiary"
          }`}
          style={{ width: `${Math.max(4, diagnostic.level * 100)}%` }}
        />
      </div>
    </div>
  );
}

function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}
