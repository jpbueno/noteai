import { db } from "./db";
import type { ChatMessage, Meeting, Note, T5TReport, TaskItem } from "./types";

export type EntityRepository<T extends { id: string }> = {
  all(): Promise<T[]>;
  get(id: string): Promise<T | null>;
  save(item: T): Promise<void>;
  update(id: string, changes: Partial<T>): Promise<void>;
  delete(id: string): Promise<void>;
};

function repository<T extends { id: string }>(table: {
  toArray: () => Promise<unknown>;
  get?: (id: string) => Promise<unknown>;
  add: (data: Record<string, unknown>) => Promise<unknown>;
  update?: (id: string, changes: Record<string, unknown>) => Promise<unknown>;
  delete: (id: string) => Promise<unknown>;
}): EntityRepository<T> {
  return {
    async all() {
      return (await table.toArray()) as T[];
    },
    async get(id: string) {
      if (!table.get) return null;
      return ((await table.get(id)) as T | null) || null;
    },
    async save(item: T) {
      await table.add(item as Record<string, unknown>);
    },
    async update(id: string, changes: Partial<T>) {
      if (table.update) {
        await table.update(id, changes as Record<string, unknown>);
      } else {
        await table.add({ id, ...(changes as Record<string, unknown>) });
      }
    },
    async delete(id: string) {
      await table.delete(id);
    },
  };
}

export const repositories = {
  meetings: repository<Meeting>(db.meetings),
  notes: repository<Note>(db.notes),
  tasks: repository<TaskItem>(db.tasks),
  t5tReports: repository<T5TReport>(db.t5tReports),
  chatMessages: repository<ChatMessage>(db.chatMessages),
};

