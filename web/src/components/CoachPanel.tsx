"use client";

import { useEffect, useRef } from "react";
import {
  Lightbulb,
  MessageSquare,
  Code,
  CircleCheck,
  Clock,
  Loader2,
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
}

export default function CoachPanel({ insights, isAnalyzing }: CoachPanelProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [insights.length]);

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center gap-2 px-4 py-3 border-b border-border flex-shrink-0">
        <BrainHeadIcon className="w-4 h-4 text-accent" />
        <span className="text-sm font-semibold text-text-primary flex-1">AI Coach</span>
        {isAnalyzing && (
          <div className="flex items-center gap-1.5 text-xs text-accent">
            <Loader2 className="w-3 h-3 animate-spin" />
            Analyzing...
          </div>
        )}
      </div>

      {/* Insights list */}
      <div ref={scrollRef} className="flex-1 overflow-y-auto px-3 py-3 space-y-2.5">
        {insights.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-12 gap-2 text-center">
            <BrainHeadIcon className="w-8 h-8 text-text-tertiary opacity-50" />
            <p className="text-xs text-text-tertiary">
              AI coach will provide real-time insights as the conversation progresses...
            </p>
          </div>
        ) : (
          insights.map((insight) => {
            const config = INSIGHT_CONFIG[insight.type] || INSIGHT_CONFIG.key_insight;
            const Icon = config.icon;
            return (
              <div
                key={insight.id}
                className={`border-l-[3px] ${config.color.split(" ")[0]} rounded-r-md bg-hover/40 px-3 py-2.5 animate-in`}
              >
                <div className="flex items-center gap-1.5 mb-1">
                  <Icon className={`w-3 h-3 ${config.color.split(" ")[1]}`} />
                  <span className={`text-[10px] font-semibold uppercase tracking-wide ${config.color.split(" ")[1]}`}>
                    {config.label}
                  </span>
                </div>
                <p className="text-[13px] text-text-primary leading-snug">
                  {insight.content}
                </p>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
