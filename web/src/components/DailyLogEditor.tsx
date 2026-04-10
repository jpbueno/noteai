"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import {
  ChevronDown,
  ChevronRight,
  Plus,
  Clock,
  Eye,
  EyeOff,
} from "lucide-react";
import type { DailyLog, DailyLogSection, T5TConfig } from "@/lib/types";
import { DEFAULT_T5T_CONFIG } from "@/lib/types";
import { db, getT5TConfig } from "@/lib/db";
import { triggerRefresh } from "@/lib/hooks";

interface DailyLogEditorProps {
  log: DailyLog;
}

export default function DailyLogEditor({ log }: DailyLogEditorProps) {
  const [sections, setSections] = useState<DailyLogSection[]>(log.sections);
  const [config, setConfig] = useState<T5TConfig>(DEFAULT_T5T_CONFIG);
  const [expandedSections, setExpandedSections] = useState<
    Record<string, boolean>
  >({});
  const [title, setTitle] = useState(formatLogTitle(log.date));
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const prevIdRef = useRef(log.id);

  useEffect(() => {
    getT5TConfig().then(setConfig);
  }, []);

  useEffect(() => {
    if (prevIdRef.current !== log.id) {
      setSections(log.sections);
      setTitle(formatLogTitle(log.date));
      prevIdRef.current = log.id;
    }
  }, [log.id, log.sections, log.date]);

  // Initialize expanded state for all sections
  useEffect(() => {
    const expanded: Record<string, boolean> = {};
    for (const s of sections) {
      expanded[s.name] = expandedSections[s.name] ?? true;
    }
    setExpandedSections(expanded);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sections.length]);

  const save = useCallback(
    (newSections: DailyLogSection[]) => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
      saveTimer.current = setTimeout(async () => {
        await db.dailyLogs.update(log.id, {
          sections: newSections,
          modifiedDate: new Date().toISOString(),
        });
        triggerRefresh();
      }, 400);
    },
    [log.id],
  );

  const updateSection = (name: string, content: string) => {
    const newSections = sections.map((s) =>
      s.name === name ? { ...s, content } : s,
    );
    setSections(newSections);
    save(newSections);
  };

  const addQuickNote = (sectionName: string) => {
    const timestamp = new Date().toLocaleTimeString("en-US", {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    const existing = sections.find((s) => s.name === sectionName);
    if (existing) {
      const newContent = existing.content
        ? `${existing.content}\n- [${timestamp}] `
        : `- [${timestamp}] `;
      updateSection(sectionName, newContent);
    }
  };

  const toggleSection = (name: string) => {
    setExpandedSections((prev) => ({ ...prev, [name]: !prev[name] }));
  };

  const getClassification = (sectionName: string) => {
    return (
      config.dailyTemplate.find((t) => t.name === sectionName)
        ?.classification || "report-worthy"
    );
  };

  const getHint = (sectionName: string) => {
    return config.dailyTemplate.find((t) => t.name === sectionName)?.hint || "";
  };

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-3xl mx-auto px-12 py-10">
        {/* Header */}
        <div className="flex items-center gap-3 mb-2">
          <h1 className="text-[40px] font-bold text-text-primary">{title}</h1>
        </div>
        <p className="text-sm text-text-secondary mb-8">
          {new Date(log.date + "T12:00:00").toLocaleDateString("en-US", {
            weekday: "long",
            month: "long",
            day: "numeric",
            year: "numeric",
          })}
        </p>

        {/* Sections */}
        <div className="space-y-4">
          {sections.map((section) => {
            const isPersonal = getClassification(section.name) === "personal";
            const isExpanded = expandedSections[section.name] ?? true;

            return (
              <div
                key={section.name}
                className={`border rounded-lg ${isPersonal ? "border-border/50 bg-hover/30" : "border-border bg-hover/50"}`}
              >
                {/* Section header */}
                <div className="flex items-center gap-2 px-4 py-3">
                  <button
                    onClick={() => toggleSection(section.name)}
                    className="flex items-center gap-2 flex-1 text-left"
                  >
                    {isExpanded ? (
                      <ChevronDown className="w-4 h-4 text-text-tertiary" />
                    ) : (
                      <ChevronRight className="w-4 h-4 text-text-tertiary" />
                    )}
                    <span className="text-sm font-semibold text-text-primary">
                      {section.name}
                    </span>
                    {isPersonal && (
                      <span className="flex items-center gap-1 text-[10px] text-text-tertiary bg-hover px-1.5 py-0.5 rounded">
                        <EyeOff className="w-2.5 h-2.5" />
                        Personal
                      </span>
                    )}
                  </button>
                  <button
                    onClick={() => addQuickNote(section.name)}
                    className="flex items-center gap-1 text-text-tertiary hover:text-accent text-xs transition-colors px-2 py-1 rounded hover:bg-hover"
                    title="Add timestamped note"
                  >
                    <Clock className="w-3 h-3" />
                    Quick
                  </button>
                </div>

                {/* Section content */}
                {isExpanded && (
                  <div className="px-4 pb-4">
                    <textarea
                      value={section.content}
                      onChange={(e) =>
                        updateSection(section.name, e.target.value)
                      }
                      placeholder={getHint(section.name)}
                      className="w-full bg-transparent border-none text-sm text-text-primary outline-none resize-none min-h-[60px] placeholder:text-text-tertiary p-0 font-mono leading-relaxed"
                      rows={Math.max(
                        3,
                        section.content.split("\n").length + 1,
                      )}
                    />
                  </div>
                )}
              </div>
            );
          })}
        </div>

        {/* Add section */}
        {config.dailyTemplate.some(
          (t) => !sections.find((s) => s.name === t.name),
        ) && (
          <div className="mt-4">
            <select
              onChange={(e) => {
                if (e.target.value) {
                  const newSections = [
                    ...sections,
                    { name: e.target.value, content: "" },
                  ];
                  setSections(newSections);
                  save(newSections);
                  e.target.value = "";
                }
              }}
              className="text-sm text-text-secondary bg-hover border border-border rounded px-3 py-1.5"
              defaultValue=""
            >
              <option value="" disabled>
                + Add section...
              </option>
              {config.dailyTemplate
                .filter((t) => !sections.find((s) => s.name === t.name))
                .map((t) => (
                  <option key={t.name} value={t.name}>
                    {t.name}{" "}
                    {t.classification === "personal" ? "(Personal)" : ""}
                  </option>
                ))}
            </select>
          </div>
        )}
      </div>
    </div>
  );
}

function formatLogTitle(date: string): string {
  return `Daily Log: ${date}`;
}
