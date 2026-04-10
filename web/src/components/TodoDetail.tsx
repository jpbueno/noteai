"use client";

import { useState, useEffect, useCallback } from "react";
import { CheckSquare, Square, Save, Loader2, Calendar, X } from "lucide-react";
import type { TodoItem } from "@/lib/types";
import { db } from "@/lib/db";
import { formatDateTime, triggerRefresh } from "@/lib/hooks";

interface TodoDetailProps {
  todo: TodoItem;
}

function isDueOverdue(dueDate: string | null): boolean {
  if (!dueDate) return false;
  const due = new Date(dueDate);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return due < today;
}

function isDueSoon(dueDate: string | null): boolean {
  if (!dueDate) return false;
  const due = new Date(dueDate);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const twoDays = new Date(today);
  twoDays.setDate(twoDays.getDate() + 2);
  return due >= today && due <= twoDays;
}

function formatDueLabel(dueDate: string): string {
  const due = new Date(dueDate);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const tomorrow = new Date(today);
  tomorrow.setDate(tomorrow.getDate() + 1);
  const dueDay = new Date(due);
  dueDay.setHours(0, 0, 0, 0);

  if (dueDay.getTime() === today.getTime()) return "Today";
  if (dueDay.getTime() === tomorrow.getTime()) return "Tomorrow";

  const diff = Math.floor((dueDay.getTime() - today.getTime()) / 86400000);
  if (diff < 0) return `${Math.abs(diff)}d overdue`;
  if (diff <= 7) return `In ${diff} days`;
  return due.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export default function TodoDetail({ todo }: TodoDetailProps) {
  const [title, setTitle] = useState(todo.title);
  const [description, setDescription] = useState(todo.description);
  const [completed, setCompleted] = useState(!!todo.completed);
  const [dueDate, setDueDate] = useState(todo.dueDate || "");
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setTitle(todo.title);
    setDescription(todo.description);
    setCompleted(!!todo.completed);
    setDueDate(todo.dueDate || "");
    setDirty(false);
  }, [todo.id, todo.title, todo.description, todo.completed, todo.dueDate]);

  const handleSave = useCallback(async () => {
    setSaving(true);
    await db.todos.update(todo.id, {
      title,
      description,
      dueDate: dueDate || null,
      modifiedDate: new Date().toISOString(),
    });
    triggerRefresh();
    setDirty(false);
    setSaving(false);
  }, [todo.id, title, description, dueDate]);

  const toggleCompleted = useCallback(async () => {
    const newVal = !completed;
    setCompleted(newVal);
    await db.todos.update(todo.id, {
      completed: newVal ? 1 : 0,
      modifiedDate: new Date().toISOString(),
    });
    triggerRefresh();
  }, [todo.id, completed]);

  const overdue = !completed && isDueOverdue(dueDate || null);
  const dueSoon = !completed && isDueSoon(dueDate || null);

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-3xl mx-auto px-12 py-10">
        <div className="flex items-start gap-3 mb-3">
          <button onClick={toggleCompleted} className="mt-2.5 flex-shrink-0">
            {completed ? (
              <CheckSquare className="w-6 h-6 text-green-500" />
            ) : (
              <Square className="w-6 h-6 text-text-tertiary hover:text-accent transition-colors" />
            )}
          </button>
          <input
            type="text"
            value={title}
            onChange={(e) => { setTitle(e.target.value); setDirty(true); }}
            placeholder="Todo title"
            className="flex-1 text-[40px] font-bold bg-transparent border-none outline-none text-text-primary placeholder:text-text-tertiary"
          />
        </div>

        <div className="flex items-center gap-4 text-xs text-text-tertiary mb-4 pl-9">
          <span>Created {formatDateTime(todo.createdDate)}</span>
          <span
            className={`px-2 py-0.5 rounded text-xs font-medium ${
              completed
                ? "bg-green-500/20 text-green-400"
                : "bg-orange-500/20 text-orange-400"
            }`}
          >
            {completed ? "Done" : "Pending"}
          </span>
          {dueDate && !completed && (
            <span
              className={`px-2 py-0.5 rounded text-xs font-medium ${
                overdue
                  ? "bg-red-500/20 text-red-400"
                  : dueSoon
                    ? "bg-yellow-500/20 text-yellow-400"
                    : "bg-blue-500/20 text-blue-400"
              }`}
            >
              {formatDueLabel(dueDate)}
            </span>
          )}
        </div>

        <div className="border-t border-border mb-6" />

        {/* Due Date */}
        <div className="mb-6">
          <h3 className="text-sm font-medium text-text-secondary mb-3">Due Date</h3>
          <div className="flex items-center gap-2">
            <Calendar className="w-4 h-4 text-text-tertiary" />
            <input
              type="date"
              value={dueDate}
              onChange={(e) => { setDueDate(e.target.value); setDirty(true); }}
              className="bg-hover border border-border rounded-md text-sm text-text-primary px-3 py-1.5 outline-none focus:border-accent"
            />
            {dueDate && (
              <button
                onClick={() => { setDueDate(""); setDirty(true); }}
                className="text-text-tertiary hover:text-text-secondary"
                title="Clear due date"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            )}
          </div>
        </div>

        {/* Description */}
        <div className="mb-6">
          <h3 className="text-sm font-medium text-text-secondary mb-3">Description</h3>
          <textarea
            value={description}
            onChange={(e) => { setDescription(e.target.value); setDirty(true); }}
            placeholder="Add a description..."
            className="w-full min-h-[200px] bg-hover border border-border rounded-md text-[15px] text-text-primary p-3 outline-none resize-none placeholder:text-text-tertiary focus:border-accent"
          />
        </div>

        <div className="pt-6 border-t border-border">
          <button
            onClick={handleSave}
            disabled={!dirty || saving}
            className="flex items-center gap-2 px-4 py-2 rounded-md bg-accent text-white text-sm font-medium hover:bg-accent/80 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <Save className="w-4 h-4" />}
            {saving ? "Saving..." : dirty ? "Save" : "Saved"}
          </button>
        </div>
      </div>
    </div>
  );
}
