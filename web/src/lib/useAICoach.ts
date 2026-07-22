"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import type { TranscriptSegment, CoachInsight } from "./types";
import { analyzeTranscriptLive, askAISA } from "./ai";
import { coachPolicy } from "./ai-coach-policy";

export function useAICoach(
  segments: TranscriptSegment[],
  isRecording: boolean,
) {
  const [autoInsights, setAutoInsights] = useState<CoachInsight[]>([]);
  const [chatMessages, setChatMessages] = useState<CoachInsight[]>([]);
  const [isAnalyzing, setIsAnalyzing] = useState(false);
  const [isReplying, setIsReplying] = useState(false);
  const [enabled, setEnabled] = useState(true);

  const analyzingRef = useRef(false);
  const replyingRef = useRef(false);
  const mountedRef = useRef(true);
  const recordingRef = useRef(isRecording);
  const enabledRef = useRef(enabled);
  const analysisAbortRef = useRef<AbortController | null>(null);
  const replyAbortRef = useRef<AbortController | null>(null);
  const segmentsRef = useRef(segments);
  const autoInsightsRef = useRef(autoInsights);
  const chatMessagesRef = useRef(chatMessages);
  const cadenceRef = useRef<ReturnType<typeof coachPolicy.createCadenceTracker> | null>(null);
  const sessionScopeRef = useRef<ReturnType<typeof coachPolicy.createRecordingSessionScope> | null>(null);
  if (!cadenceRef.current) cadenceRef.current = coachPolicy.createCadenceTracker();
  if (!sessionScopeRef.current) {
    sessionScopeRef.current = coachPolicy.createRecordingSessionScope(isRecording);
  }
  recordingRef.current = isRecording;
  enabledRef.current = enabled;
  segmentsRef.current = segments;
  autoInsightsRef.current = autoInsights;
  chatMessagesRef.current = chatMessages;

  const insights = coachPolicy.combinePresentation({ autoInsights, chatMessages });

  const analyze = useCallback(async () => {
    const segs = segmentsRef.current;
    if (analyzingRef.current || !recordingRef.current || !enabledRef.current) return;
    if (segs.length === 0) return;

    const wordCount = coachPolicy.countTranscriptWords(segs);
    if (wordCount < coachPolicy.cadence.minWords) return;

    const segmentCount = segs.length;
    if (!cadenceRef.current?.canAnalyze(segmentCount)) return;

    const context = coachPolicy.buildContext({
      segments: segs,
      priorAutoInsights: autoInsightsRef.current,
    });
    if (coachPolicy.isSessionBudgetExhausted(context)) return;

    const sessionToken = sessionScopeRef.current?.capture();
    if (sessionToken === null || sessionToken === undefined) return;
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
        || !sessionScopeRef.current?.canPublish(sessionToken)
        || !recordingRef.current
        || !enabledRef.current
      ) return;

      if (outcome.status === "insights") {
        console.log(
          `[AI Coach] Admitted ${outcome.insights.length} insight(s); rejected ${outcome.rejections.length}`,
        );
        setAutoInsights((previous) => [...previous, ...outcome.insights]);
      } else if (outcome.status === "no_op") {
        console.info("[AI Coach] No-op: no new insight cleared the admission policy");
      } else if (outcome.status === "parse_failure") {
        console.warn(`[AI Coach] Model output parse failure: ${outcome.error}`);
        cadenceRef.current?.fail(segmentCount);
        return;
      } else {
        console.info(
          `[AI Coach] Rejected model output: ${outcome.rejections.map((item) => item.reason).join(", ")}`,
        );
      }

      cadenceRef.current?.complete(segmentCount);
    } catch (error) {
      if (
        !isAbortError(error)
        && sessionScopeRef.current?.canPublish(sessionToken)
        && recordingRef.current
        && enabledRef.current
      ) {
        console.warn("[AI Coach] Analysis failed:", error);
        cadenceRef.current?.fail(segmentCount);
      }
    } finally {
      if (analysisAbortRef.current === controller) analysisAbortRef.current = null;
      if (sessionScopeRef.current?.canPublish(sessionToken)) {
        analyzingRef.current = false;
        if (mountedRef.current) setIsAnalyzing(false);
      }
    }
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      sessionScopeRef.current?.sync(false);
      analysisAbortRef.current?.abort();
      replyAbortRef.current?.abort();
    };
  }, []);

  useEffect(() => {
    sessionScopeRef.current?.sync(isRecording);
    cadenceRef.current?.reset();
    analysisAbortRef.current?.abort();
    replyAbortRef.current?.abort();
    analysisAbortRef.current = null;
    replyAbortRef.current = null;
    analyzingRef.current = false;
    replyingRef.current = false;
    setIsAnalyzing(false);
    setIsReplying(false);

    if (isRecording) {
      setAutoInsights([]);
      setChatMessages([]);
    }
  }, [isRecording]);

  useEffect(() => {
    if (enabled) return;
    analysisAbortRef.current?.abort();
    replyAbortRef.current?.abort();
    analysisAbortRef.current = null;
    replyAbortRef.current = null;
    analyzingRef.current = false;
    replyingRef.current = false;
    setIsAnalyzing(false);
    setIsReplying(false);
  }, [enabled]);

  useEffect(() => {
    if (!isRecording || !enabled) return;

    const interval = setInterval(analyze, coachPolicy.cadence.checkIntervalMs);
    return () => clearInterval(interval);
  }, [isRecording, enabled, analyze]);

  const sendMessage = useCallback(async (question: string) => {
    const trimmed = question.trim();
    if (
      !trimmed
      || replyingRef.current
      || !recordingRef.current
      || !enabledRef.current
    ) return;

    const sessionToken = sessionScopeRef.current?.capture();
    if (sessionToken === null || sessionToken === undefined) return;

    const context = coachPolicy.buildContext({
      segments: segmentsRef.current,
      priorAutoInsights: autoInsightsRef.current,
    });
    const chatHistory = chatMessagesRef.current
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

    setChatMessages((previous) => [...previous, userMessage]);
    replyingRef.current = true;
    setIsReplying(true);
    const controller = new AbortController();
    replyAbortRef.current?.abort();
    replyAbortRef.current = controller;
    const canPublishReply = () => coachPolicy.canPublishReply({
      mounted: mountedRef.current,
      recording: recordingRef.current,
      enabled: enabledRef.current,
      aborted: controller.signal.aborted,
      sessionCurrent: sessionScopeRef.current?.canPublish(sessionToken) ?? false,
    });

    try {
      const reply = await askAISA(trimmed, context, chatHistory, { signal: controller.signal });
      if (!canPublishReply()) return;

      const content = reply.trim();
      if (content) {
        const assistantMessage: CoachInsight = {
          id: crypto.randomUUID(),
          timestamp: new Date().toISOString(),
          type: "key_insight",
          content,
          role: "assistant",
        };
        setChatMessages((previous) => [...previous, assistantMessage]);
      }
    } catch (error) {
      if (!isAbortError(error)) {
        console.warn("[AI SA] Reply failed:", error);
        if (canPublishReply()) {
          const errorMessage: CoachInsight = {
            id: crypto.randomUUID(),
            timestamp: new Date().toISOString(),
            type: "key_insight",
            content: `Reply failed: ${error instanceof Error ? error.message : "unknown error"}`,
            role: "assistant",
          };
          setChatMessages((previous) => [...previous, errorMessage]);
        }
      }
    } finally {
      if (replyAbortRef.current === controller) {
        replyAbortRef.current = null;
        if (canPublishReply()) {
          replyingRef.current = false;
          if (mountedRef.current) setIsReplying(false);
        }
      }
    }
  }, []);

  return {
    insights,
    autoInsights,
    chatMessages,
    isAnalyzing,
    isReplying,
    enabled,
    setEnabled,
    sendMessage,
  };
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}
