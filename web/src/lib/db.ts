import type { T5TConfig } from "./types";

/* eslint-disable @typescript-eslint/no-explicit-any */
type Row = Record<string, any>;
/* eslint-enable @typescript-eslint/no-explicit-any */

async function api(path: string, options?: RequestInit) {
  const res = await fetch(path, options);
  return res.json();
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
  chatMessages: {
    async toArray() { return api("/api/data/chatMessages"); },
    async add(data: Row) { return api("/api/data/chatMessages", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }); },
    async delete(id: string) { return api(`/api/data/chatMessages?id=${id}`, { method: "DELETE" }); },
    async clear() { return api("/api/data/chatMessages?confirm=true", { method: "DELETE" }); },
  },
};

export async function getBacklinks(type: string, id: string) {
  return api(`/api/backlinks?type=${encodeURIComponent(type)}&id=${encodeURIComponent(id)}`);
}

export async function getSetting(key: string): Promise<string | undefined> {
  const data = await api(`/api/settings?key=${encodeURIComponent(key)}`);
  return data.value ?? undefined;
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
  if (v) return JSON.parse(v);
  return { vertical: "", region: "", jobFunction: "", subjectLine: "" };
}

export async function saveT5TConfig(config: T5TConfig): Promise<void> {
  await setSetting("t5t_config", JSON.stringify(config));
}
