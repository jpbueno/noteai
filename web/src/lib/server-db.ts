// Turso HTTP API client using plain fetch — works on any serverless platform

function getConfig() {
  const rawUrl = process.env.TURSO_DATABASE_URL || "";
  const authToken = process.env.TURSO_AUTH_TOKEN || "";
  const url = rawUrl.replace(/^libsql:\/\//, "https://");
  return { url, authToken };
}

interface TursoResult {
  columns: string[];
  rows: (string | number | null)[][];
}

async function query(sql: string, args: (string | number | null)[] = []): Promise<TursoResult> {
  const { url, authToken } = getConfig();

  const response = await fetch(`${url}/v2/pipeline`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${authToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      requests: [
        {
          type: "execute",
          stmt: {
            sql,
            args: args.map((a) => {
              if (a === null || a === undefined) return { type: "null", value: null };
              if (typeof a === "number") return { type: "float", value: a };
              return { type: "text", value: String(a) };
            }),
          },
        },
        { type: "close" },
      ],
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Turso error (${response.status}): ${text}`);
  }

  const data = await response.json();
  const result = data.results?.[0]?.response?.result;

  if (!result) {
    const errMsg = data.results?.[0]?.response?.error?.message;
    if (errMsg) throw new Error(`SQL error: ${errMsg}`);
    return { columns: [], rows: [] };
  }

  const columns = (result.cols || []).map((c: { name: string }) => c.name);
  const rows = (result.rows || []).map((r: { type: string; value: string | null }[]) =>
    r.map((cell) => {
      if (cell.value === null) return null;
      if (cell.type === "integer") return parseInt(cell.value, 10);
      if (cell.type === "float") return parseFloat(cell.value);
      return cell.value;
    })
  );

  return { columns, rows };
}

// Schema

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', date TEXT NOT NULL, duration REAL NOT NULL DEFAULT 0, transcript TEXT NOT NULL DEFAULT '[]', summary TEXT NOT NULL DEFAULT '{}')`,
  `CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT 'Untitled', content TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]', createdDate TEXT NOT NULL, modifiedDate TEXT NOT NULL, sourceMeetingID TEXT)`,
  `CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', rawInput TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'pending', createdDate TEXT NOT NULL, modifiedDate TEXT NOT NULL, sourceMeetingID TEXT, sourceNoteID TEXT)`,
  `CREATE TABLE IF NOT EXISTS t5tReports (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', createdDate TEXT NOT NULL, periodStart TEXT NOT NULL, periodEnd TEXT NOT NULL, meetingIDs TEXT NOT NULL DEFAULT '[]', noteIDs TEXT NOT NULL DEFAULT '[]', taskIDs TEXT NOT NULL DEFAULT '[]', dailyLogIDs TEXT NOT NULL DEFAULT '[]', sections TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'draft')`,
  `CREATE TABLE IF NOT EXISTS dailyLogs (id TEXT PRIMARY KEY, date TEXT NOT NULL, sections TEXT NOT NULL DEFAULT '[]', linkedMeetingIDs TEXT NOT NULL DEFAULT '[]', createdDate TEXT NOT NULL, modifiedDate TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS chatMessages (id TEXT PRIMARY KEY, role TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', timestamp TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS todos (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', completed INTEGER NOT NULL DEFAULT 0, createdDate TEXT NOT NULL, modifiedDate TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')`,
];

const MIGRATIONS = [
  "ALTER TABLE meetings ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE tasks ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE t5tReports ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE todos ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE todos ADD COLUMN dueDate TEXT",
  "ALTER TABLE dailyLogs ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE t5tReports ADD COLUMN dailyLogIDs TEXT NOT NULL DEFAULT '[]'",
];

let _initialized = false;

async function ensureSchema(): Promise<void> {
  if (_initialized) return;
  for (const sql of SCHEMA) {
    await query(sql);
  }
  for (const sql of MIGRATIONS) {
    try { await query(sql); } catch { /* column already exists */ }
  }
  _initialized = true;
}

// JSON serialization

const JSON_COLS: Record<string, string[]> = {
  meetings: ["transcript", "summary"],
  notes: ["tags"],
  tasks: ["tags"],
  t5tReports: ["meetingIDs", "noteIDs", "taskIDs", "dailyLogIDs", "sections"],
  dailyLogs: ["sections", "linkedMeetingIDs"],
};

function serializeRow(table: string, row: Record<string, unknown>): Record<string, unknown> {
  const cols = JSON_COLS[table] || [];
  const out = { ...row };
  for (const col of cols) {
    if (out[col] !== undefined && typeof out[col] !== "string") {
      out[col] = JSON.stringify(out[col]);
    }
  }
  return out;
}

function deserializeRow(table: string, colNames: string[], values: (string | number | null)[]): Record<string, unknown> {
  const obj: Record<string, unknown> = {};
  const jsonCols = JSON_COLS[table] || [];
  for (let i = 0; i < colNames.length; i++) {
    const val = values[i];
    if (jsonCols.includes(colNames[i]) && typeof val === "string") {
      try { obj[colNames[i]] = JSON.parse(val); } catch { obj[colNames[i]] = val; }
    } else {
      obj[colNames[i]] = val;
    }
  }
  return obj;
}

// Column whitelist — prevents SQL injection via crafted JSON keys

const TABLE_COLUMNS: Record<string, string[]> = {
  meetings: ["id", "title", "date", "duration", "transcript", "summary", "pinned"],
  notes: ["id", "title", "content", "tags", "createdDate", "modifiedDate", "sourceMeetingID", "pinned"],
  tasks: ["id", "title", "description", "rawInput", "tags", "status", "createdDate", "modifiedDate", "sourceMeetingID", "sourceNoteID", "pinned"],
  t5tReports: ["id", "title", "createdDate", "periodStart", "periodEnd", "meetingIDs", "noteIDs", "taskIDs", "dailyLogIDs", "sections", "status", "pinned"],
  dailyLogs: ["id", "date", "sections", "linkedMeetingIDs", "createdDate", "modifiedDate", "pinned"],
  chatMessages: ["id", "role", "content", "timestamp"],
  todos: ["id", "title", "description", "completed", "dueDate", "createdDate", "modifiedDate", "pinned"],
  settings: ["key", "value"],
};

function stripInvalidColumns(table: string, data: Record<string, unknown>): Record<string, unknown> {
  const validCols = TABLE_COLUMNS[table];
  if (!validCols) throw new Error(`Unknown table: ${table}`);
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(data)) {
    if (validCols.includes(key)) {
      out[key] = data[key];
    }
  }
  return out;
}

// CRUD

const VALID_TABLES = ["meetings", "notes", "tasks", "t5tReports", "dailyLogs", "chatMessages", "todos", "settings"];

export async function getAll(table: string): Promise<Record<string, unknown>[]> {
  if (!VALID_TABLES.includes(table)) throw new Error(`Invalid table: ${table}`);
  await ensureSchema();
  let orderCol = "id";
  let pinPrefix = "";
  if (table === "meetings") { orderCol = "date"; pinPrefix = "pinned DESC, "; }
  else if (table === "dailyLogs") { orderCol = "date"; pinPrefix = "pinned DESC, "; }
  else if (["notes", "tasks", "t5tReports", "todos"].includes(table)) { orderCol = "createdDate"; pinPrefix = "pinned DESC, "; }
  else if (table === "chatMessages") orderCol = "timestamp";
  const result = await query(`SELECT * FROM ${table} ORDER BY ${pinPrefix}${orderCol} DESC`);
  return result.rows.map((r) => deserializeRow(table, result.columns, r));
}

export async function getById(table: string, id: string): Promise<Record<string, unknown> | undefined> {
  if (!VALID_TABLES.includes(table)) throw new Error(`Invalid table: ${table}`);
  await ensureSchema();
  const result = await query(`SELECT * FROM ${table} WHERE id = ?`, [id]);
  if (result.rows.length === 0) return undefined;
  return deserializeRow(table, result.columns, result.rows[0]);
}

export async function upsert(table: string, data: Record<string, unknown>): Promise<void> {
  if (!VALID_TABLES.includes(table)) throw new Error(`Invalid table: ${table}`);
  await ensureSchema();

  // Strip any keys not in the column whitelist (prevents SQL injection via column names)
  const safeData = stripInvalidColumns(table, data);

  const pkCol = table === "settings" ? "key" : "id";
  const pkVal = safeData[pkCol] as string | undefined;

  if (pkVal) {
    const existing = await query(`SELECT * FROM ${table} WHERE ${pkCol} = ?`, [pkVal]);
    if (existing.rows.length > 0) {
      const existingObj = deserializeRow(table, existing.columns, existing.rows[0]);
      const merged = serializeRow(table, { ...existingObj, ...safeData });
      const cols = Object.keys(merged);
      const sets = cols.map((c) => `${c} = ?`).join(", ");
      const values = cols.map((c) => merged[c] as string | number | null);
      await query(`UPDATE ${table} SET ${sets} WHERE ${pkCol} = ?`, [...values, pkVal]);
      return;
    }
  }

  const serialized = serializeRow(table, safeData);
  const cols = Object.keys(serialized);
  const placeholders = cols.map(() => "?").join(", ");
  const values = cols.map((c) => serialized[c] as string | number | null);
  await query(`INSERT INTO ${table} (${cols.join(", ")}) VALUES (${placeholders})`, values);
}

export async function remove(table: string, id: string): Promise<void> {
  if (!VALID_TABLES.includes(table)) throw new Error(`Invalid table: ${table}`);
  await ensureSchema();
  await query(`DELETE FROM ${table} WHERE id = ?`, [id]);
}

export async function clearTable(table: string): Promise<void> {
  if (!VALID_TABLES.includes(table)) throw new Error(`Invalid table: ${table}`);
  await ensureSchema();
  await query(`DELETE FROM ${table}`);
}

// Settings key whitelist

const VALID_SETTING_KEYS = [
  "llm_provider",
  "llm_model",
  "meeting_template",
  "api_key_openrouter",
  "api_key_anthropic",
  "api_key_openai",
  "api_key_nvidia",
  "api_key_groq",
  "t5t_config",
  "tts_voice",
];

const ENCRYPTED_KEYS = ["api_key_openrouter", "api_key_anthropic", "api_key_openai", "api_key_nvidia", "api_key_groq"];
const ENC_PREFIX = "enc:";

export function isValidSettingKey(key: string): boolean {
  return VALID_SETTING_KEYS.includes(key);
}

// --- AES-256-GCM encryption for sensitive settings ---

function getEncryptionKey(): string {
  return process.env.NOTEAI_AUTH_SECRET || "";
}

async function deriveKey(secret: string): Promise<CryptoKey> {
  const raw = new TextEncoder().encode(secret);
  const hash = await crypto.subtle.digest("SHA-256", raw);
  return crypto.subtle.importKey("raw", hash, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function encrypt(plaintext: string): Promise<string> {
  const secret = getEncryptionKey();
  if (!secret) return plaintext; // no secret = no encryption (local dev)
  const key = await deriveKey(secret);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = new TextEncoder().encode(plaintext);
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, data);
  const combined = new Uint8Array(iv.length + new Uint8Array(ciphertext).length);
  combined.set(iv);
  combined.set(new Uint8Array(ciphertext), iv.length);
  return ENC_PREFIX + btoa(String.fromCharCode(...combined));
}

async function decrypt(stored: string): Promise<string> {
  if (!stored.startsWith(ENC_PREFIX)) return stored; // plaintext (legacy or unencrypted)
  const secret = getEncryptionKey();
  if (!secret) return stored;
  const key = await deriveKey(secret);
  const combined = Uint8Array.from(atob(stored.slice(ENC_PREFIX.length)), (c) => c.charCodeAt(0));
  const iv = combined.slice(0, 12);
  const ciphertext = combined.slice(12);
  const plainBuffer = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ciphertext);
  return new TextDecoder().decode(plainBuffer);
}

// --- Settings CRUD ---

let _keysMigrated = false;

async function ensureMigration(): Promise<void> {
  if (_keysMigrated) return;
  _keysMigrated = true;
  await migrateEncryptSettings();
}

export async function getSettingValue(key: string): Promise<string | undefined> {
  await ensureSchema();
  if (ENCRYPTED_KEYS.includes(key) && !_keysMigrated) {
    await ensureMigration();
  }
  const result = await query("SELECT value FROM settings WHERE key = ?", [key]);
  if (result.rows.length === 0) return undefined;
  const raw = result.rows[0][0] as string;
  if (ENCRYPTED_KEYS.includes(key)) {
    return decrypt(raw);
  }
  return raw;
}

export async function setSettingValue(key: string, value: string): Promise<void> {
  if (!isValidSettingKey(key)) throw new Error(`Invalid setting key: ${key}`);
  await ensureSchema();
  let stored = value;
  if (ENCRYPTED_KEYS.includes(key) && value) {
    stored = await encrypt(value);
  }
  await query(
    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    [key, stored]
  );
}

// One-time migration: encrypt any plaintext API keys already in the DB
export async function migrateEncryptSettings(): Promise<void> {
  await ensureSchema();
  for (const key of ENCRYPTED_KEYS) {
    const result = await query("SELECT value FROM settings WHERE key = ?", [key]);
    if (result.rows.length === 0) continue;
    const raw = result.rows[0][0] as string;
    if (raw && !raw.startsWith(ENC_PREFIX)) {
      const encrypted = await encrypt(raw);
      await query(
        "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [key, encrypted]
      );
    }
  }
}

export async function bulkUpsert(table: string, rows: Record<string, unknown>[]): Promise<void> {
  if (!VALID_TABLES.includes(table)) throw new Error(`Invalid table: ${table}`);
  for (const item of rows) {
    await upsert(table, item);
  }
}
