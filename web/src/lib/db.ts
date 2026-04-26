import type { T5TConfig } from "./types";
import { DEFAULT_T5T_CONFIG } from "./types";

/* eslint-disable @typescript-eslint/no-explicit-any */
type Row = Record<string, any>;
/* eslint-enable @typescript-eslint/no-explicit-any */

async function api(path: string, options?: RequestInit) {
  const res = await fetch(path, options);
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    const message =
      data && typeof data === "object" && "error" in data && typeof data.error === "string"
        ? data.error
        : `Request failed with status ${res.status}`;
    throw new Error(message);
  }
  return data;
}

export const db = {
  meetings: {
    async toArray() { return api("/api/data/meetings"); },
    async get(id: string) { return api(`/api/data/meetings?id=${id}`); },
    async add(data: Row) { return api("/api/data/meetings", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async put(data: Row) { return api("/api/data/meetings", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async update(id: string, changes: Row) { return api("/api/data/meetings", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id, ...changes }) }); },
    async delete(id: string) { return api(`/api/data/meetings?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/meetings?confirm=true", { method: "DELETE" }); },
    async bulkPut(rows: Row[]) { return api("/api/data/meetings", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(rows) }); },
  },
  notes: {
    async toArray() { return api("/api/data/notes"); },
    async get(id: string) { return api(`/api/data/notes?id=${id}`); },
    async add(data: Row) { return api("/api/data/notes", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async put(data: Row) { return api("/api/data/notes", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async update(id: string, changes: Row) { return api("/api/data/notes", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id, ...changes }) }); },
    async delete(id: string) { return api(`/api/data/notes?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/notes?confirm=true", { method: "DELETE" }); },
    async bulkPut(rows: Row[]) { return api("/api/data/notes", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(rows) }); },
  },
  tasks: {
    async toArray() { return api("/api/data/tasks"); },
    async get(id: string) { return api(`/api/data/tasks?id=${id}`); },
    async add(data: Row) { return api("/api/data/tasks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async put(data: Row) { return api("/api/data/tasks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async update(id: string, changes: Row) { return api("/api/data/tasks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id, ...changes }) }); },
    async delete(id: string) { return api(`/api/data/tasks?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/tasks?confirm=true", { method: "DELETE" }); },
    async bulkPut(rows: Row[]) { return api("/api/data/tasks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(rows) }); },
  },
  t5tReports: {
    async toArray() { return api("/api/data/t5tReports"); },
    async get(id: string) { return api(`/api/data/t5tReports?id=${id}`); },
    async add(data: Row) { return api("/api/data/t5tReports", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async put(data: Row) { return api("/api/data/t5tReports", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async update(id: string, changes: Row) { return api("/api/data/t5tReports", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id, ...changes }) }); },
    async delete(id: string) { return api(`/api/data/t5tReports?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/t5tReports?confirm=true", { method: "DELETE" }); },
    async bulkPut(rows: Row[]) { return api("/api/data/t5tReports", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(rows) }); },
  },
  dailyLogs: {
    async toArray() { return api("/api/data/dailyLogs"); },
    async get(id: string) { return api(`/api/data/dailyLogs?id=${id}`); },
    async add(data: Row) { return api("/api/data/dailyLogs", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async put(data: Row) { return api("/api/data/dailyLogs", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async update(id: string, changes: Row) { return api("/api/data/dailyLogs", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id, ...changes }) }); },
    async delete(id: string) { return api(`/api/data/dailyLogs?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/dailyLogs?confirm=true", { method: "DELETE" }); },
    async bulkPut(rows: Row[]) { return api("/api/data/dailyLogs", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(rows) }); },
  },
  chatMessages: {
    async toArray() { return api("/api/data/chatMessages"); },
    async add(data: Row) { return api("/api/data/chatMessages", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async delete(id: string) { return api(`/api/data/chatMessages?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/chatMessages?confirm=true", { method: "DELETE" }); },
  },
  todos: {
    async toArray() { return api("/api/data/todos"); },
    async get(id: string) { return api(`/api/data/todos?id=${id}`); },
    async add(data: Row) { return api("/api/data/todos", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async put(data: Row) { return api("/api/data/todos", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async update(id: string, changes: Row) { return api("/api/data/todos", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id, ...changes }) }); },
    async delete(id: string) { return api(`/api/data/todos?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/todos?confirm=true", { method: "DELETE" }); },
    async bulkPut(rows: Row[]) { return api("/api/data/todos", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(rows) }); },
  },
};

export async function getBacklinks(type: string, id: string) {
  return api(`/api/backlinks?type=${encodeURIComponent(type)}&id=${encodeURIComponent(id)}`);
}

export async function getSetting(key: string): Promise<string | undefined> {
  const data = await api(`/api/settings?key=${encodeURIComponent(key)}`);
  return data.value ?? undefined;
}

export async function isSettingConfigured(key: string): Promise<boolean> {
  const data = await api(`/api/settings?key=${encodeURIComponent(key)}`);
  return Boolean(data.configured);
}

export async function setSetting(key: string, value: string): Promise<void> {
  await api("/api/settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key, value }),
  });
}

export async function getT5TConfig(): Promise<T5TConfig> {
  const v = await getSetting("t5t_config");
  if (!v) return { ...DEFAULT_T5T_CONFIG };
  try {
    const parsed = JSON.parse(v);
    // Detect old v2 format (has "vertical" key) and return defaults
    if ("vertical" in parsed && !("identity" in parsed)) {
      return { ...DEFAULT_T5T_CONFIG };
    }
    // Merge with defaults to fill any missing fields
    return { ...DEFAULT_T5T_CONFIG, ...parsed };
  } catch {
    return { ...DEFAULT_T5T_CONFIG };
  }
}

export async function saveT5TConfig(config: T5TConfig): Promise<void> {
  await setSetting("t5t_config", JSON.stringify(config));
}
