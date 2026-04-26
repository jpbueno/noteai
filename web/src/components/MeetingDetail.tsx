"use client";

import { useState } from "react";
import {
  Clock,
  Calendar,
  CheckCircle,
  Circle,
  Copy,
  Download,
  Volume2,
  FileText,
  Sparkles,
  AlignLeft,
} from "lucide-react";
import type { Meeting, ActionItem, SidebarSelection } from "@/lib/types";
import { formatDuration, formatDateTime, triggerRefresh } from "@/lib/hooks";
import { db } from "@/lib/db";
import { useTTS } from "@/lib/tts";
import { TTSPlayer, ReadAloudButton } from "@/components/TTSPlayer";

type Tab = "summary" | "transcript" | "raw";

interface MeetingDetailProps {
  meeting: Meeting;
  onNavigate?: (sel: SidebarSelection) => void;
}

export default function MeetingDetail({ meeting }: MeetingDetailProps) {
  const { summary } = meeting;
  const hasSummary = summary.wasSummarized && !summaryEmpty(summary);
  const [activeTab, setActiveTab] = useState<Tab>(hasSummary ? "summary" : "transcript");
  const tts = useTTS();

  const readableText = hasSummary
    ? [
        ...summary.decisions,
        ...summary.actionItems.map((ai) => ai.task),
        ...summary.topics,
        ...summary.openQuestions,
      ].join(". ")
    : meeting.transcript.map((s) => s.text).join(" ");

  const handleToggleAction = async (actionId: string) => {
    const updated = { ...meeting };
    updated.summary = {
      ...updated.summary,
      actionItems: updated.summary.actionItems.map((ai) =>
        ai.id === actionId ? { ...ai, isCompleted: !ai.isCompleted } : ai
      ),
    };
    await db.meetings.put(updated);
    triggerRefresh();
  };

  const rawText = meeting.transcript.map((s) => s.text).join("\n");

  const copyToClipboard = () => {
    navigator.clipboard.writeText(
      activeTab === "raw" ? rawText : generateMarkdown(meeting)
    );
  };

  const downloadMarkdown = () => {
    const md = generateMarkdown(meeting);
    const blob = new Blob([md], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${meeting.title}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const tabs: { id: Tab; label: string; icon: React.ReactNode }[] = [
    ...(hasSummary
      ? [{ id: "summary" as Tab, label: "Summary", icon: <Sparkles className="w-3.5 h-3.5" /> }]
      : []),
    { id: "transcript", label: "Transcript", icon: <FileText className="w-3.5 h-3.5" /> },
    { id: "raw", label: "Raw", icon: <AlignLeft className="w-3.5 h-3.5" /> },
  ];

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-3xl mx-auto px-12 py-10">
        {/* Title */}
        <h1 className="text-[40px] font-bold text-text-primary mb-3 leading-tight">
          {meeting.title}
        </h1>

        {/* Meta */}
        <div className="flex items-center gap-4 text-sm text-text-secondary mb-6">
          <span className="flex items-center gap-1.5">
            <Calendar className="w-3.5 h-3.5" />
            {formatDateTime(meeting.date)}
          </span>
          <span className="flex items-center gap-1.5">
            <Clock className="w-3.5 h-3.5" />
            {formatDuration(meeting.duration)}
          </span>
          <span className="flex items-center gap-1.5">
            <Volume2 className="w-3.5 h-3.5" />
            {meeting.transcript.length} segments
          </span>
        </div>

        {/* Actions bar */}
        <div className="flex gap-2 mb-6">
          <button
            onClick={copyToClipboard}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-hover hover:bg-selected text-sm text-text-secondary transition-colors"
          >
            <Copy className="w-3.5 h-3.5" />
            Copy
          </button>
          <button
            onClick={downloadMarkdown}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-hover hover:bg-selected text-sm text-text-secondary transition-colors"
          >
            <Download className="w-3.5 h-3.5" />
            Export .md
          </button>
          <ReadAloudButton
            state={tts.state}
            onSpeak={() => tts.speak(readableText)}
            onStop={tts.stop}
          />
        </div>

        <TTSPlayer
          state={tts.state}
          progress={tts.progress}
          error={tts.error}
          voice={tts.voice}
          onTogglePlayPause={tts.togglePlayPause}
          onStop={tts.stop}
          onDismissError={tts.dismissError}
        />

        {/* Tabs */}
        <div className="flex gap-1 mb-6 border-b border-border pb-px">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex items-center gap-1.5 px-3 py-2 text-sm rounded-t-md transition-colors ${
                activeTab === tab.id
                  ? "text-text-primary border-b-2 border-accent -mb-px"
                  : "text-text-tertiary hover:text-text-secondary"
              }`}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </div>

        {/* Tab content */}
        {activeTab === "summary" && hasSummary && (
          <div className="space-y-6">
            {summary.decisions.length > 0 && (
              <SummaryBlock title="Key Decisions" color="text-blue-400">
                <ul className="space-y-1.5">
                  {summary.decisions.map((d, i) => (
                    <li key={i} className="text-[15px] text-text-primary flex items-start gap-2">
                      <span className="text-blue-400 mt-1">•</span>
                      {d}
                    </li>
                  ))}
                </ul>
              </SummaryBlock>
            )}

            {summary.actionItems.length > 0 && (
              <SummaryBlock title="Action Items" color="text-orange-400">
                <ul className="space-y-2">
                  {summary.actionItems.map((ai) => (
                    <ActionItemRow key={ai.id} item={ai} onToggle={() => handleToggleAction(ai.id)} />
                  ))}
                </ul>
              </SummaryBlock>
            )}

            {summary.topics.length > 0 && (
              <SummaryBlock title="Topics Discussed" color="text-green-400">
                <ul className="space-y-1.5">
                  {summary.topics.map((t, i) => (
                    <li key={i} className="text-[15px] text-text-primary flex items-start gap-2">
                      <span className="text-green-400 mt-1">•</span>
                      {t}
                    </li>
                  ))}
                </ul>
              </SummaryBlock>
            )}

            {summary.openQuestions.length > 0 && (
              <SummaryBlock title="Open Questions" color="text-purple-400">
                <ul className="space-y-1.5">
                  {summary.openQuestions.map((q, i) => (
                    <li key={i} className="text-[15px] text-text-primary flex items-start gap-2">
                      <span className="text-purple-400 mt-1">?</span>
                      {q}
                    </li>
                  ))}
                </ul>
              </SummaryBlock>
            )}
          </div>
        )}

        {activeTab === "transcript" && (
          <div className="space-y-3">
            {meeting.transcript.map((seg) => (
              <div key={seg.id} className="flex gap-3">
                <span className="text-xs text-text-tertiary font-mono w-12 pt-0.5 flex-shrink-0 text-right">
                  {seg.startTime > 0 ? formatTimestamp(seg.startTime) : ""}
                </span>
                <div className="flex-1">
                  {seg.speaker && (
                    <span className="text-xs text-accent font-medium mr-2">
                      {seg.speaker}
                    </span>
                  )}
                  <span className="text-[15px] text-text-primary leading-relaxed">
                    {seg.text}
                  </span>
                </div>
              </div>
            ))}
            {meeting.transcript.length === 0 && (
              <p className="text-text-tertiary text-sm py-8 text-center">
                No transcript segments recorded.
              </p>
            )}
          </div>
        )}

        {activeTab === "raw" && (
          <div>
            <div className="flex justify-end mb-2">
              <button
                onClick={() => navigator.clipboard.writeText(rawText)}
                className="flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs text-text-tertiary hover:text-text-secondary hover:bg-hover transition-colors"
              >
                <Copy className="w-3 h-3" />
                Copy raw text
              </button>
            </div>
            <pre className="bg-sidebar border border-border rounded-lg p-4 text-sm text-text-primary font-mono leading-relaxed whitespace-pre-wrap overflow-x-auto select-all">
              {rawText || "[No transcript data]"}
            </pre>
          </div>
        )}

        {!hasSummary && activeTab === "summary" && (
          <div className="text-center py-12">
            <p className="text-text-tertiary text-sm">
              No summary available for this meeting.
            </p>
            <p className="text-text-tertiary text-xs mt-1">
              Configure an API key in Settings to enable summarization.
            </p>
          </div>
        )}

      </div>
    </div>
  );
}

function SummaryBlock({ title, color, children }: { title: string; color: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className={`text-lg font-semibold ${color} mb-3`}>{title}</h3>
      {children}
    </div>
  );
}

function ActionItemRow({ item, onToggle }: { item: ActionItem; onToggle: () => void }) {
  return (
    <li className="flex items-start gap-2">
      <button onClick={onToggle} className="mt-0.5 flex-shrink-0">
        {item.isCompleted ? (
          <CheckCircle className="w-4 h-4 text-green-500" />
        ) : (
          <Circle className="w-4 h-4 text-text-tertiary hover:text-orange-400 transition-colors" />
        )}
      </button>
      <div className="flex-1">
        <span className={`text-[15px] ${item.isCompleted ? "text-text-tertiary line-through" : "text-text-primary"}`}>
          {item.task}
        </span>
        {(item.owner || item.deadline) && (
          <div className="flex gap-3 mt-0.5">
            {item.owner && <span className="text-xs text-text-tertiary">@{item.owner}</span>}
            {item.deadline && <span className="text-xs text-text-tertiary">Due: {item.deadline}</span>}
          </div>
        )}
      </div>
    </li>
  );
}

function summaryEmpty(s: Meeting["summary"]): boolean {
  return s.decisions.length === 0 && s.actionItems.length === 0 && s.topics.length === 0 && s.openQuestions.length === 0;
}

function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function generateMarkdown(meeting: Meeting): string {
  const lines: string[] = [];
  lines.push(`# ${meeting.title}\n`);
  lines.push(`**Date:** ${formatDateTime(meeting.date)}`);
  lines.push(`**Duration:** ${formatDuration(meeting.duration)}\n`);

  const { summary } = meeting;
  if (summary.wasSummarized) {
    lines.push("## Summary\n");
    if (summary.decisions.length > 0) {
      lines.push("### Key Decisions");
      summary.decisions.forEach((d) => lines.push(`- ${d}`));
      lines.push("");
    }
    if (summary.actionItems.length > 0) {
      lines.push("### Action Items");
      summary.actionItems.forEach((ai) => {
        const check = ai.isCompleted ? "x" : " ";
        const meta = [ai.owner && `@${ai.owner}`, ai.deadline && `due ${ai.deadline}`].filter(Boolean).join(", ");
        lines.push(`- [${check}] ${ai.task}${meta ? ` (${meta})` : ""}`);
      });
      lines.push("");
    }
    if (summary.topics.length > 0) {
      lines.push("### Topics");
      summary.topics.forEach((t) => lines.push(`- ${t}`));
      lines.push("");
    }
    if (summary.openQuestions.length > 0) {
      lines.push("### Open Questions");
      summary.openQuestions.forEach((q) => lines.push(`- ${q}`));
      lines.push("");
    }
  }

  lines.push("## Transcript\n");
  meeting.transcript.forEach((seg) => {
    const speaker = seg.speaker ? `**${seg.speaker}:** ` : "";
    const ts = seg.startTime > 0 ? `[${formatTimestamp(seg.startTime)}] ` : "";
    lines.push(`${ts}${speaker}${seg.text}`);
  });

  return lines.join("\n");
}
