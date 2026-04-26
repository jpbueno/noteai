"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import {
  Plus,
  X,
  Sparkles,
  Loader2,
  Copy,
  Download,
  ChevronDown,
  ChevronRight,
} from "lucide-react";
import type { T5TReport, T5TEntry, Meeting, Note, TaskItem, SidebarSelection } from "@/lib/types";
import { db } from "@/lib/db";
import { formatDate, triggerRefresh } from "@/lib/hooks";
import { chatWithAI } from "@/lib/ai";
import {
  buildT5TContext,
  buildT5TMessages,
  parseT5TSections,
} from "@/lib/ai-tasks";
import { selectedSources } from "@/lib/library";
import { v4 as uuid } from "uuid";

interface T5TComposerProps {
  report: T5TReport;
  meetings: Meeting[];
  notes: Note[];
  tasks: TaskItem[];
  onNavigate?: (sel: SidebarSelection) => void;
}

export default function T5TComposer({
  report,
  meetings,
  notes,
  tasks,
}: T5TComposerProps) {
  const [sections, setSections] = useState(report.sections);
  const [selectedMeetingIDs, setSelectedMeetingIDs] = useState<Set<string>>(new Set(report.meetingIDs));
  const [selectedNoteIDs, setSelectedNoteIDs] = useState<Set<string>>(new Set(report.noteIDs));
  const [selectedTaskIDs, setSelectedTaskIDs] = useState<Set<string>>(new Set(report.taskIDs));
  const [isGenerating, setIsGenerating] = useState(false);
  const [expandedSections, setExpandedSections] = useState<Record<string, boolean>>({
    insights: true,
    accountUpdates: true,
    futurePlans: true,
    sources: true,
  });
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const prevIdRef = useRef(report.id);

  useEffect(() => {
    if (prevIdRef.current !== report.id) {
      setSections(report.sections);
      setSelectedMeetingIDs(new Set(report.meetingIDs));
      setSelectedNoteIDs(new Set(report.noteIDs));
      setSelectedTaskIDs(new Set(report.taskIDs));
      prevIdRef.current = report.id;
    }
  }, [report.id, report.sections, report.meetingIDs, report.noteIDs, report.taskIDs]);

  const save = useCallback(
    (newSections: typeof sections) => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
      saveTimer.current = setTimeout(async () => {
        await db.t5tReports.update(report.id, { sections: newSections });
        triggerRefresh();
      }, 400);
    },
    [report.id]
  );

  const saveSources = useCallback(
    async (mIDs: Set<string>, nIDs: Set<string>, tIDs: Set<string>) => {
      await db.t5tReports.update(report.id, {
        meetingIDs: Array.from(mIDs),
        noteIDs: Array.from(nIDs),
        taskIDs: Array.from(tIDs),
      });
      triggerRefresh();
    },
    [report.id]
  );

  const toggleMeeting = (id: string) => {
    setSelectedMeetingIDs((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      saveSources(next, selectedNoteIDs, selectedTaskIDs);
      return next;
    });
  };

  const toggleNote = (id: string) => {
    setSelectedNoteIDs((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      saveSources(selectedMeetingIDs, next, selectedTaskIDs);
      return next;
    });
  };

  const toggleTask = (id: string) => {
    setSelectedTaskIDs((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      saveSources(selectedMeetingIDs, selectedNoteIDs, next);
      return next;
    });
  };

  const toggleSection = (key: string) =>
    setExpandedSections((prev) => ({ ...prev, [key]: !prev[key] }));

  const addEntry = (section: keyof typeof sections) => {
    const entry: T5TEntry = {
      id: uuid(),
      headline: "",
      explanation: "",
    };
    const newSections = {
      ...sections,
      [section]: [...sections[section], entry],
    };
    setSections(newSections);
    save(newSections);
  };

  const updateEntry = (
    section: keyof typeof sections,
    entryId: string,
    field: "headline" | "explanation",
    value: string
  ) => {
    const newSections = {
      ...sections,
      [section]: sections[section].map((e) =>
        e.id === entryId ? { ...e, [field]: value } : e
      ),
    };
    setSections(newSections);
    save(newSections);
  };

  const removeEntry = (section: keyof typeof sections, entryId: string) => {
    const newSections = {
      ...sections,
      [section]: sections[section].filter((e) => e.id !== entryId),
    };
    setSections(newSections);
    save(newSections);
  };

  const {
    meetings: linkedMeetings,
    notes: linkedNotes,
    tasks: linkedTasks,
  } = selectedSources(
    { meetings, notes, tasks },
    { meetingIDs: selectedMeetingIDs, noteIDs: selectedNoteIDs, taskIDs: selectedTaskIDs }
  );

  const generateWithAI = async () => {
    setIsGenerating(true);
    try {
      const context = buildT5TContext(linkedMeetings, linkedNotes, linkedTasks);
      const request = buildT5TMessages(report.periodStart, report.periodEnd, context);
      const result = await chatWithAI(request.messages, request.systemContext);
      const newSections = parseT5TSections(result);

      setSections(newSections);
      save(newSections);
    } catch (err) {
      alert(err instanceof Error ? err.message : "Failed to generate");
    } finally {
      setIsGenerating(false);
    }
  };

  const copyEmailBody = () => {
    const body = buildEmailBody(sections);
    navigator.clipboard.writeText(body);
  };

  const downloadReport = () => {
    const md = buildMarkdown(report, sections);
    const blob = new Blob([md], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `T5T-${formatDate(report.periodStart)}-${formatDate(report.periodEnd)}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-3xl mx-auto px-12 py-10">
        <h1 className="text-[40px] font-bold text-text-primary mb-2">
          {report.title}
        </h1>
        <p className="text-sm text-text-secondary mb-6">
          Period: {formatDate(report.periodStart)} –{" "}
          {formatDate(report.periodEnd)} •{" "}
          <span
            className={
              report.status === "draft" ? "text-orange-400" : "text-green-400"
            }
          >
            {report.status === "draft" ? "Draft" : "Finalized"}
          </span>
        </p>

        {/* Actions */}
        <div className="flex gap-2 mb-8">
          <button
            onClick={generateWithAI}
            disabled={isGenerating}
            className="flex items-center gap-1.5 px-4 py-2 rounded-md bg-accent text-white text-sm font-medium hover:bg-accent/80 transition-colors disabled:opacity-50"
          >
            {isGenerating ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <Sparkles className="w-4 h-4" />
            )}
            {isGenerating ? "Generating..." : "Generate with AI"}
          </button>
          <button
            onClick={copyEmailBody}
            className="flex items-center gap-1.5 px-3 py-2 rounded-md bg-hover hover:bg-selected text-sm text-text-secondary transition-colors"
          >
            <Copy className="w-3.5 h-3.5" />
            Copy Email
          </button>
          <button
            onClick={downloadReport}
            className="flex items-center gap-1.5 px-3 py-2 rounded-md bg-hover hover:bg-selected text-sm text-text-secondary transition-colors"
          >
            <Download className="w-3.5 h-3.5" />
            Export .md
          </button>
        </div>

        <div className="border-t border-border mb-8" />

        {/* Sections */}
        <T5TSection
          title="Insights, Management Escalations & Help Needed"
          entries={sections.insights}
          expanded={expandedSections.insights}
          onToggle={() => toggleSection("insights")}
          onAdd={() => addEntry("insights")}
          onUpdate={(id, field, val) => updateEntry("insights", id, field, val)}
          onRemove={(id) => removeEntry("insights", id)}
        />

        <T5TSection
          title="Industry Business Development / Account Updates"
          entries={sections.accountUpdates}
          expanded={expandedSections.accountUpdates}
          onToggle={() => toggleSection("accountUpdates")}
          onAdd={() => addEntry("accountUpdates")}
          onUpdate={(id, field, val) =>
            updateEntry("accountUpdates", id, field, val)
          }
          onRemove={(id) => removeEntry("accountUpdates", id)}
        />

        <T5TSection
          title="Future Plans"
          entries={sections.futurePlans}
          expanded={expandedSections.futurePlans}
          onToggle={() => toggleSection("futurePlans")}
          onAdd={() => addEntry("futurePlans")}
          onUpdate={(id, field, val) =>
            updateEntry("futurePlans", id, field, val)
          }
          onRemove={(id) => removeEntry("futurePlans", id)}
        />

        {/* Sources */}
        <div className="mt-8">
          <button
            onClick={() => toggleSection("sources")}
            className="flex items-center gap-2 mb-3 text-text-secondary hover:text-text-primary transition-colors"
          >
            {expandedSections.sources ? (
              <ChevronDown className="w-4 h-4" />
            ) : (
              <ChevronRight className="w-4 h-4" />
            )}
            <h3 className="text-sm font-medium">
              Sources ({selectedMeetingIDs.size + selectedNoteIDs.size + selectedTaskIDs.size} selected)
            </h3>
          </button>
          {expandedSections.sources && (
            <div className="space-y-4 pl-6">
              {meetings.length > 0 && (
                <div>
                  <p className="text-xs font-semibold text-text-secondary uppercase tracking-wide mb-2">Meetings</p>
                  <div className="space-y-1">
                    {meetings.map((m) => (
                      <label key={m.id} className="flex items-center gap-2 cursor-pointer hover:bg-hover rounded px-2 py-1 -mx-2 transition-colors">
                        <input
                          type="checkbox"
                          checked={selectedMeetingIDs.has(m.id)}
                          onChange={() => toggleMeeting(m.id)}
                          className="accent-accent"
                        />
                        <span className="text-sm text-text-primary truncate">
                          {formatDate(m.date)} {m.title}
                        </span>
                      </label>
                    ))}
                  </div>
                </div>
              )}
              {notes.length > 0 && (
                <div>
                  <p className="text-xs font-semibold text-text-secondary uppercase tracking-wide mb-2">Notes</p>
                  <div className="space-y-1">
                    {notes.map((n) => (
                      <label key={n.id} className="flex items-center gap-2 cursor-pointer hover:bg-hover rounded px-2 py-1 -mx-2 transition-colors">
                        <input
                          type="checkbox"
                          checked={selectedNoteIDs.has(n.id)}
                          onChange={() => toggleNote(n.id)}
                          className="accent-accent"
                        />
                        <span className="text-sm text-text-primary truncate">
                          {formatDate(n.createdDate)} {n.title}
                        </span>
                      </label>
                    ))}
                  </div>
                </div>
              )}
              {tasks.length > 0 && (
                <div>
                  <p className="text-xs font-semibold text-text-secondary uppercase tracking-wide mb-2">Tasks</p>
                  <div className="space-y-1">
                    {tasks.map((t) => (
                      <label key={t.id} className="flex items-center gap-2 cursor-pointer hover:bg-hover rounded px-2 py-1 -mx-2 transition-colors">
                        <input
                          type="checkbox"
                          checked={selectedTaskIDs.has(t.id)}
                          onChange={() => toggleTask(t.id)}
                          className="accent-accent"
                        />
                        <span className="text-sm text-text-primary truncate">
                          {formatDate(t.createdDate)} {t.title || "Untitled"}
                        </span>
                      </label>
                    ))}
                  </div>
                </div>
              )}
              {meetings.length === 0 && notes.length === 0 && tasks.length === 0 && (
                <p className="text-sm text-text-tertiary">
                  No meetings, notes, or tasks available.
                </p>
              )}
            </div>
          )}
        </div>

      </div>
    </div>
  );
}

function T5TSection({
  title,
  entries,
  expanded,
  onToggle,
  onAdd,
  onUpdate,
  onRemove,
}: {
  title: string;
  entries: T5TEntry[];
  expanded: boolean;
  onToggle: () => void;
  onAdd: () => void;
  onUpdate: (id: string, field: "headline" | "explanation", val: string) => void;
  onRemove: (id: string) => void;
}) {
  return (
    <div className="mb-6">
      <div className="flex items-center gap-2 mb-3">
        <button
          onClick={onToggle}
          className="flex items-center gap-2 text-text-primary hover:text-accent transition-colors"
        >
          {expanded ? (
            <ChevronDown className="w-4 h-4" />
          ) : (
            <ChevronRight className="w-4 h-4" />
          )}
          <h2 className="text-lg font-semibold">{title}</h2>
        </button>
        <button
          onClick={onAdd}
          className="ml-auto text-text-tertiary hover:text-accent transition-colors"
        >
          <Plus className="w-4 h-4" />
        </button>
      </div>

      {expanded && (
        <div className="space-y-3 pl-6">
          {entries.map((entry) => (
            <div
              key={entry.id}
              className="relative group border border-border rounded-lg p-4 bg-hover/50"
            >
              <button
                onClick={() => onRemove(entry.id)}
                className="absolute top-2 right-2 opacity-0 group-hover:opacity-100 text-text-tertiary hover:text-danger transition-opacity"
              >
                <X className="w-3.5 h-3.5" />
              </button>
              <input
                type="text"
                value={entry.headline}
                onChange={(e) =>
                  onUpdate(entry.id, "headline", e.target.value)
                }
                placeholder="Headline"
                className="w-full bg-transparent border-none text-[15px] font-medium text-text-primary outline-none mb-2 placeholder:text-text-tertiary p-0"
              />
              <textarea
                value={entry.explanation}
                onChange={(e) =>
                  onUpdate(entry.id, "explanation", e.target.value)
                }
                placeholder="Explanation..."
                className="w-full bg-transparent border-none text-sm text-text-secondary outline-none resize-none min-h-[40px] placeholder:text-text-tertiary p-0"
              />
            </div>
          ))}
          {entries.length === 0 && (
            <p className="text-xs text-text-tertiary">
              No entries yet. Click + to add one.
            </p>
          )}
        </div>
      )}
    </div>
  );
}

function buildEmailBody(sections: T5TReport["sections"]): string {
  const parts: string[] = [];

  if (sections.insights.length > 0) {
    parts.push(
      "Insights, Management Escalations & Help Needed, Market & Competition"
    );
    sections.insights.forEach((e) => {
      parts.push(`• ${e.headline}\n  ${e.explanation}`);
    });
  }

  if (sections.accountUpdates.length > 0) {
    parts.push("\nIndustry Business Development / Account Updates");
    sections.accountUpdates.forEach((e) => {
      parts.push(`• ${e.headline}\n  ${e.explanation}`);
    });
  }

  if (sections.futurePlans.length > 0) {
    parts.push("\nFuture Plans");
    sections.futurePlans.forEach((e) => {
      parts.push(`• ${e.headline}\n  ${e.explanation}`);
    });
  }

  return parts.join("\n");
}

function buildMarkdown(
  report: T5TReport,
  sections: T5TReport["sections"]
): string {
  const lines: string[] = [];
  lines.push(`# ${report.title}\n`);
  lines.push(
    `**Period:** ${formatDate(report.periodStart)} – ${formatDate(report.periodEnd)}\n`
  );

  if (sections.insights.length > 0) {
    lines.push(
      "## Insights, Management Escalations & Help Needed\n"
    );
    sections.insights.forEach((e) => {
      lines.push(`### ${e.headline}`);
      lines.push(`${e.explanation}\n`);
    });
  }

  if (sections.accountUpdates.length > 0) {
    lines.push("## Industry Business Development / Account Updates\n");
    sections.accountUpdates.forEach((e) => {
      lines.push(`### ${e.headline}`);
      lines.push(`${e.explanation}\n`);
    });
  }

  if (sections.futurePlans.length > 0) {
    lines.push("## Future Plans\n");
    sections.futurePlans.forEach((e) => {
      lines.push(`### ${e.headline}`);
      lines.push(`${e.explanation}\n`);
    });
  }

  return lines.join("\n");
}
