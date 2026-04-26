"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import type { TranscriptSegment, CoachInsight } from "./types";
import { analyzeTranscriptLive, askAISA } from "./ai";

const MIN_WORDS = 25;
const MIN_NEW_SEGMENTS = 2;
const MIN_INTERVAL_MS = 45_000;
const CHECK_INTERVAL_MS = 8_000;

export function useAICoach(
  segments: TranscriptSegment[],
  isRecording: boolean,
) {
  const [insights, setInsights] = useState<CoachInsight[]>([]);
  const [isAnalyzing, setIsAnalyzing] = useState(false);
  const [isReplying, setIsReplying] = useState(false);
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

    // Need enough new content AND enough time elapsed — be strict
    if (lastAnalyzedTime.current > 0) {
      if (timeSinceLast < MIN_INTERVAL_MS) return;
      if (newSegsSinceLast < MIN_NEW_SEGMENTS && timeSinceLast < 90_000) return;
    }

    analyzingRef.current = true;
    setIsAnalyzing(true);

    try {
      const previousContents = insightsRef.current.map((i) => i.content);
      console.log(`[AI Coach] Analyzing — ${wordCount} words, ${previousContents.length} prior insights`);
      const newInsights = await analyzeTranscriptLive(fullText, previousContents);
      console.log(`[AI Coach] Got ${newInsights.length} new insight(s)`);

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

  // Send an interactive message to the AI SA
  const sendMessage = useCallback(async (question: string) => {
    const trimmed = question.trim();
    if (!trimmed || isReplying) return;

    const userMsg: CoachInsight = {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      type: "key_insight",
      content: trimmed,
      role: "user",
    };
    setInsights((prev) => [...prev, userMsg]);
    setIsReplying(true);

    try {
      const segs = segmentsRef.current;
      const transcript = segs.map((s) => s.text).join(" ");
      const all = insightsRef.current;
      const chatHistory = all
        .filter((m) => m.role === "user" || m.role === "assistant")
        .map((m) => ({ role: m.role as "user" | "assistant", content: m.content }));
      const priorInsights = all
        .filter((m) => !m.role)
        .map((m) => m.content);

      const reply = await askAISA(trimmed, transcript, chatHistory, priorInsights);

      if (mountedRef.current && reply.trim()) {
        const assistantMsg: CoachInsight = {
          id: crypto.randomUUID(),
          timestamp: new Date().toISOString(),
          type: "key_insight",
          content: reply.trim(),
          role: "assistant",
        };
        setInsights((prev) => [...prev, assistantMsg]);
      }
    } catch (err) {
      console.warn("[AI SA] Reply failed:", err);
      if (mountedRef.current) {
        const errorMsg: CoachInsight = {
          id: crypto.randomUUID(),
          timestamp: new Date().toISOString(),
          type: "key_insight",
          content: `Reply failed: ${err instanceof Error ? err.message : "unknown error"}`,
          role: "assistant",
        };
        setInsights((prev) => [...prev, errorMsg]);
      }
    } finally {
      if (mountedRef.current) setIsReplying(false);
    }
  }, [isReplying]);

  return { insights, isAnalyzing, isReplying, enabled, setEnabled, sendMessage };
}
