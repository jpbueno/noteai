"use client";

import { useMemo } from "react";
import { CheckSquare, Square, Calendar, Circle, Plus, Activity, Clock, ListTodo } from "lucide-react";
import type { TodoItem, SidebarSelection } from "@/lib/types";
import { db } from "@/lib/db";
import { parseDueDate, triggerRefresh } from "@/lib/hooks";

interface HomeDashboardProps {
  todos: TodoItem[];
  onSelect: (sel: SidebarSelection) => void;
  onNewTodo: () => void;
}

function getDueDateInfo(dueDate: string | null, completed: boolean) {
  if (!dueDate) return { label: null, color: "" };
  const due = parseDueDate(dueDate);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const tomorrow = new Date(today);
  tomorrow.setDate(tomorrow.getDate() + 1);
  const dueDay = new Date(due);
  dueDay.setHours(0, 0, 0, 0);

  if (completed) {
    return { label: due.toLocaleDateString("en-US", { month: "short", day: "numeric" }), color: "text-text-tertiary" };
  }

  const diff = Math.floor((dueDay.getTime() - today.getTime()) / 86400000);

  if (diff < 0) return { label: `${Math.abs(diff)}d overdue`, color: "text-red-400" };
  if (diff === 0) return { label: "Today", color: "text-yellow-400" };
  if (diff === 1) return { label: "Tomorrow", color: "text-yellow-400" };
  if (diff <= 7) return { label: `In ${diff} days`, color: "text-blue-400" };
  return { label: due.toLocaleDateString("en-US", { month: "short", day: "numeric" }), color: "text-text-tertiary" };
}

export default function HomeDashboard({ todos, onSelect, onNewTodo }: HomeDashboardProps) {
  const { overdue, today: todayTodos, upcoming, noDue, completed } = useMemo(() => {
    const now = new Date();
    now.setHours(0, 0, 0, 0);
    const tomorrow = new Date(now);
    tomorrow.setDate(tomorrow.getDate() + 1);

    const overdue: TodoItem[] = [];
    const today: TodoItem[] = [];
    const upcoming: TodoItem[] = [];
    const noDue: TodoItem[] = [];
    const completed: TodoItem[] = [];

    for (const t of todos) {
      if (t.completed) {
        completed.push(t);
        continue;
      }
      if (!t.dueDate) {
        noDue.push(t);
        continue;
      }
      const due = parseDueDate(t.dueDate);
      due.setHours(0, 0, 0, 0);
      if (due < now) overdue.push(t);
      else if (due.getTime() === now.getTime()) today.push(t);
      else upcoming.push(t);
    }

    // Sort upcoming by due date ascending
    upcoming.sort((a, b) => parseDueDate(a.dueDate!).getTime() - parseDueDate(b.dueDate!).getTime());
    // Sort completed by modification date descending (most recent first)
    completed.sort((a, b) => new Date(b.modifiedDate).getTime() - new Date(a.modifiedDate).getTime());

    return { overdue, today, upcoming, noDue, completed };
  }, [todos]);

  const toggleCompleted = async (todo: TodoItem, e: React.MouseEvent) => {
    e.stopPropagation();
    await db.todos.update(todo.id, {
      completed: todo.completed ? 0 : 1,
      modifiedDate: new Date().toISOString(),
    });
    triggerRefresh();
  };

  const pendingCount = overdue.length + todayTodos.length + upcoming.length + noDue.length;
  const focusCount = overdue.length + todayTodos.length;
  const nextTask = overdue[0] || todayTodos[0] || upcoming[0] || noDue[0] || null;

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-6xl px-8 py-8">
        <div className="mb-6 flex items-center justify-between">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.16em] text-text-tertiary">
              Command Center
            </p>
            <h1 className="mt-1 text-[34px] font-bold leading-tight tracking-[-0.02em] text-text-primary">
              Today&apos;s workspace
            </h1>
            <p className="mt-1 text-sm text-text-tertiary">
              Keep meetings, notes, tasks, and T5T follow-ups moving from one place.
            </p>
          </div>
          <button
            onClick={onNewTodo}
            className="flex h-10 items-center gap-2 rounded-xl bg-accent px-3.5 text-sm font-bold text-black hover:bg-accent/85 transition-colors"
          >
            <Plus className="w-3.5 h-3.5" />
            New Task
          </button>
        </div>

        <section className="mb-5 grid grid-cols-1 gap-4 lg:grid-cols-[1.15fr_0.85fr]">
          <div className="v4-panel p-6">
            <div className="flex items-start justify-between gap-4">
              <div>
                <h2 className="text-xl font-bold text-text-primary">Operational snapshot</h2>
                <p className="mt-1 text-sm text-text-tertiary">
                  {pendingCount} pending{completed.length > 0 ? ` · ${completed.length} completed` : ""}
                </p>
              </div>
              <span className="rounded-full bg-accent/12 px-3 py-1 text-xs font-bold text-accent">
                v4
              </span>
            </div>
            <div className="mt-6 grid grid-cols-2 gap-3 md:grid-cols-4">
              <Metric icon={<Activity className="h-4 w-4" />} label="Focus queue" value={focusCount} />
              <Metric icon={<ListTodo className="h-4 w-4" />} label="Open tasks" value={pendingCount} />
              <Metric icon={<CheckSquare className="h-4 w-4" />} label="Completed" value={completed.length} />
              <Metric icon={<Clock className="h-4 w-4" />} label="Upcoming" value={upcoming.length} />
            </div>
          </div>

          <div className="v4-panel p-6">
            <div className="flex items-center justify-between gap-3">
              <h2 className="text-base font-bold text-text-primary">Suggested next move</h2>
              <Circle className="h-2.5 w-2.5 fill-accent text-accent" />
            </div>
            {nextTask ? (
              <button
                onClick={() => onSelect({ type: "todo", id: nextTask.id })}
                className="mt-4 block w-full rounded-xl border border-border bg-content/50 p-4 text-left transition-colors hover:border-accent/45 hover:bg-hover"
              >
                <span className="text-sm font-bold text-text-primary">{nextTask.title || "Untitled task"}</span>
                <span className="mt-1 block text-xs text-text-tertiary">
                  {nextTask.dueDate ? getDueDateInfo(nextTask.dueDate, !!nextTask.completed).label : "No due date"}
                </span>
              </button>
            ) : (
              <p className="mt-4 text-sm text-text-tertiary">No pending tasks. The workspace is clear.</p>
            )}
          </div>
        </section>

        <section className="grid grid-cols-1 gap-4 xl:grid-cols-2">
          <TaskColumn title="Focus Queue" subtitle="Overdue and due today" tone="danger">
            {[...overdue, ...todayTodos].map((t) => (
              <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
            ))}
            {focusCount === 0 && <EmptyColumn text="No urgent tasks" />}
          </TaskColumn>

          <TaskColumn title="Upcoming" subtitle="Next work to prepare" tone="accent">
            {[...upcoming.slice(0, 8), ...noDue.slice(0, 4)].map((t) => (
              <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
            ))}
            {upcoming.length + noDue.length === 0 && <EmptyColumn text="No upcoming tasks" />}
          </TaskColumn>

          {completed.length > 0 && (
            <div className="xl:col-span-2">
              <TaskColumn title="Recently Completed" subtitle="Latest closed loops" tone="done">
                {completed.slice(0, 6).map((t) => (
                  <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
                ))}
              </TaskColumn>
            </div>
          )}
        </section>

      </div>
    </div>
  );
}

function Metric({
  icon,
  label,
  value,
}: {
  icon: React.ReactNode;
  label: string;
  value: number;
}) {
  return (
    <div className="rounded-xl border border-border bg-content/55 p-3">
      <div className="flex items-center gap-2 text-text-tertiary">
        {icon}
        <span className="text-xs font-medium">{label}</span>
      </div>
      <div className="mt-2 text-2xl font-bold text-text-primary">{value}</div>
    </div>
  );
}

function TaskColumn({
  title,
  subtitle,
  tone,
  children,
}: {
  title: string;
  subtitle: string;
  tone: "danger" | "accent" | "done";
  children: React.ReactNode;
}) {
  const toneClass =
    tone === "danger"
      ? "bg-danger text-danger"
      : tone === "done"
        ? "bg-green-400 text-green-400"
        : "bg-accent text-accent";

  return (
    <div className="v4-panel p-4">
      <div className="mb-3 flex items-center gap-2">
        <Circle className={`h-2.5 w-2.5 fill-current ${toneClass}`} />
        <div>
          <h2 className="text-sm font-bold text-text-primary">{title}</h2>
          <p className="text-xs text-text-tertiary">{subtitle}</p>
        </div>
      </div>
      <div className="space-y-2">{children}</div>
    </div>
  );
}

function EmptyColumn({ text }: { text: string }) {
  return (
    <div className="rounded-xl border border-dashed border-border px-4 py-8 text-center text-sm text-text-tertiary">
      {text}
    </div>
  );
}

function TaskRow({
  todo,
  onSelect,
  onToggle,
}: {
  todo: TodoItem;
  onSelect: (sel: SidebarSelection) => void;
  onToggle: (todo: TodoItem, e: React.MouseEvent) => void;
}) {
  const { label: dueLabel, color: dueColor } = getDueDateInfo(todo.dueDate, !!todo.completed);

  return (
    <button
      onClick={() => onSelect({ type: "todo", id: todo.id })}
      className="v4-row group flex w-full items-center gap-3 px-3 py-3 text-left transition-colors hover:border-accent/35 hover:bg-hover"
    >
      <span
        onClick={(e) => onToggle(todo, e)}
        className="flex-shrink-0"
      >
        {todo.completed ? (
          <CheckSquare className="w-[18px] h-[18px] text-green-400" />
        ) : (
          <Square className="w-[18px] h-[18px] text-text-tertiary group-hover:text-accent transition-colors" />
        )}
      </span>
      <span
        className={`flex-1 text-sm font-semibold truncate ${
          todo.completed ? "text-text-tertiary line-through" : "text-text-primary"
        }`}
      >
        {todo.title || "Untitled"}
      </span>
      {dueLabel && (
        <span className={`flex items-center gap-1 text-xs ${dueColor} flex-shrink-0`}>
          <Calendar className="w-3 h-3" />
          {dueLabel}
        </span>
      )}
    </button>
  );
}
