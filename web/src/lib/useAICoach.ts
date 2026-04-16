"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import type { TranscriptSegment, CoachInsight } from "./types";
import { analyzeTranscriptLive } from "./ai";

const MIN_WORDS = 30;
const MIN_NEW_SEGMENTS = 3;
const MIN_INTERVAL_MS = 25_000;
const CHECK_INTERVAL_MS = 8_000;

export function useAICoach(
  segments: TranscriptSegment[],
  isRecording: boolean,
) {
  const [insights, setInsights] = useState<CoachInsight[]>([]);
  const [isAnalyzing, setIsAnalyzing] = useState(false);
  const [enabled, setEnabled] = useState(true);

  const lastAnalyzedCount = useRef(0);
  const lastAnalyzedTime = useRef(0);
  const analyzingRef = useRef(false);
  const mountedRef = useRef(true);
  const segmentsRef = useRef(segments);
  const insightsRef = useRef(insights);
  segmentsRef.current = segments;
  insightsRef.current = insights;

  const analyze = useCallback(async () => {
    const segs = segmentsRef.current;
    if (analyzingRef.current) return;
    if (segs.length === 0) return;

    const fullText = segs.map((s) => s.text).join(" ");
    const wordCount = fullText.split(/\s+/).length;
    if (wordCount < MIN_WORDS) return;

    const newSegsSinceLast = segs.length - lastAnalyzedCount.current;
    const timeSinceLast = Date.now() - lastAnalyzedTime.current;

    // Need enough new content or enough time elapsed
    if (lastAnalyzedTime.current > 0) {
      if (timeSinceLast < MIN_INTERVAL_MS) return;
      if (newSegsSinceLast < MIN_NEW_SEGMENTS && timeSinceLast < 60_000) return;
    }

    analyzingRef.current = true;
    setIsAnalyzing(true);

    try {
      const previousContents = insightsRef.current.map((i) => i.content);
      const newInsights = await analyzeTranscriptLive(fullText, previousContents);

      if (mountedRef.current && newInsights.length > 0) {
        setInsights((prev) => [...prev, ...newInsights]);
      }

      lastAnalyzedCount.current = segs.length;
      lastAnalyzedTime.current = Date.now();
    } catch (err) {
      console.warn("[AI Coach] Analysis failed:", err);
    } finally {
      analyzingRef.current = false;
      if (mountedRef.current) setIsAnalyzing(false);
    }
  }, []);

  // Periodic check loop
  useEffect(() => {
    if (!isRecording || !enabled) return;

    const interval = setInterval(() => {
      analyze();
    }, CHECK_INTERVAL_MS);

    return () => clearInterval(interval);
  }, [isRecording, enabled, analyze]);

  // Reset when recording starts
  useEffect(() => {
    if (isRecording) {
      setInsights([]);
      lastAnalyzedCount.current = 0;
      lastAnalyzedTime.current = 0;
    }
  }, [isRecording]);

  // Cleanup
  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; };
  }, []);

  return { insights, isAnalyzing, enabled, setEnabled };
}
