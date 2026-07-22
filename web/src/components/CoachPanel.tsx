"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import {
  CircleCheck,
  Clock,
  Code,
  History,
  Lightbulb,
  Loader2,
  LocateFixed,
  MessageSquare,
  MessagesSquare,
  Pin,
  PinOff,
  RotateCcw,
  Send,
  User,
  X,
} from "lucide-react";
import BrainHeadIcon from "@/components/BrainHeadIcon";
import { coachPolicy } from "@/lib/ai-coach-policy";
import type {
  CoachInsight,
  CoachInsightLifecycle,
  CoachInsightType,
} from "@/lib/types";

const INSIGHT_CONFIG: Record<
  CoachInsightType,
  {
    icon: React.ComponentType<{ className?: string }>;
    color: string;
    label: string;
  }
> = {
  key_insight: { icon: Lightbulb, color: "border-blue-400 text-blue-400", label: "Insight" },
  talking_point: { icon: MessageSquare, color: "border-green-400 text-green-400", label: "Talking Point" },
  technical_answer: { icon: Code, color: "border-accent text-accent", label: "Technical" },
  action_item: { icon: CircleCheck, color: "border-orange-400 text-orange-400", label: "Action Item" },
  follow_up: { icon: Clock, color: "border-purple-400 text-purple-400", label: "Follow Up" },
};

type CoachView = "active" | "history" | "chat";

interface CoachPanelProps {
  insights: Array<CoachInsight & {
    onLifecycleChange?: (lifecycle: CoachInsightLifecycle) => void;
  }>;
  isAnalyzing: boolean;
  isReplying?: boolean;
  onSendMessage?: (question: string) => void;
  onSelectSource?: (segmentID: number) => void;
}

export default function CoachPanel({
  insights,
  isAnalyzing,
  isReplying = false,
  onSendMessage,
  onSelectSource,
}: CoachPanelProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [input, setInput] = useState("");
  const [view, setView] = useState<CoachView>("active");
  const [lifecycleOverrides, setLifecycleOverrides] = useState<
    Record<string, CoachInsightLifecycle>
  >({});
  const [pinnedIDs, setPinnedIDs] = useState<Set<string>>(() => new Set());

  const effectiveInsights = useMemo(
    () => insights.map((item) => {
      const lifecycle = lifecycleOverrides[item.id];
      return lifecycle ? { ...item, lifecycle } : item;
    }),
    [insights, lifecycleOverrides],
  );
  const groups = coachPolicy.partitionPresentation(effectiveInsights);
  const activeInsights = [...groups.activeAutoInsights].sort(
    (left, right) => Number(pinnedIDs.has(right.id)) - Number(pinnedIDs.has(left.id)),
  );
  const visibleCount = view === "active"
    ? activeInsights.length
    : view === "history"
      ? groups.history.length
      : groups.chatMessages.length;

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [visibleCount, view, isReplying]);

  const setLifecycle = (item: CoachInsight & {
    onLifecycleChange?: (lifecycle: CoachInsightLifecycle) => void;
  }, lifecycle: CoachInsightLifecycle) => {
    item.onLifecycleChange?.(lifecycle);
    setLifecycleOverrides((previous) => ({ ...previous, [item.id]: lifecycle }));
    if (lifecycle !== "active") {
      setPinnedIDs((previous) => {
        const next = new Set(previous);
        next.delete(item.id);
        return next;
      });
    }
  };

  const togglePin = (id: string) => {
    setPinnedIDs((previous) => {
      const next = new Set(previous);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault();
    const question = input.trim();
    if (!question || !onSendMessage || isReplying) return;
    setView("chat");
    onSendMessage(question);
    setInput("");
  };

  const handleKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      handleSubmit(event as unknown as React.FormEvent);
    }
  };

  const renderAutomaticInsight = (item: CoachInsight, history = false) => {
    const config = INSIGHT_CONFIG[item.type] || INSIGHT_CONFIG.key_insight;
    const Icon = config.icon;
    const pinned = pinnedIDs.has(item.id);
    return (
      <div
        key={item.id}
        className={`border-l-[3px] ${config.color.split(" ")[0]} rounded-r-md bg-hover/40 px-3 py-2.5 animate-in`}
      >
        <div className="flex items-center gap-1.5 mb-1">
          <Icon className={`w-3 h-3 ${config.color.split(" ")[1]}`} />
          <span className={`text-[10px] font-semibold uppercase ${config.color.split(" ")[1]}`}>
            {config.label}
          </span>
          {history && (
            <span className="text-[10px] text-text-tertiary capitalize">
              {item.lifecycle}
            </span>
          )}
          <span className="flex-1" />
          {history ? (
            <button
              type="button"
              onClick={() => setLifecycle(item, "active")}
              className="coach-icon-button"
              aria-label="Restore insight"
              title="Restore insight"
            >
              <RotateCcw className="w-3.5 h-3.5" />
            </button>
          ) : (
            <>
              {pinned ? (
                <button
                  type="button"
                  onClick={() => togglePin(item.id)}
                  className="coach-icon-button text-accent"
                  aria-label="Unpin insight"
                  title="Unpin insight"
                >
                  <PinOff className="w-3.5 h-3.5" />
                </button>
              ) : (
                <button
                  type="button"
                  onClick={() => togglePin(item.id)}
                  className="coach-icon-button"
                  aria-label="Pin insight"
                  title="Pin insight"
                >
                  <Pin className="w-3.5 h-3.5" />
                </button>
              )}
              <button
                type="button"
                onClick={() => setLifecycle(item, "resolved")}
                className="coach-icon-button"
                aria-label="Resolve insight"
                title="Resolve insight"
              >
                <CircleCheck className="w-3.5 h-3.5" />
              </button>
              <button
                type="button"
                onClick={() => setLifecycle(item, "dismissed")}
                className="coach-icon-button"
                aria-label="Dismiss insight"
                title="Dismiss insight"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            </>
          )}
        </div>
        <p className="text-[13px] text-text-primary leading-snug">
          {item.content}
        </p>
        {item.evidence && item.evidence.length > 0 && (
          <div className="flex flex-wrap gap-1 mt-2">
            {item.evidence.map((evidence, index) => (
              <button
                key={`${item.id}-${evidence.segmentId}`}
                type="button"
                onClick={() => onSelectSource?.(evidence.segmentId)}
                className="inline-flex items-center gap-1 rounded border border-border px-1.5 py-1 text-[10px] text-text-secondary hover:border-accent/50 hover:text-accent transition-colors"
                title={`Show transcript source ${evidence.segmentId}`}
              >
                <LocateFixed className="w-3 h-3" />
                Source {index + 1}
              </button>
            ))}
          </div>
        )}
      </div>
    );
  };

  const renderChatMessage = (item: CoachInsight) => {
    if (item.role === "user") {
      return (
        <div key={item.id} className="flex justify-end animate-in">
          <div className="flex items-start gap-2 max-w-[90%]">
            <div className="rounded-md bg-accent/20 border border-accent/30 px-3 py-2">
              <p className="text-[13px] text-text-primary leading-snug whitespace-pre-wrap">
                {item.content}
              </p>
            </div>
            <User className="w-4 h-4 text-accent flex-shrink-0 mt-1" />
          </div>
        </div>
      );
    }

    return (
      <div key={item.id} className="flex justify-start animate-in">
        <div className="flex items-start gap-2 max-w-[95%]">
          <BrainHeadIcon className="w-4 h-4 text-accent flex-shrink-0 mt-1" />
          <div className="rounded-md bg-hover/60 border border-border px-3 py-2">
            <p className="text-[13px] text-text-primary leading-snug whitespace-pre-wrap">
              {item.content}
            </p>
          </div>
        </div>
      </div>
    );
  };

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center gap-2 px-4 py-3 border-b border-border flex-shrink-0">
        <BrainHeadIcon className="w-4 h-4 text-accent" />
        <span className="text-sm font-semibold text-text-primary flex-1">
          AI Solutions Architect
        </span>
        {isAnalyzing && (
          <div className="flex items-center gap-1.5 text-xs text-accent">
            <Loader2 className="w-3 h-3 animate-spin" />
            Analyzing...
          </div>
        )}
      </div>

      <div className="grid grid-cols-3 gap-1 p-2 border-b border-border" role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={view === "active"}
          onClick={() => setView("active")}
          className={`coach-view-tab ${view === "active" ? "coach-view-tab-active" : ""}`}
        >
          <Lightbulb className="w-3 h-3" />
          <span>Active</span>
          <span className="text-[10px]">{activeInsights.length}</span>
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={view === "history"}
          onClick={() => setView("history")}
          className={`coach-view-tab ${view === "history" ? "coach-view-tab-active" : ""}`}
        >
          <History className="w-3 h-3" />
          <span>History</span>
          <span className="text-[10px]">{groups.history.length}</span>
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={view === "chat"}
          onClick={() => setView("chat")}
          className={`coach-view-tab ${view === "chat" ? "coach-view-tab-active" : ""}`}
        >
          <MessagesSquare className="w-3 h-3" />
          <span>Chat</span>
          <span className="text-[10px]">{groups.chatMessages.length}</span>
        </button>
      </div>

      <div ref={scrollRef} className="flex-1 overflow-y-auto px-3 py-3 space-y-2.5">
        {view === "active" && activeInsights.map((item) => renderAutomaticInsight(item))}
        {view === "history" && groups.history.map((item) => renderAutomaticInsight(item, true))}
        {view === "chat" && groups.chatMessages.map(renderChatMessage)}

        {visibleCount === 0 && !isReplying && (
          <div className="flex flex-col items-center justify-center py-12 gap-2 text-center">
            {view === "chat" ? (
              <MessagesSquare className="w-7 h-7 text-text-tertiary opacity-50" />
            ) : (
              <BrainHeadIcon className="w-8 h-8 text-text-tertiary opacity-50" />
            )}
            <p className="text-xs text-text-tertiary">
              {view === "active"
                ? "No active insights"
                : view === "history"
                  ? "No insight history"
                  : "No chat messages"}
            </p>
          </div>
        )}

        {view === "chat" && isReplying && (
          <div className="flex justify-start animate-in">
            <div className="flex items-center gap-2">
              <BrainHeadIcon className="w-4 h-4 text-accent" />
              <div className="rounded-md bg-hover/60 border border-border px-3 py-2 flex items-center gap-1.5">
                <Loader2 className="w-3 h-3 animate-spin text-accent" />
                <span className="text-xs text-text-tertiary">Thinking...</span>
              </div>
            </div>
          </div>
        )}
      </div>

      {onSendMessage && (
        <form onSubmit={handleSubmit} className="border-t border-border p-2 flex-shrink-0">
          <div className="flex items-end gap-2 bg-hover rounded-md border border-border focus-within:border-accent transition-colors">
            <textarea
              value={input}
              onChange={(event) => setInput(event.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Ask the SA a question..."
              rows={1}
              disabled={isReplying}
              className="flex-1 bg-transparent border-none outline-none text-[13px] text-text-primary placeholder:text-text-tertiary px-3 py-2 resize-none max-h-24 disabled:opacity-50"
              style={{ minHeight: "36px" }}
            />
            <button
              type="submit"
              disabled={!input.trim() || isReplying}
              className="flex items-center justify-center w-8 h-8 mr-1 mb-1 rounded-md bg-accent text-white disabled:opacity-30 disabled:cursor-not-allowed hover:bg-accent/80 transition-colors flex-shrink-0"
              title="Send"
              aria-label="Send message"
            >
              <Send className="w-3.5 h-3.5" />
            </button>
          </div>
        </form>
      )}
    </div>
  );
}
