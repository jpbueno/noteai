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
  Check,
  AlertCircle,
  Mail,
  FileText,
  Eye,
  ArrowLeft,
  ArrowRight,
  Calendar,
  CheckCircle,
} from "lucide-react";
import type {
  T5TReport,
  T5TReportSection,
  T5TConfig,
  TodoItem,
  Meeting,
  Note,
  SidebarSelection,
} from "@/lib/types";
import { DEFAULT_T5T_CONFIG } from "@/lib/types";
import { db, getT5TConfig } from "@/lib/db";
import { formatDate, triggerRefresh } from "@/lib/hooks";
import {
  generateT5TReport,
  buildReportMarkdown,
  buildEmailSubject,
  runQualityChecks,
  type QualityCheck,
} from "@/lib/t5t-engine";
import { createOutlookHtmlDocument } from "@/lib/outlook-html";
import { v4 as uuid } from "uuid";

// ===== Wizard Steps =====

type WizardStep = "sources" | "generate" | "export";

const STEPS: { id: WizardStep; label: string; icon: React.ComponentType<{ className?: string }> }[] = [
  { id: "sources", label: "Sources", icon: CheckCircle },
  { id: "generate", label: "Generate & Edit", icon: Sparkles },
  { id: "export", label: "Export", icon: Mail },
];

// ===== Props =====

interface T5TComposerProps {
  report: T5TReport;
  meetings: Meeting[];
  notes: Note[];
  todos: TodoItem[];
  onNavigate?: (sel: SidebarSelection) => void;
}

export default function T5TComposer({
  report,
  meetings,
  notes,
  todos,
  onNavigate,
}: T5TComposerProps) {
  const [step, setStep] = useState<WizardStep>("sources");
  const [config, setConfig] = useState<T5TConfig>(DEFAULT_T5T_CONFIG);
  const [sections, setSections] = useState<T5TReportSection[]>(report.sections);
  const [selectedTodoIDs, setSelectedTodoIDs] = useState<Set<string>>(
    new Set(report.todoIDs || report.taskIDs || []),
  );
  const [selectedMeetingIDs, setSelectedMeetingIDs] = useState<Set<string>>(
    new Set(report.meetingIDs),
  );
  const [selectedNoteIDs, setSelectedNoteIDs] = useState<Set<string>>(
    new Set(report.noteIDs),
  );
  const [isGenerating, setIsGenerating] = useState(false);
  const [qualityChecks, setQualityChecks] = useState<QualityCheck[]>([]);
  const [expandedSections, setExpandedSections] = useState<
    Record<string, boolean>
  >({});
  const [htmlPreview, setHtmlPreview] = useState("");
  const [showHtmlPreview, setShowHtmlPreview] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const prevIdRef = useRef(report.id);

  // Load config
  useEffect(() => {
    getT5TConfig().then(setConfig);
  }, []);

  // Sync when report changes
  useEffect(() => {
    if (prevIdRef.current !== report.id) {
      setSections(report.sections);
      setSelectedTodoIDs(new Set(report.todoIDs || report.taskIDs || []));
      setSelectedMeetingIDs(new Set(report.meetingIDs));
      setSelectedNoteIDs(new Set(report.noteIDs));
      setStep("sources");
      setQualityChecks([]);
      setHtmlPreview("");
      prevIdRef.current = report.id;
    }
  }, [report]);

  // Initialize expanded state for sections
  useEffect(() => {
    if (sections.length > 0) {
      const expanded: Record<string, boolean> = {};
      for (const s of sections) {
        expanded[s.name] = expandedSections[s.name] ?? true;
      }
      setExpandedSections(expanded);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sections.length]);

  // ===== Persistence =====

  const save = useCallback(
    (newSections: T5TReportSection[]) => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
      saveTimer.current = setTimeout(async () => {
        await db.t5tReports.update(report.id, { sections: newSections });
        triggerRefresh();
      }, 400);
    },
    [report.id],
  );

  const saveSources = useCallback(
    async (
      tIDs: Set<string>,
      mIDs: Set<string>,
      nIDs: Set<string>,
    ) => {
      await db.t5tReports.update(report.id, {
        todoIDs: Array.from(tIDs),
        meetingIDs: Array.from(mIDs),
        noteIDs: Array.from(nIDs),
      });
      triggerRefresh();
    },
    [report.id],
  );

  // ===== Source Toggles =====

  const toggleSource = (
    type: "todo" | "meeting" | "note",
    id: string,
  ) => {
    const setters = {
      todo: setSelectedTodoIDs,
      meeting: setSelectedMeetingIDs,
      note: setSelectedNoteIDs,
    };
    setters[type]((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      const t = type === "todo" ? next : selectedTodoIDs;
      const m = type === "meeting" ? next : selectedMeetingIDs;
      const n = type === "note" ? next : selectedNoteIDs;
      saveSources(t, m, n);
      return next;
    });
  };

  // ===== Section Editing =====

  const updateSectionContent = (sectionId: string, content: string) => {
    const newSections = sections.map((s) =>
      s.id === sectionId ? { ...s, content } : s,
    );
    setSections(newSections);
    save(newSections);
  };

  const toggleSectionExpand = (name: string) =>
    setExpandedSections((prev) => ({ ...prev, [name]: !prev[name] }));

  // ===== Generation =====

  const handleGenerate = async () => {
    setIsGenerating(true);
    try {
      const linkedTodos = todos.filter((t) =>
        selectedTodoIDs.has(t.id),
      );
      const linkedMeetings = meetings.filter((m) =>
        selectedMeetingIDs.has(m.id),
      );
      const linkedNotes = notes.filter((n) => selectedNoteIDs.has(n.id));

      const generated = await generateT5TReport(
        config,
        linkedTodos,
        linkedMeetings,
        linkedNotes,
        report.periodStart,
        report.periodEnd,
      );

      setSections(generated);
      save(generated);

      // Run quality checks
      const checks = runQualityChecks(generated, config);
      setQualityChecks(checks);

      setStep("generate");
    } catch (err) {
      alert(err instanceof Error ? err.message : "Generation failed");
    } finally {
      setIsGenerating(false);
    }
  };

  const regenerateSection = async (sectionName: string) => {
    setIsGenerating(true);
    try {
      const linkedTodos = todos.filter((t) =>
        selectedTodoIDs.has(t.id),
      );
      const linkedMeetings = meetings.filter((m) =>
        selectedMeetingIDs.has(m.id),
      );
      const linkedNotes = notes.filter((n) => selectedNoteIDs.has(n.id));

      const generated = await generateT5TReport(
        config,
        linkedTodos,
        linkedMeetings,
        linkedNotes,
        report.periodStart,
        report.periodEnd,
      );

      // Only replace the requested section
      const newSection = generated.find((s) => s.name === sectionName);
      if (newSection) {
        const newSections = sections.map((s) =>
          s.name === sectionName ? newSection : s,
        );
        setSections(newSections);
        save(newSections);
        const checks = runQualityChecks(newSections, config);
        setQualityChecks(checks);
      }
    } catch (err) {
      alert(err instanceof Error ? err.message : "Regeneration failed");
    } finally {
      setIsGenerating(false);
    }
  };

  // ===== Export =====

  const getFullMarkdown = () =>
    buildReportMarkdown(config, sections, report.periodStart, report.periodEnd);

  const getOutlookHtml = () =>
    createOutlookHtmlDocument(getFullMarkdown(), config);

  const handleCopyMarkdown = () => {
    navigator.clipboard.writeText(getFullMarkdown());
    setCopied("markdown");
    setTimeout(() => setCopied(null), 2000);
  };

  const handleCopyHtml = () => {
    const html = getOutlookHtml();
    // Copy as both HTML and plain text for Outlook compatibility
    const blob = new Blob([html], { type: "text/html" });
    const clipItem = new ClipboardItem({ "text/html": blob });
    navigator.clipboard.write([clipItem]);
    setCopied("html");
    setTimeout(() => setCopied(null), 2000);
  };

  const handleDownloadMarkdown = () => {
    const md = getFullMarkdown();
    const blob = new Blob([md], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `Weekly_Report_${report.periodStart.slice(0, 10)}_${report.periodEnd.slice(0, 10)}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleDownloadHtml = () => {
    const html = getOutlookHtml();
    const blob = new Blob([html], { type: "text/html" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `Weekly_Report_${report.periodStart.slice(0, 10)}_${report.periodEnd.slice(0, 10)}_outlook.html`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleOpenMailto = () => {
    const subject = encodeURIComponent(
      buildEmailSubject(config, report.periodStart, report.periodEnd),
    );
    const body = encodeURIComponent(getFullMarkdown());
    const to = encodeURIComponent(config.identity.email || "");
    window.open(`mailto:${to}?subject=${subject}&body=${body}`);
  };

  const handlePreviewHtml = () => {
    setHtmlPreview(getOutlookHtml());
    setShowHtmlPreview(true);
  };

  const handleFinalize = async () => {
    await db.t5tReports.update(report.id, { status: "finalized" });
    triggerRefresh();
  };

  // ===== Derived Data =====

  const periodMeetings = meetings.filter((m) => {
    const date = new Date(m.date);
    return date >= new Date(report.periodStart) && date <= new Date(report.periodEnd);
  });

  const totalSources =
    selectedTodoIDs.size +
    selectedMeetingIDs.size +
    selectedNoteIDs.size;

  const passedChecks = qualityChecks.filter((c) => c.passed).length;

  // ===== Render =====

  return (
    <div className="h-full flex flex-col overflow-hidden">
      {/* Header */}
      <div className="flex-shrink-0 px-8 pt-6 pb-4 border-b border-border">
        <div className="max-w-4xl mx-auto">
          <div className="flex items-start justify-between mb-3">
            <div>
              <h1 className="text-2xl font-bold text-text-primary">
                {report.title}
              </h1>
              <p className="text-sm text-text-secondary mt-1">
                {formatDate(report.periodStart)} –{" "}
                {formatDate(report.periodEnd)} ·{" "}
                <span
                  className={
                    report.status === "draft"
                      ? "text-orange-400"
                      : "text-green-400"
                  }
                >
                  {report.status === "draft" ? "Draft" : "Finalized"}
                </span>
              </p>
            </div>
          </div>

          {/* Step navigation */}
          <div className="flex items-center gap-1">
            {STEPS.map((s, i) => {
              const Icon = s.icon;
              const isActive = step === s.id;
              const isPast =
                STEPS.findIndex((x) => x.id === step) >
                STEPS.findIndex((x) => x.id === s.id);
              return (
                <button
                  key={s.id}
                  onClick={() => setStep(s.id)}
                  className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                    isActive
                      ? "bg-accent text-white"
                      : isPast
                        ? "bg-hover text-text-primary"
                        : "text-text-tertiary hover:text-text-secondary hover:bg-hover"
                  }`}
                >
                  <Icon className="w-3.5 h-3.5" />
                  {s.label}
                  {s.id === "sources" && totalSources > 0 && (
                    <span className="text-[10px] bg-white/20 px-1 rounded">
                      {totalSources}
                    </span>
                  )}
                  {s.id === "generate" &&
                    qualityChecks.length > 0 && (
                      <span
                        className={`text-[10px] px-1 rounded ${passedChecks === qualityChecks.length ? "bg-green-500/20 text-green-300" : "bg-orange-500/20 text-orange-300"}`}
                      >
                        {passedChecks}/{qualityChecks.length}
                      </span>
                    )}
                </button>
              );
            })}
          </div>
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto">
        <div className="max-w-4xl mx-auto px-8 py-6">
          {step === "sources" && (
            <SourcesStep
              todos={todos}
              meetings={periodMeetings}
              allMeetings={meetings}
              notes={notes}
              selectedTodoIDs={selectedTodoIDs}
              selectedMeetingIDs={selectedMeetingIDs}
              selectedNoteIDs={selectedNoteIDs}
              onToggle={toggleSource}
              isGenerating={isGenerating}
              onGenerate={handleGenerate}
              onNavigate={onNavigate}
            />
          )}

          {step === "generate" && (
            <GenerateStep
              sections={sections}
              expandedSections={expandedSections}
              onToggleSection={toggleSectionExpand}
              onUpdateSection={updateSectionContent}
              onRegenerate={regenerateSection}
              qualityChecks={qualityChecks}
              isGenerating={isGenerating}
              onGenerateAll={handleGenerate}
              config={config}
            />
          )}

          {step === "export" && (
            <ExportStep
              onCopyMarkdown={handleCopyMarkdown}
              onCopyHtml={handleCopyHtml}
              onDownloadMarkdown={handleDownloadMarkdown}
              onDownloadHtml={handleDownloadHtml}
              onMailto={handleOpenMailto}
              onPreviewHtml={handlePreviewHtml}
              onFinalize={handleFinalize}
              copied={copied}
              htmlPreview={htmlPreview}
              showHtmlPreview={showHtmlPreview}
              onClosePreview={() => setShowHtmlPreview(false)}
              isFinalized={report.status === "finalized"}
              markdown={getFullMarkdown()}
            />
          )}
        </div>
      </div>
    </div>
  );
}

// ===== Step 1: Sources =====

function SourcesStep({
  todos,
  meetings,
  allMeetings,
  notes,
  selectedTodoIDs,
  selectedMeetingIDs,
  selectedNoteIDs,
  onToggle,
  isGenerating,
  onGenerate,
  onNavigate,
}: {
  todos: TodoItem[];
  meetings: Meeting[];
  allMeetings: Meeting[];
  notes: Note[];
  selectedTodoIDs: Set<string>;
  selectedMeetingIDs: Set<string>;
  selectedNoteIDs: Set<string>;
  onToggle: (type: "todo" | "meeting" | "note", id: string) => void;
  isGenerating: boolean;
  onGenerate: () => void;
  onNavigate?: (sel: SidebarSelection) => void;
}) {
  const completedTodos = todos.filter((t) => t.completed);
  const pendingTodos = todos.filter((t) => !t.completed);

  return (
    <div className="space-y-6">
      <p className="text-sm text-text-secondary">
        Select the sources to include in this report. Todos are the primary
        input — meetings and notes provide supplementary context.
      </p>

      {/* Todos — primary source */}
      <SourceSection
        title="Todos"
        icon={CheckCircle}
        badge={`${selectedTodoIDs.size}/${todos.length} selected`}
      >
        {todos.length > 0 ? (
          <div className="space-y-1">
            {/* Select all / none */}
            <div className="flex items-center gap-3 mb-2">
              <button
                onClick={() => {
                  for (const t of todos) {
                    if (!selectedTodoIDs.has(t.id)) onToggle("todo", t.id);
                  }
                }}
                className="text-[11px] text-accent hover:underline"
              >
                Select all
              </button>
              <button
                onClick={() => {
                  for (const t of todos) {
                    if (selectedTodoIDs.has(t.id)) onToggle("todo", t.id);
                  }
                }}
                className="text-[11px] text-text-tertiary hover:underline"
              >
                Clear
              </button>
            </div>
            {pendingTodos.length > 0 && (
              <>
                <p className="text-[11px] text-text-tertiary font-semibold uppercase tracking-wide pt-1">Pending</p>
                {pendingTodos.map((t) => (
                  <SourceItem
                    key={t.id}
                    checked={selectedTodoIDs.has(t.id)}
                    onChange={() => onToggle("todo", t.id)}
                    label={`${t.title || "Untitled"}${t.dueDate ? " (due: " + t.dueDate + ")" : ""}`}
                    onClick={() => onNavigate?.({ type: "todo", id: t.id })}
                  />
                ))}
              </>
            )}
            {completedTodos.length > 0 && (
              <>
                <p className="text-[11px] text-text-tertiary font-semibold uppercase tracking-wide pt-2">Completed</p>
                {completedTodos.map((t) => (
                  <SourceItem
                    key={t.id}
                    checked={selectedTodoIDs.has(t.id)}
                    onChange={() => onToggle("todo", t.id)}
                    label={`${t.title || "Untitled"}${t.dueDate ? " (due: " + t.dueDate + ")" : ""}`}
                    onClick={() => onNavigate?.({ type: "todo", id: t.id })}
                  />
                ))}
              </>
            )}
          </div>
        ) : (
          <p className="text-xs text-text-tertiary">
            No todos available. Create todos to use as report input.
          </p>
        )}
      </SourceSection>

      {/* Meetings */}
      <SourceSection
        title="Meetings"
        icon={Calendar}
        badge={`${selectedMeetingIDs.size}/${meetings.length} in period`}
      >
        {meetings.length > 0 ? (
          <div className="space-y-1">
            {meetings.map((m) => (
              <SourceItem
                key={m.id}
                checked={selectedMeetingIDs.has(m.id)}
                onChange={() => onToggle("meeting", m.id)}
                label={`${formatDate(m.date)} ${m.title}`}
                onClick={() => onNavigate?.({ type: "meeting", id: m.id })}
              />
            ))}
          </div>
        ) : (
          <p className="text-xs text-text-tertiary">No meetings in period</p>
        )}
        {allMeetings.filter((m) => !meetings.includes(m)).length > 0 && (
          <details className="mt-2">
            <summary className="text-xs text-text-tertiary cursor-pointer hover:text-text-secondary">
              {allMeetings.length - meetings.length} meeting(s) outside period
            </summary>
            <div className="space-y-1 mt-1">
              {allMeetings
                .filter((m) => !meetings.includes(m))
                .map((m) => (
                  <SourceItem
                    key={m.id}
                    checked={selectedMeetingIDs.has(m.id)}
                    onChange={() => onToggle("meeting", m.id)}
                    label={`${formatDate(m.date)} ${m.title}`}
                    dimmed
                  />
                ))}
            </div>
          </details>
        )}
      </SourceSection>

      {/* Notes */}
      <SourceSection
        title="Notes"
        icon={FileText}
        badge={`${selectedNoteIDs.size} selected`}
      >
        {notes.length > 0 ? (
          <div className="space-y-1">
            {notes.map((n) => (
              <SourceItem
                key={n.id}
                checked={selectedNoteIDs.has(n.id)}
                onChange={() => onToggle("note", n.id)}
                label={`${formatDate(n.createdDate)} ${n.title}`}
                onClick={() => onNavigate?.({ type: "note", id: n.id })}
              />
            ))}
          </div>
        ) : (
          <p className="text-xs text-text-tertiary">No notes available</p>
        )}
      </SourceSection>

      {/* Generate button */}
      <div className="pt-4 border-t border-border">
        <button
          onClick={onGenerate}
          disabled={isGenerating}
          className="flex items-center gap-2 px-5 py-2.5 rounded-md bg-accent text-white text-sm font-medium hover:bg-accent/80 transition-colors disabled:opacity-50"
        >
          {isGenerating ? (
            <Loader2 className="w-4 h-4 animate-spin" />
          ) : (
            <Sparkles className="w-4 h-4" />
          )}
          {isGenerating ? "Generating T5T Report..." : "Generate with AI"}
        </button>
        {selectedTodoIDs.size === 0 &&
          selectedMeetingIDs.size === 0 &&
          selectedNoteIDs.size === 0 && (
            <p className="text-xs text-orange-400 mt-2">
              No sources selected — the AI will generate a minimal report
            </p>
          )}
      </div>
    </div>
  );
}

// ===== Step 2: Generate & Edit =====

function GenerateStep({
  sections,
  expandedSections,
  onToggleSection,
  onUpdateSection,
  onRegenerate,
  qualityChecks,
  isGenerating,
  onGenerateAll,
  config,
}: {
  sections: T5TReportSection[];
  expandedSections: Record<string, boolean>;
  onToggleSection: (name: string) => void;
  onUpdateSection: (id: string, content: string) => void;
  onRegenerate: (sectionName: string) => void;
  qualityChecks: QualityCheck[];
  isGenerating: boolean;
  onGenerateAll: () => void;
  config: T5TConfig;
}) {
  return (
    <div className="space-y-6">
      {/* Quality checks */}
      {qualityChecks.length > 0 && (
        <div className="bg-hover/50 border border-border rounded-lg p-4">
          <h3 className="text-sm font-medium text-text-primary mb-2">
            Quality Checks
          </h3>
          <div className="grid grid-cols-2 gap-2">
            {qualityChecks.map((check) => (
              <div
                key={check.id}
                className="flex items-center gap-2 text-xs"
              >
                {check.passed ? (
                  <CheckCircle className="w-3.5 h-3.5 text-green-400 flex-shrink-0" />
                ) : (
                  <AlertCircle className="w-3.5 h-3.5 text-orange-400 flex-shrink-0" />
                )}
                <span
                  className={
                    check.passed ? "text-text-secondary" : "text-orange-400"
                  }
                >
                  {check.message}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Regenerate all button */}
      <div className="flex items-center gap-2">
        <button
          onClick={onGenerateAll}
          disabled={isGenerating}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-hover hover:bg-selected text-sm text-text-secondary transition-colors disabled:opacity-50"
        >
          {isGenerating ? (
            <Loader2 className="w-3.5 h-3.5 animate-spin" />
          ) : (
            <Sparkles className="w-3.5 h-3.5" />
          )}
          Regenerate All
        </button>
        <span className="text-xs text-text-tertiary">
          Edit sections below or regenerate individual sections
        </span>
      </div>

      {/* Sections */}
      {sections.length === 0 ? (
        <div className="text-center py-12">
          <Sparkles className="w-8 h-8 text-text-tertiary mx-auto mb-3" />
          <p className="text-sm text-text-secondary">
            No sections generated yet. Go to Sources and click Generate.
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {sections.map((section) => {
            const isExpanded = expandedSections[section.name] ?? true;
            return (
              <div
                key={section.id}
                className="border border-border rounded-lg overflow-hidden"
              >
                <div className="flex items-center gap-2 px-4 py-3 bg-hover/30">
                  <button
                    onClick={() => onToggleSection(section.name)}
                    className="flex items-center gap-2 flex-1 text-left"
                  >
                    {isExpanded ? (
                      <ChevronDown className="w-4 h-4 text-text-tertiary" />
                    ) : (
                      <ChevronRight className="w-4 h-4 text-text-tertiary" />
                    )}
                    <span className="text-sm font-semibold text-text-primary">
                      [{section.name}]
                    </span>
                  </button>
                  <button
                    onClick={() => onRegenerate(section.name)}
                    disabled={isGenerating}
                    className="flex items-center gap-1 text-text-tertiary hover:text-accent text-xs transition-colors px-2 py-1 rounded hover:bg-hover disabled:opacity-50"
                    title="Regenerate this section"
                  >
                    <Sparkles className="w-3 h-3" />
                    Regen
                  </button>
                </div>
                {isExpanded && (
                  <div className="px-4 pb-4 pt-2">
                    <textarea
                      value={section.content}
                      onChange={(e) =>
                        onUpdateSection(section.id, e.target.value)
                      }
                      className="w-full bg-transparent border-none text-sm text-text-primary outline-none resize-none min-h-[60px] placeholder:text-text-tertiary p-0 font-mono leading-relaxed"
                      rows={Math.max(
                        3,
                        section.content.split("\n").length + 1,
                      )}
                      placeholder={
                        config.reportTemplate.find(
                          (t) => t.name === section.name,
                        )?.placeholder || "Section content..."
                      }
                    />
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ===== Step 3: Export =====

function ExportStep({
  onCopyMarkdown,
  onCopyHtml,
  onDownloadMarkdown,
  onDownloadHtml,
  onMailto,
  onPreviewHtml,
  onFinalize,
  copied,
  htmlPreview,
  showHtmlPreview,
  onClosePreview,
  isFinalized,
  markdown,
}: {
  onCopyMarkdown: () => void;
  onCopyHtml: () => void;
  onDownloadMarkdown: () => void;
  onDownloadHtml: () => void;
  onMailto: () => void;
  onPreviewHtml: () => void;
  onFinalize: () => void;
  copied: string | null;
  htmlPreview: string;
  showHtmlPreview: boolean;
  onClosePreview: () => void;
  isFinalized: boolean;
  markdown: string;
}) {
  return (
    <div className="space-y-8">
      {/* Export actions */}
      <div>
        <h3 className="text-sm font-medium text-text-primary mb-4">
          Export Options
        </h3>
        <div className="grid grid-cols-2 gap-3">
          <ExportButton
            icon={Copy}
            label="Copy Markdown"
            description="Copy the full report as markdown text"
            onClick={onCopyMarkdown}
            active={copied === "markdown"}
          />
          <ExportButton
            icon={Copy}
            label="Copy Outlook HTML"
            description="Copy formatted HTML for pasting into Outlook"
            onClick={onCopyHtml}
            active={copied === "html"}
          />
          <ExportButton
            icon={Download}
            label="Download .md"
            description="Save as a markdown file"
            onClick={onDownloadMarkdown}
          />
          <ExportButton
            icon={Download}
            label="Download .html"
            description="Save as Outlook-compatible HTML"
            onClick={onDownloadHtml}
          />
          <ExportButton
            icon={Eye}
            label="Preview HTML"
            description="See how it looks in Outlook"
            onClick={onPreviewHtml}
          />
          <ExportButton
            icon={Mail}
            label="Open in Email"
            description="Create a new email with the report"
            onClick={onMailto}
          />
        </div>
      </div>

      {/* Finalize */}
      <div className="border-t border-border pt-6">
        <div className="flex items-center gap-3">
          <button
            onClick={onFinalize}
            disabled={isFinalized}
            className={`flex items-center gap-2 px-4 py-2 rounded-md text-sm font-medium transition-colors ${
              isFinalized
                ? "bg-green-500/20 text-green-400 cursor-default"
                : "bg-accent text-white hover:bg-accent/80"
            }`}
          >
            <Check className="w-4 h-4" />
            {isFinalized ? "Finalized" : "Mark as Finalized"}
          </button>
          {!isFinalized && (
            <span className="text-xs text-text-tertiary">
              Finalizing marks this report as complete
            </span>
          )}
        </div>
      </div>

      {/* Markdown preview */}
      <div className="border-t border-border pt-6">
        <h3 className="text-sm font-medium text-text-primary mb-3">
          Markdown Preview
        </h3>
        <pre className="text-xs text-text-secondary bg-hover/50 border border-border rounded-lg p-4 overflow-auto max-h-[400px] whitespace-pre-wrap font-mono">
          {markdown}
        </pre>
      </div>

      {/* HTML Preview modal */}
      {showHtmlPreview && (
        <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-8">
          <div className="bg-white rounded-lg shadow-2xl max-w-4xl w-full max-h-[90vh] flex flex-col">
            <div className="flex items-center justify-between px-4 py-3 border-b">
              <h3 className="text-sm font-medium text-gray-900">
                Outlook HTML Preview
              </h3>
              <button
                onClick={onClosePreview}
                className="text-gray-400 hover:text-gray-600"
              >
                <X className="w-4 h-4" />
              </button>
            </div>
            <div className="flex-1 overflow-auto p-4">
              <iframe
                srcDoc={htmlPreview}
                className="w-full h-full min-h-[500px] border-0"
                title="HTML Preview"
              />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ===== Reusable Components =====

function SourceSection({
  title,
  icon: Icon,
  badge,
  children,
}: {
  title: string;
  icon: React.ComponentType<{ className?: string }>;
  badge?: string;
  children: React.ReactNode;
}) {
  const [expanded, setExpanded] = useState(true);

  return (
    <div className="border border-border rounded-lg overflow-hidden">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-2 w-full px-4 py-3 bg-hover/30 text-left"
      >
        {expanded ? (
          <ChevronDown className="w-4 h-4 text-text-tertiary" />
        ) : (
          <ChevronRight className="w-4 h-4 text-text-tertiary" />
        )}
        <Icon className="w-4 h-4 text-text-secondary" />
        <span className="text-sm font-semibold text-text-primary flex-1">
          {title}
        </span>
        {badge && (
          <span className="text-[10px] text-text-tertiary bg-hover px-1.5 py-0.5 rounded">
            {badge}
          </span>
        )}
      </button>
      {expanded && <div className="px-4 pb-3 pt-1">{children}</div>}
    </div>
  );
}

function SourceItem({
  checked,
  onChange,
  label,
  onClick,
  dimmed,
}: {
  checked: boolean;
  onChange: () => void;
  label: string;
  onClick?: () => void;
  dimmed?: boolean;
}) {
  return (
    <label
      className={`flex items-center gap-2 cursor-pointer hover:bg-hover rounded px-2 py-1 -mx-2 transition-colors ${dimmed ? "opacity-60" : ""}`}
    >
      <input
        type="checkbox"
        checked={checked}
        onChange={onChange}
        className="accent-accent flex-shrink-0"
      />
      <span
        className="text-sm text-text-primary truncate flex-1 cursor-pointer"
        onClick={(e) => {
          if (onClick) {
            e.preventDefault();
            onClick();
          }
        }}
      >
        {label}
      </span>
    </label>
  );
}

function ExportButton({
  icon: Icon,
  label,
  description,
  onClick,
  active,
}: {
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  description: string;
  onClick: () => void;
  active?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      className={`flex items-start gap-3 p-4 rounded-lg border transition-colors text-left ${
        active
          ? "border-green-500/50 bg-green-500/10"
          : "border-border bg-hover/30 hover:bg-hover"
      }`}
    >
      {active ? (
        <Check className="w-4 h-4 text-green-400 flex-shrink-0 mt-0.5" />
      ) : (
        <Icon className="w-4 h-4 text-text-secondary flex-shrink-0 mt-0.5" />
      )}
      <div>
        <span className="text-sm font-medium text-text-primary block">
          {active ? "Copied!" : label}
        </span>
        <span className="text-xs text-text-tertiary">{description}</span>
      </div>
    </button>
  );
}
