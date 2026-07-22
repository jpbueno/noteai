"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import type { TranscriptSegment, CoachInsight } from "./types";
import { analyzeTranscriptLive, askAISA } from "./ai";
import { coachPolicy } from "./ai-coach-policy";

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
  const lastFailureTime = useRef(0);
  const analyzingRef = useRef(false);
  const replyingRef = useRef(false);
  const mountedRef = useRef(true);
  const recordingRef = useRef(isRecording);
  const enabledRef = useRef(enabled);
  const sessionVersionRef = useRef(0);
  const analysisAbortRef = useRef<AbortController | null>(null);
  const replyAbortRef = useRef<AbortController | null>(null);
  const segmentsRef = useRef(segments);
  const insightsRef = useRef(insights);
  recordingRef.current = isRecording;
  enabledRef.current = enabled;
  segmentsRef.current = segments;
  insightsRef.current = insights;

  const analyze = useCallback(async () => {
    const segs = segmentsRef.current;
    if (analyzingRef.current || !recordingRef.current || !enabledRef.current) return;
    if (segs.length === 0) return;

    const wordCount = coachPolicy.countTranscriptWords(segs);
    if (wordCount < coachPolicy.cadence.minWords) return;

    const timeSinceFailure = Date.now() - lastFailureTime.current;
    if (
      lastFailureTime.current > 0
      && timeSinceFailure < coachPolicy.cadence.failureRetryMs
    ) return;

    const autoInsights = autoInsightsFrom(insightsRef.current);
    const context = coachPolicy.buildContext({
      segments: segs,
      priorAutoInsights: autoInsights,
    });
    if (coachPolicy.isSessionBudgetExhausted(context)) return;

    const newSegsSinceLast = segs.length - lastAnalyzedCount.current;
    const timeSinceLast = Date.now() - lastAnalyzedTime.current;
    if (lastAnalyzedTime.current > 0) {
      if (timeSinceLast < coachPolicy.cadence.minIntervalMs) return;
      if (
        newSegsSinceLast < coachPolicy.cadence.minNewSegments
        && timeSinceLast < coachPolicy.cadence.sparseUpdateIntervalMs
      ) return;
    }

    const sessionVersion = sessionVersionRef.current;
    const controller = new AbortController();
    analysisAbortRef.current?.abort();
    analysisAbortRef.current = controller;
    analyzingRef.current = true;
    setIsAnalyzing(true);

    try {
      console.log(
        `[AI Coach] Analyzing ${wordCount} words with ${context.transcriptSegments.length} recent segments and ${context.sessionInsightCount} prior auto-insights`,
      );
      const outcome = await analyzeTranscriptLive(context, { signal: controller.signal });
      if (
        !mountedRef.current
        || controller.signal.aborted
        || sessionVersion !== sessionVersionRef.current
        || !recordingRef.current
        || !enabledRef.current
      ) return;

      if (outcome.status === "insights") {
        console.log(
          `[AI Coach] Admitted ${outcome.insights.length} insight(s); rejected ${outcome.rejections.length}`,
        );
        setInsights((previous) => [...previous, ...outcome.insights]);
      } else if (outcome.status === "no_op") {
        console.info("[AI Coach] No-op: no new insight cleared the admission policy");
      } else if (outcome.status === "parse_failure") {
        console.warn(`[AI Coach] Model output parse failure: ${outcome.error}`);
        lastFailureTime.current = Date.now();
        return;
      } else {
        console.info(
          `[AI Coach] Rejected model output: ${outcome.rejections.map((item) => item.reason).join(", ")}`,
        );
      }

      lastAnalyzedCount.current = segs.length;
      lastAnalyzedTime.current = Date.now();
      lastFailureTime.current = 0;
    } catch (error) {
      if (!isAbortError(error)) {
        console.warn("[AI Coach] Analysis failed:", error);
        lastFailureTime.current = Date.now();
      }
    } finally {
      if (analysisAbortRef.current === controller) analysisAbortRef.current = null;
      if (sessionVersion === sessionVersionRef.current) {
        analyzingRef.current = false;
        if (mountedRef.current) setIsAnalyzing(false);
      }
    }
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      analysisAbortRef.current?.abort();
      replyAbortRef.current?.abort();
    };
  }, []);

  useEffect(() => {
    sessionVersionRef.current += 1;
    analysisAbortRef.current?.abort();
    replyAbortRef.current?.abort();
    analysisAbortRef.current = null;
    replyAbortRef.current = null;
    analyzingRef.current = false;
    replyingRef.current = false;
    setIsAnalyzing(false);
    setIsReplying(false);

    if (isRecording) {
      setInsights([]);
      lastAnalyzedCount.current = 0;
      lastAnalyzedTime.current = 0;
      lastFailureTime.current = 0;
    }
  }, [isRecording]);

  useEffect(() => {
    if (enabled) return;
    analysisAbortRef.current?.abort();
    analysisAbortRef.current = null;
    analyzingRef.current = false;
    setIsAnalyzing(false);
  }, [enabled]);

  useEffect(() => {
    if (!isRecording || !enabled) return;

    const interval = setInterval(analyze, coachPolicy.cadence.checkIntervalMs);
    return () => clearInterval(interval);
  }, [isRecording, enabled, analyze]);

  const sendMessage = useCallback(async (question: string) => {
    const trimmed = question.trim();
    if (!trimmed || replyingRef.current) return;

    const streamBeforeQuestion = insightsRef.current;
    const context = coachPolicy.buildContext({
      segments: segmentsRef.current,
      priorAutoInsights: autoInsightsFrom(streamBeforeQuestion),
    });
    const chatHistory = streamBeforeQuestion
      .filter((entry) => entry.role === "user" || entry.role === "assistant")
      .map((entry) => ({
        role: entry.role as "user" | "assistant",
        content: entry.content,
      }));
    const userMessage: CoachInsight = {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      type: "key_insight",
      content: trimmed,
      role: "user",
    };

    setInsights((previous) => [...previous, userMessage]);
    replyingRef.current = true;
    setIsReplying(true);
    const sessionVersion = sessionVersionRef.current;
    const controller = new AbortController();
    replyAbortRef.current?.abort();
    replyAbortRef.current = controller;

    try {
      const reply = await askAISA(trimmed, context, chatHistory, { signal: controller.signal });
      if (
        !mountedRef.current
        || controller.signal.aborted
        || sessionVersion !== sessionVersionRef.current
      ) return;

      const content = reply.trim();
      if (content) {
        const assistantMessage: CoachInsight = {
          id: crypto.randomUUID(),
          timestamp: new Date().toISOString(),
          type: "key_insight",
          content,
          role: "assistant",
        };
        setInsights((previous) => [...previous, assistantMessage]);
      }
    } catch (error) {
      if (!isAbortError(error)) {
        console.warn("[AI SA] Reply failed:", error);
        if (mountedRef.current && sessionVersion === sessionVersionRef.current) {
          const errorMessage: CoachInsight = {
            id: crypto.randomUUID(),
            timestamp: new Date().toISOString(),
            type: "key_insight",
            content: `Reply failed: ${error instanceof Error ? error.message : "unknown error"}`,
            role: "assistant",
          };
          setInsights((previous) => [...previous, errorMessage]);
        }
      }
    } finally {
      if (replyAbortRef.current === controller) replyAbortRef.current = null;
      if (sessionVersion === sessionVersionRef.current) {
        replyingRef.current = false;
        if (mountedRef.current) setIsReplying(false);
      }
    }
  }, []);

  return { insights, isAnalyzing, isReplying, enabled, setEnabled, sendMessage };
}

function autoInsightsFrom(entries: CoachInsight[]): CoachInsight[] {
  return entries.filter((entry) => !entry.role);
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}
