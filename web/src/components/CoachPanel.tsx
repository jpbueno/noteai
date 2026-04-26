"use client";

import { useEffect, useRef, useState } from "react";
import {
  Lightbulb,
  MessageSquare,
  Code,
  CircleCheck,
  Clock,
  Loader2,
  Send,
  User,
} from "lucide-react";
import BrainHeadIcon from "@/components/BrainHeadIcon";
import type { CoachInsight, CoachInsightType } from "@/lib/types";

const INSIGHT_CONFIG: Record<CoachInsightType, { icon: React.ComponentType<{ className?: string }>; color: string; label: string }> = {
  key_insight: { icon: Lightbulb, color: "border-blue-400 text-blue-400", label: "Insight" },
  talking_point: { icon: MessageSquare, color: "border-green-400 text-green-400", label: "Talking Point" },
  technical_answer: { icon: Code, color: "border-accent text-accent", label: "Technical" },
  action_item: { icon: CircleCheck, color: "border-orange-400 text-orange-400", label: "Action Item" },
  follow_up: { icon: Clock, color: "border-purple-400 text-purple-400", label: "Follow Up" },
};

interface CoachPanelProps {
  insights: CoachInsight[];
  isAnalyzing: boolean;
  isReplying?: boolean;
  onSendMessage?: (question: string) => void;
}

export default function CoachPanel({ insights, isAnalyzing, isReplying = false, onSendMessage }: CoachPanelProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [input, setInput] = useState("");

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [insights.length, isReplying]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const q = input.trim();
    if (!q || !onSendMessage || isReplying) return;
    onSendMessage(q);
    setInput("");
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit(e as unknown as React.FormEvent);
    }
  };

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center gap-2 px-4 py-3 border-b border-border flex-shrink-0">
        <BrainHeadIcon className="w-4 h-4 text-accent" />
        <span className="text-sm font-semibold text-text-primary flex-1">AI Solutions Architect</span>
        {isAnalyzing && (
          <div className="flex items-center gap-1.5 text-xs text-accent">
            <Loader2 className="w-3 h-3 animate-spin" />
            Analyzing...
          </div>
        )}
      </div>

      {/* Messages list */}
      <div ref={scrollRef} className="flex-1 overflow-y-auto px-3 py-3 space-y-2.5">
        {insights.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-12 gap-2 text-center">
            <BrainHeadIcon className="w-8 h-8 text-text-tertiary opacity-50" />
            <p className="text-xs text-text-tertiary">
              AI Solutions Architect will provide real-time insights as the conversation progresses...
            </p>
            {onSendMessage && (
              <p className="text-[11px] text-text-tertiary mt-2 italic">
                Or ask a question below to chat directly.
              </p>
            )}
          </div>
        ) : (
          insights.map((item) => {
            if (item.role === "user") {
              return (
                <div key={item.id} className="flex justify-end animate-in">
                  <div className="flex items-start gap-2 max-w-[90%]">
                    <div className="rounded-lg bg-accent/20 border border-accent/30 px-3 py-2">
                      <p className="text-[13px] text-text-primary leading-snug whitespace-pre-wrap">
                        {item.content}
                      </p>
                    </div>
                    <User className="w-4 h-4 text-accent flex-shrink-0 mt-1" />
                  </div>
                </div>
              );
            }

            if (item.role === "assistant") {
              return (
                <div key={item.id} className="flex justify-start animate-in">
                  <div className="flex items-start gap-2 max-w-[95%]">
                    <BrainHeadIcon className="w-4 h-4 text-accent flex-shrink-0 mt-1" />
                    <div className="rounded-lg bg-hover/60 border border-border px-3 py-2">
                      <p className="text-[13px] text-text-primary leading-snug whitespace-pre-wrap">
                        {item.content}
                      </p>
                    </div>
                  </div>
                </div>
              );
            }

            const config = INSIGHT_CONFIG[item.type] || INSIGHT_CONFIG.key_insight;
            const Icon = config.icon;
            return (
              <div
                key={item.id}
                className={`border-l-[3px] ${config.color.split(" ")[0]} rounded-r-md bg-hover/40 px-3 py-2.5 animate-in`}
              >
                <div className="flex items-center gap-1.5 mb-1">
                  <Icon className={`w-3 h-3 ${config.color.split(" ")[1]}`} />
                  <span className={`text-[10px] font-semibold uppercase tracking-wide ${config.color.split(" ")[1]}`}>
                    {config.label}
                  </span>
                </div>
                <p className="text-[13px] text-text-primary leading-snug">
                  {item.content}
                </p>
              </div>
            );
          })
        )}
        {isReplying && (
          <div className="flex justify-start animate-in">
            <div className="flex items-center gap-2">
              <BrainHeadIcon className="w-4 h-4 text-accent" />
              <div className="rounded-lg bg-hover/60 border border-border px-3 py-2 flex items-center gap-1.5">
                <Loader2 className="w-3 h-3 animate-spin text-accent" />
                <span className="text-xs text-text-tertiary">Thinking...</span>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Chat input */}
      {onSendMessage && (
        <form onSubmit={handleSubmit} className="border-t border-border p-2 flex-shrink-0">
          <div className="flex items-end gap-2 bg-hover rounded-md border border-border focus-within:border-accent transition-colors">
            <textarea
              value={input}
              onChange={(e) => setInput(e.target.value)}
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
              title="Send (Enter)"
            >
              <Send className="w-3.5 h-3.5" />
            </button>
          </div>
        </form>
      )}
    </div>
  );
}
