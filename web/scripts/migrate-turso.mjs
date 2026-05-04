import { readFileSync } from "node:fs";
import { webcrypto } from "node:crypto";

const schemaDefinition = JSON.parse(
  readFileSync(new URL("../src/lib/turso-schema.json", import.meta.url), "utf8"),
);

function parseArgs(argv) {
  const args = { envFile: "" };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--env-file") {
      args.envFile = argv[++i] || "";
    }
  }
  return args;
}

function parseDotEnv(content) {
  const env = {};
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const index = trimmed.indexOf("=");
    if (index === -1) continue;
    const key = trimmed.slice(0, index).trim();
    let value = trimmed.slice(index + 1).trim();
    if (
      (value.startsWith("\"") && value.endsWith("\"")) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    env[key] = value;
  }
  return env;
}

function loadEnvFile(path) {
  if (!path) return;
  const parsed = parseDotEnv(readFileSync(path, "utf8"));
  for (const [key, value] of Object.entries(parsed)) {
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

function tursoUrl() {
  return (process.env.TURSO_DATABASE_URL || "").replace(/^libsql:\/\//, "https://");
}

function tursoAuthToken() {
  return process.env.TURSO_MIGRATION_AUTH_TOKEN || process.env.TURSO_AUTH_TOKEN || "";
}

function toTursoArgs(args) {
  return args.map((value) => {
    if (value === null || value === undefined) return { type: "null", value: null };
    if (typeof value === "number") return { type: "float", value };
    return { type: "text", value: String(value) };
  });
}

async function execute(sql, args = []) {
  const url = tursoUrl();
  const authToken = tursoAuthToken();
  if (!url || !authToken) {
    throw new Error("Missing TURSO_DATABASE_URL and migration token");
  }

  const response = await fetch(`${url}/v2/pipeline`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${authToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      requests: [
        { type: "execute", stmt: { sql, args: toTursoArgs(args) } },
        { type: "close" },
      ],
    }),
  });

  if (!response.ok) {
    throw new Error(`Turso error (${response.status})`);
  }

  const data = await response.json();
  const first = data.results?.[0]?.response;
  if (first?.error?.message) {
    throw new Error(`SQL error: ${first.error.message}`);
  }

  const result = first?.result;
  return {
    columns: (result?.cols || []).map((column) => column.name),
    rows: (result?.rows || []).map((row) => row.map((cell) => cell.value)),
  };
}

function isBenignMigrationError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return /duplicate column name|already exists/i.test(message);
}

async function runSchemaMigrations() {
  for (const sql of schemaDefinition.schema) {
    await execute(sql);
  }

  let applied = 0;
  let skipped = 0;
  for (const migration of schemaDefinition.migrations) {
    try {
      await execute(migration.sql);
      applied += 1;
    } catch (error) {
      if (!isBenignMigrationError(error)) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(`Migration ${migration.id} failed: ${message}`);
      }
      skipped += 1;
    }
  }

  console.log(`Turso schema migration complete: ${applied} applied, ${skipped} already present.`);
}

async function deriveKey(secret) {
  const raw = new TextEncoder().encode(secret);
  const hash = await webcrypto.subtle.digest("SHA-256", raw);
  return webcrypto.subtle.importKey("raw", hash, "AES-GCM", false, ["encrypt"]);
}

async function encryptSetting(secret, plaintext) {
  const key = await deriveKey(secret);
  const iv = webcrypto.getRandomValues(new Uint8Array(12));
  const data = new TextEncoder().encode(plaintext);
  const ciphertext = await webcrypto.subtle.encrypt({ name: "AES-GCM", iv }, key, data);
  const combined = new Uint8Array(iv.length + new Uint8Array(ciphertext).length);
  combined.set(iv);
  combined.set(new Uint8Array(ciphertext), iv.length);
  return `enc:${Buffer.from(combined).toString("base64")}`;
}

async function migrateEncryptedSettings() {
  const secret = process.env.NOTEAI_AUTH_SECRET || "";
  if (!secret) {
    console.log("Encrypted settings migration skipped: NOTEAI_AUTH_SECRET is not set.");
    return;
  }

  let encrypted = 0;
  for (const key of schemaDefinition.encryptedSettingKeys) {
    const result = await execute("SELECT value FROM settings WHERE key = ?", [key]);
    const raw = result.rows[0]?.[0];
    if (typeof raw === "string" && raw && !raw.startsWith("enc:")) {
      await execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [key, await encryptSetting(secret, raw)],
      );
      encrypted += 1;
    }
  }

  console.log(`Encrypted settings migration complete: ${encrypted} plaintext setting(s) encrypted.`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  loadEnvFile(args.envFile);
  await runSchemaMigrations();
  await migrateEncryptedSettings();
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
