#!/usr/bin/env node
import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SWIFT_REFERENCE_UNIX_SECONDS = 978307200;
const DEFAULT_TABLES = ["meetings", "notes", "tasks", "todos", "t5tReports"];
const JSON_COLS = {
  meetings: ["transcript", "summary"],
  notes: ["tags"],
  tasks: ["tags"],
  t5tReports: ["meetingIDs", "noteIDs", "taskIDs", "dailyLogIDs", "sections"],
};

export function parseDotEnv(text) {
  const normalized = text.replace(/\\n/g, "\n");
  const env = {};
  for (const rawLine of normalized.split(/\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const index = line.indexOf("=");
    if (index < 0) continue;
    const key = line.slice(0, index).trim();
    let value = line.slice(index + 1).trim();
    value = value.replace(/^['"]|['"]$/g, "");
    env[key] = value;
  }
  return env;
}

export function parseWebDate(value, fieldName = "date") {
  if (value instanceof Date) return value;
  if (typeof value === "number") return new Date(value * 1000);
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Missing ${fieldName}`);
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error(`Invalid ${fieldName}: ${value}`);
  }
  return parsed;
}

export function unixSeconds(value, fieldName = "date") {
  return parseWebDate(value, fieldName).getTime() / 1000;
}

export function swiftReferenceSeconds(value, fieldName = "date") {
  return unixSeconds(value, fieldName) - SWIFT_REFERENCE_UNIX_SECONDS;
}

export function uuid(value, fieldName = "id") {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Missing ${fieldName}`);
  }
  return value.toUpperCase();
}

function jsonArray(value, fallback = []) {
  if (Array.isArray(value)) return value;
  if (typeof value === "string" && value.trim()) {
    try {
      const parsed = JSON.parse(value);
      return Array.isArray(parsed) ? parsed : fallback;
    } catch {
      return fallback;
    }
  }
  return fallback;
}

function jsonObject(value, fallback = {}) {
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  if (typeof value === "string" && value.trim()) {
    try {
      const parsed = JSON.parse(value);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : fallback;
    } catch {
      return fallback;
    }
  }
  return fallback;
}

function nullableUuid(value, fieldName) {
  return value ? uuid(String(value), fieldName) : null;
}

function safeNumber(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function optionalSwiftDate(value, fieldName) {
  if (value === null || value === undefined || value === "") return null;
  return swiftReferenceSeconds(value, fieldName);
}

function entryFromWebSection(section) {
  const name = typeof section?.name === "string" && section.name.trim() ? section.name.trim() : "Update";
  const content = typeof section?.content === "string" ? section.content.trim() : "";
  return {
    id: uuid(globalThis.crypto.randomUUID()),
    headline: name,
    explanation: content,
  };
}

export function t5tSectionsFromWeb(sections) {
  const byKey = new Map();
  for (const section of jsonArray(sections)) {
    const id = typeof section?.id === "string" ? section.id.toLowerCase() : "";
    const name = typeof section?.name === "string" ? section.name.toLowerCase() : "";
    const key = id || name;
    if (key.includes("insight") || key.includes("management") || key.includes("competition")) {
      byKey.set("insights", [...(byKey.get("insights") || []), entryFromWebSection(section)]);
    } else if (key.includes("account") || key.includes("update") || key.includes("project")) {
      byKey.set("accountUpdates", [...(byKey.get("accountUpdates") || []), entryFromWebSection(section)]);
    } else if (key.includes("future") || key.includes("next")) {
      byKey.set("futurePlans", [...(byKey.get("futurePlans") || []), entryFromWebSection(section)]);
    }
  }
  return {
    insights: byKey.get("insights") || [],
    accountUpdates: byKey.get("accountUpdates") || [],
    futurePlans: byKey.get("futurePlans") || [],
  };
}

export function macMeeting(row) {
  const summary = jsonObject(row.summary, {});
  return {
    id: uuid(row.id),
    title: String(row.title || "Untitled Meeting"),
    date: swiftReferenceSeconds(row.date, "meeting.date"),
    duration: safeNumber(row.duration),
    transcript: jsonArray(row.transcript).map((segment, index) => ({
      id: Number.isInteger(segment?.id) ? segment.id : index + 1,
      text: String(segment?.text || ""),
      startTime: safeNumber(segment?.startTime),
      endTime: safeNumber(segment?.endTime),
      speaker: segment?.speaker || null,
      confidence: safeNumber(segment?.confidence),
    })),
    summary: {
      decisions: jsonArray(summary.decisions).map(String),
      actionItems: jsonArray(summary.actionItems).map((item) => ({
        id: typeof item?.id === "string" && item.id ? item.id : uuid(globalThis.crypto.randomUUID()),
        task: String(item?.task || ""),
        owner: item?.owner || null,
        deadline: item?.deadline || null,
        isCompleted: Boolean(item?.isCompleted),
      })),
      topics: jsonArray(summary.topics).map(String),
      openQuestions: jsonArray(summary.openQuestions).map(String),
      wasSummarized: Boolean(summary.wasSummarized),
    },
  };
}

export function macNote(row) {
  return {
    id: uuid(row.id),
    title: String(row.title || "Untitled"),
    content: String(row.content || ""),
    tags: jsonArray(row.tags).map(String),
    createdDate: swiftReferenceSeconds(row.createdDate, "note.createdDate"),
    modifiedDate: swiftReferenceSeconds(row.modifiedDate, "note.modifiedDate"),
    sourceMeetingID: nullableUuid(row.sourceMeetingID, "note.sourceMeetingID"),
  };
}

export function macTask(row) {
  return {
    id: uuid(row.id),
    title: String(row.title || ""),
    description: String(row.description || ""),
    rawInput: String(row.rawInput || ""),
    tags: jsonArray(row.tags).map(String),
    status: row.status === "completed" ? "completed" : "pending",
    createdDate: swiftReferenceSeconds(row.createdDate, "task.createdDate"),
    modifiedDate: swiftReferenceSeconds(row.modifiedDate, "task.modifiedDate"),
    sourceMeetingID: nullableUuid(row.sourceMeetingID, "task.sourceMeetingID"),
    sourceNoteID: nullableUuid(row.sourceNoteID, "task.sourceNoteID"),
  };
}

export function macTodo(row) {
  return {
    id: uuid(row.id),
    title: String(row.title || ""),
    description: String(row.description || ""),
    completed: Boolean(Number(row.completed)),
    dueDate: optionalSwiftDate(row.dueDate, "todo.dueDate"),
    createdDate: swiftReferenceSeconds(row.createdDate, "todo.createdDate"),
    modifiedDate: swiftReferenceSeconds(row.modifiedDate, "todo.modifiedDate"),
  };
}

export function macT5TReport(row) {
  const meetingIDs = jsonArray(row.meetingIDs).map((id) => uuid(String(id), "t5t.meetingIDs"));
  const noteIDs = jsonArray(row.noteIDs).map((id) => uuid(String(id), "t5t.noteIDs"));
  const taskIDs = jsonArray(row.taskIDs).map((id) => uuid(String(id), "t5t.taskIDs"));
  const todoIDs = jsonArray(row.todoIDs || row.taskIDs).map((id) => uuid(String(id), "t5t.todoIDs"));
  return {
    id: uuid(row.id),
    title: String(row.title || "Top 5 Things"),
    createdDate: swiftReferenceSeconds(row.createdDate, "t5t.createdDate"),
    periodStart: swiftReferenceSeconds(row.periodStart, "t5t.periodStart"),
    periodEnd: swiftReferenceSeconds(row.periodEnd, "t5t.periodEnd"),
    meetingIDs,
    noteIDs,
    taskIDs,
    todoIDs,
    sections: t5tSectionsFromWeb(row.sections),
    status: row.status === "finalized" ? "finalized" : "draft",
  };
}

function sqlString(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replaceAll("'", "''")}'`;
}

function sqlNumber(value) {
  if (value === null || value === undefined) return "NULL";
  const number = Number(value);
  if (!Number.isFinite(number)) throw new Error(`Invalid SQL number: ${value}`);
  return String(number);
}

function insertStatement(table, values) {
  const columns = Object.keys(values);
  return `INSERT OR REPLACE INTO ${table} (${columns.join(", ")}) VALUES (${columns.map((column) => {
    const value = values[column];
    return typeof value === "number" ? sqlNumber(value) : sqlString(value);
  }).join(", ")});`;
}

const schemaSql = [
  "CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, title TEXT NOT NULL, date REAL NOT NULL, duration REAL NOT NULL, json_data TEXT NOT NULL);",
  "CREATE TABLE IF NOT EXISTS t5t_reports (id TEXT PRIMARY KEY, created_date REAL NOT NULL, period_start REAL NOT NULL, period_end REAL NOT NULL, status TEXT NOT NULL DEFAULT 'draft', json_data TEXT NOT NULL);",
  "CREATE TABLE IF NOT EXISTS t5t_config (id INTEGER PRIMARY KEY CHECK (id = 1), json_data TEXT NOT NULL);",
  "CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, modified_date REAL NOT NULL, json_data TEXT NOT NULL);",
  "CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, modified_date REAL NOT NULL, status TEXT NOT NULL DEFAULT 'pending', json_data TEXT NOT NULL);",
  "CREATE TABLE IF NOT EXISTS todos (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, modified_date REAL NOT NULL, completed INTEGER NOT NULL DEFAULT 0, due_date REAL, json_data TEXT NOT NULL);",
];

export function buildImportSql(rowsByTable) {
  const statements = ["PRAGMA busy_timeout = 5000;", "BEGIN IMMEDIATE;", ...schemaSql];
  for (const table of ["meetings", "notes", "tasks", "todos", "t5t_reports"]) {
    statements.push(`DELETE FROM ${table};`);
  }

  for (const row of rowsByTable.meetings || []) {
    const meeting = macMeeting(row);
    statements.push(insertStatement("meetings", {
      id: meeting.id,
      title: meeting.title,
      date: unixSeconds(row.date, "meeting.date"),
      duration: meeting.duration,
      json_data: JSON.stringify(meeting),
    }));
  }

  for (const row of rowsByTable.notes || []) {
    const note = macNote(row);
    statements.push(insertStatement("notes", {
      id: note.id,
      title: note.title,
      created_date: unixSeconds(row.createdDate, "note.createdDate"),
      modified_date: unixSeconds(row.modifiedDate, "note.modifiedDate"),
      json_data: JSON.stringify(note),
    }));
  }

  for (const row of rowsByTable.tasks || []) {
    const task = macTask(row);
    statements.push(insertStatement("tasks", {
      id: task.id,
      title: task.title,
      created_date: unixSeconds(row.createdDate, "task.createdDate"),
      modified_date: unixSeconds(row.modifiedDate, "task.modifiedDate"),
      status: task.status,
      json_data: JSON.stringify(task),
    }));
  }

  for (const row of rowsByTable.todos || []) {
    const todo = macTodo(row);
    statements.push(insertStatement("todos", {
      id: todo.id,
      title: todo.title,
      created_date: unixSeconds(row.createdDate, "todo.createdDate"),
      modified_date: unixSeconds(row.modifiedDate, "todo.modifiedDate"),
      completed: todo.completed ? 1 : 0,
      due_date: row.dueDate ? unixSeconds(row.dueDate, "todo.dueDate") : null,
      json_data: JSON.stringify(todo),
    }));
  }

  for (const row of rowsByTable.t5tReports || []) {
    const report = macT5TReport(row);
    statements.push(insertStatement("t5t_reports", {
      id: report.id,
      created_date: unixSeconds(row.createdDate, "t5t.createdDate"),
      period_start: unixSeconds(row.periodStart, "t5t.periodStart"),
      period_end: unixSeconds(row.periodEnd, "t5t.periodEnd"),
      status: report.status,
      json_data: JSON.stringify(report),
    }));
  }

  statements.push("COMMIT;");
  return `${statements.join("\n")}\n`;
}

function deserializeRow(table, columns, values) {
  const jsonCols = JSON_COLS[table] || [];
  const row = {};
  for (let index = 0; index < columns.length; index += 1) {
    const name = columns[index];
    let value = values[index];
    if (jsonCols.includes(name) && typeof value === "string") {
      try {
        value = JSON.parse(value);
      } catch {
        value = name === "summary" ? {} : [];
      }
    }
    row[name] = value;
  }
  return row;
}

async function tursoQuery(baseUrl, token, sql) {
  const response = await fetch(`${baseUrl}/v2/pipeline`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      requests: [{ type: "execute", stmt: { sql, args: [] } }, { type: "close" }],
    }),
  });

  if (!response.ok) {
    throw new Error(`Turso query failed with HTTP ${response.status}`);
  }

  const data = await response.json();
  const result = data.results?.[0]?.response?.result;
  if (!result) return { columns: [], rows: [] };
  const columns = (result.cols || []).map((column) => column.name);
  const rows = (result.rows || []).map((row) => row.map((cell) => {
    if (cell.value === null) return null;
    if (cell.type === "integer") return Number.parseInt(cell.value, 10);
    if (cell.type === "float") return Number.parseFloat(cell.value);
    return cell.value;
  }));
  return { columns, rows };
}

async function fetchTursoRows(envPath) {
  const env = parseDotEnv(readFileSync(envPath, "utf8"));
  const rawUrl = env.TURSO_DATABASE_URL || "";
  const token = env.TURSO_AUTH_TOKEN || "";
  if (!rawUrl || !token) {
    throw new Error(`Missing TURSO_DATABASE_URL or TURSO_AUTH_TOKEN in ${envPath}`);
  }
  const baseUrl = new URL(rawUrl.replace(/^libsql:\/\//, "https://")).origin;
  const rowsByTable = {};
  for (const table of DEFAULT_TABLES) {
    const { columns, rows } = await tursoQuery(baseUrl, token, `SELECT * FROM ${table}`);
    rowsByTable[table] = rows.map((row) => deserializeRow(table, columns, row));
  }
  return rowsByTable;
}

function defaultMacDbPath() {
  if (!process.env.HOME) throw new Error("HOME is not set");
  return resolve(process.env.HOME, "Library/Application Support/NoteAI/meetings.sqlite");
}

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "").replace("T", "-");
}

function backupDatabase(dbPath) {
  if (!existsSync(dbPath)) return null;
  const backupPath = `${dbPath}.backup-${timestamp()}`;
  const backup = spawnSync("sqlite3", [dbPath, `.backup '${backupPath.replaceAll("'", "''")}'`], {
    encoding: "utf8",
  });
  if (backup.status === 0) return backupPath;
  copyFileSync(dbPath, backupPath);
  return backupPath;
}

function applyImportSql(dbPath, sql) {
  mkdirSync(dirname(dbPath), { recursive: true });
  const result = spawnSync("sqlite3", [dbPath], {
    input: sql,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`sqlite3 import failed: ${result.stderr || result.stdout}`);
  }
}

function counts(rowsByTable) {
  return Object.fromEntries(DEFAULT_TABLES.map((table) => [table, rowsByTable[table]?.length || 0]));
}

function parseArgs(argv) {
  const args = {
    envPath: "web/.env.prod",
    dbPath: defaultMacDbPath(),
    dryRun: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--env") {
      args.envPath = argv[++index];
    } else if (arg === "--db") {
      args.dbPath = argv[++index];
    } else if (arg === "--dry-run") {
      args.dryRun = true;
    } else if (arg === "--help" || arg === "-h") {
      args.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function printHelp() {
  console.log(`Usage: node scripts/turso-to-macos-sync.mjs [--env web/.env.prod] [--db path] [--dry-run]

Mirrors Turso-backed NoteAI web data into the macOS local GRDB SQLite store.
The script backs up the local database before replacing meetings, notes, tasks,
todos, and T5T reports.`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  const envPath = resolve(args.envPath);
  const dbPath = resolve(args.dbPath);
  const rowsByTable = await fetchTursoRows(envPath);
  const importSql = buildImportSql(rowsByTable);
  const rowCounts = counts(rowsByTable);

  if (args.dryRun) {
    console.log(`Dry run complete: ${JSON.stringify(rowCounts)}`);
    return;
  }

  const backupPath = backupDatabase(dbPath);
  applyImportSql(dbPath, importSql);
  console.log(`Synced Turso data into ${dbPath}`);
  if (backupPath) console.log(`Backup created at ${backupPath}`);
  console.log(`Rows synced: ${JSON.stringify(rowCounts)}`);
}

const isCli = process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isCli) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
