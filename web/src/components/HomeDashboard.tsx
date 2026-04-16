"use client";

import { useMemo } from "react";
import { CheckSquare, Square, Calendar, Circle, Plus } from "lucide-react";
import type { TodoItem, SidebarSelection } from "@/lib/types";
import { db } from "@/lib/db";
import { triggerRefresh } from "@/lib/hooks";

interface HomeDashboardProps {
  todos: TodoItem[];
  onSelect: (sel: SidebarSelection) => void;
  onNewTodo: () => void;
}

function getDueDateInfo(dueDate: string | null, completed: boolean) {
  if (!dueDate) return { label: null, color: "" };
  const due = new Date(dueDate);
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
      const due = new Date(t.dueDate);
      due.setHours(0, 0, 0, 0);
      if (due < now) overdue.push(t);
      else if (due.getTime() === now.getTime()) today.push(t);
      else upcoming.push(t);
    }

    // Sort upcoming by due date ascending
    upcoming.sort((a, b) => new Date(a.dueDate!).getTime() - new Date(b.dueDate!).getTime());
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

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-2xl mx-auto px-12 py-10">
        {/* Header */}
        <div className="flex items-center justify-between mb-8">
          <div>
            <h1 className="text-2xl font-bold text-text-primary">Tasks</h1>
            <p className="text-sm text-text-tertiary mt-1">
              {pendingCount} pending{completed.length > 0 ? ` · ${completed.length} completed` : ""}
            </p>
          </div>
          <button
            onClick={onNewTodo}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-accent text-white text-sm font-medium hover:bg-accent/80 transition-colors"
          >
            <Plus className="w-3.5 h-3.5" />
            New Task
          </button>
        </div>

        {/* Overdue */}
        {overdue.length > 0 && (
          <TaskGroup label="Overdue" color="text-red-400" dotColor="bg-red-400">
            {overdue.map((t) => (
              <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
            ))}
          </TaskGroup>
        )}

        {/* Today */}
        {todayTodos.length > 0 && (
          <TaskGroup label="Today" color="text-yellow-400" dotColor="bg-yellow-400">
            {todayTodos.map((t) => (
              <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
            ))}
          </TaskGroup>
        )}

        {/* Upcoming */}
        {upcoming.length > 0 && (
          <TaskGroup label="Upcoming" color="text-blue-400" dotColor="bg-blue-400">
            {upcoming.map((t) => (
              <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
            ))}
          </TaskGroup>
        )}

        {/* No due date */}
        {noDue.length > 0 && (
          <TaskGroup label="No Due Date" color="text-text-tertiary" dotColor="bg-text-tertiary">
            {noDue.map((t) => (
              <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
            ))}
          </TaskGroup>
        )}

        {/* Completed */}
        {completed.length > 0 && (
          <TaskGroup label="Completed" color="text-text-tertiary" dotColor="bg-green-500" dimmed>
            {completed.map((t) => (
              <TaskRow key={t.id} todo={t} onSelect={onSelect} onToggle={toggleCompleted} />
            ))}
          </TaskGroup>
        )}

        {/* Empty state */}
        {todos.length === 0 && (
          <div className="flex flex-col items-center justify-center py-20 gap-3">
            <CheckSquare className="w-9 h-9 text-text-tertiary" />
            <p className="text-base font-medium text-text-secondary">No tasks yet</p>
            <p className="text-xs text-text-tertiary">Create your first task to get started</p>
          </div>
        )}
      </div>
    </div>
  );
}

function TaskGroup({
  label,
  color,
  dotColor,
  dimmed,
  children,
}: {
  label: string;
  color: string;
  dotColor: string;
  dimmed?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className={`mb-6 ${dimmed ? "opacity-60" : ""}`}>
      <div className="flex items-center gap-2 mb-2">
        <Circle className={`w-2 h-2 ${dotColor} fill-current`} />
        <span className={`text-xs font-semibold uppercase tracking-wide ${color}`}>{label}</span>
      </div>
      <div className="space-y-px">{children}</div>
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
      className="flex items-center gap-3 w-full px-3 py-2.5 rounded-lg hover:bg-hover transition-colors text-left group"
    >
      <span
        onClick={(e) => onToggle(todo, e)}
        className="flex-shrink-0"
      >
        {todo.completed ? (
          <CheckSquare className="w-[18px] h-[18px] text-green-500" />
        ) : (
          <Square className="w-[18px] h-[18px] text-text-tertiary group-hover:text-accent transition-colors" />
        )}
      </span>
      <span
        className={`flex-1 text-sm font-medium truncate ${
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
