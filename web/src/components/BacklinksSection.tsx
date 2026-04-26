"use client";

import { useState, useEffect } from "react";
import { Link2, FileText, StickyNote, CheckCircle, ListChecks, ChevronDown, ChevronRight, Loader2 } from "lucide-react";
import type { BacklinkResult, BacklinkItem, SidebarSelection } from "@/lib/types";
import { getBacklinks } from "@/lib/db";

interface BacklinksSectionProps {
  type: "meeting" | "note" | "task" | "t5t";
  id: string;
  onNavigate: (sel: SidebarSelection) => void;
}

const TYPE_ICON: Record<string, React.ComponentType<{ className?: string }>> = {
  meeting: FileText,
  note: StickyNote,
  task: CheckCircle,
  t5t: ListChecks,
};

const TYPE_LABEL: Record<string, string> = {
  meeting: "Meetings",
  note: "Notes",
  task: "Tasks",
  t5t: "T5T Reports",
};

function toSelection(item: BacklinkItem): SidebarSelection {
  const map: Record<string, SidebarSelection> = {
    meeting: { type: "meeting", id: item.id },
    note: { type: "note", id: item.id },
    task: { type: "task", id: item.id },
    t5t: { type: "t5t", id: item.id },
  };
  return map[item.type] || null;
}

export default function BacklinksSection({ type, id, onNavigate }: BacklinksSectionProps) {
  const [result, setResult] = useState<BacklinkResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState(true);

  useEffect(() => {
    let cancelled = false;
    Promise.resolve()
      .then(() => {
        if (!cancelled) setLoading(true);
        return getBacklinks(type, id);
      })
      .then((data) => {
        if (!cancelled) setResult(data);
      })
      .catch(() => {
        if (!cancelled) setResult(null);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [type, id]);

  const groups = result
    ? ([
        { key: "meetings", items: result.meetings },
        { key: "notes", items: result.notes },
        { key: "tasks", items: result.tasks },
        { key: "t5tReports", items: result.t5tReports },
      ] as { key: string; items: BacklinkItem[] }[]).filter((g) => g.items.length > 0)
    : [];

  const totalCount = groups.reduce((s, g) => s + g.items.length, 0);

  if (loading) {
    return (
      <div className="border-t border-border mt-8 pt-6 px-1">
        <div className="flex items-center gap-2 text-text-tertiary text-sm">
          <Loader2 className="w-3.5 h-3.5 animate-spin" />
          Finding references...
        </div>
      </div>
    );
  }

  if (totalCount === 0) return null;

  return (
    <div className="border-t border-border mt-8 pt-6 px-1">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-2 text-sm font-medium text-text-secondary hover:text-text-primary transition-colors mb-3"
      >
        {expanded ? <ChevronDown className="w-3.5 h-3.5" /> : <ChevronRight className="w-3.5 h-3.5" />}
        <Link2 className="w-3.5 h-3.5" />
        Referenced by ({totalCount})
      </button>

      {expanded && (
        <div className="space-y-4 pl-1">
          {groups.map((group) => {
            const typeKey = group.key === "t5tReports" ? "t5t" : group.key.replace(/s$/, "");
            const Icon = TYPE_ICON[typeKey] || FileText;
            return (
              <div key={group.key}>
                <div className="flex items-center gap-1.5 mb-1.5">
                  <Icon className="w-3 h-3 text-text-tertiary" />
                  <span className="text-xs font-medium text-text-tertiary uppercase tracking-wide">
                    {TYPE_LABEL[typeKey] || group.key}
                  </span>
                </div>
                <div className="space-y-1">
                  {group.items.map((item) => (
                    <button
                      key={item.id}
                      onClick={() => onNavigate(toSelection(item))}
                      className="flex items-start gap-2 w-full px-3 py-1.5 rounded text-left hover:bg-hover transition-colors"
                    >
                      <span className="text-sm text-text-primary truncate flex-1">{item.title}</span>
                      <div className="flex gap-1 flex-shrink-0 mt-0.5">
                        {item.matchedTerms.slice(0, 3).map((term) => (
                          <span
                            key={term}
                            className="text-[10px] px-1.5 py-0.5 rounded-full bg-accent/15 text-accent"
                          >
                            {term}
                          </span>
                        ))}
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
