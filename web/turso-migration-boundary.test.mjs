import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("Turso schema migrations are explicit and not hidden behind request-time reads", () => {
  const serverDb = read("./src/lib/server-db.ts");
  const schemaPath = new URL("./src/lib/turso-schema.json", import.meta.url);
  const migrationScriptPath = new URL("./scripts/migrate-turso.mjs", import.meta.url);
  const packageJson = JSON.parse(read("./package.json"));

  assert.equal(existsSync(schemaPath), true, "shared Turso schema definition should exist");
  assert.equal(existsSync(migrationScriptPath), true, "explicit Turso migration script should exist");
  assert.equal(packageJson.scripts["migrate:turso"], "node scripts/migrate-turso.mjs");
  assert.match(serverDb, /export async function migrateTursoSchema/);
  assert.doesNotMatch(serverDb, /await ensureSchema\(\)/);
  assert.doesNotMatch(serverDb, /function ensureSchema/);
  assert.doesNotMatch(serverDb, /ensureMigration/);
});

test("Turso migration script can use a migration token separate from the runtime app token", () => {
  const migrationScript = read("./scripts/migrate-turso.mjs");

  assert.match(migrationScript, /TURSO_MIGRATION_AUTH_TOKEN/);
  assert.match(migrationScript, /TURSO_AUTH_TOKEN/);
  assert.match(migrationScript, /turso-schema\.json/);
  assert.match(migrationScript, /NOTEAI_AUTH_SECRET/);
});

test("production Turso migrations have a manual environment-gated workflow", () => {
  const workflowUrl = new URL("../.github/workflows/web-migrate-turso.yml", import.meta.url);
  assert.equal(existsSync(workflowUrl), true, "manual Turso migration workflow should exist");

  const workflow = read("../.github/workflows/web-migrate-turso.yml");
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /github\.ref == 'refs\/heads\/main'/);
  assert.match(workflow, /environment:\s*\n\s*name:\s*production/);
  assert.match(workflow, /TURSO_MIGRATION_AUTH_TOKEN/);
  assert.match(workflow, /npm run migrate:turso/);
});
