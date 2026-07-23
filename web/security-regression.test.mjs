import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("web auth fails closed unless an explicit non-production bypass is enabled", () => {
  const apiAuth = read("./src/lib/api-auth.ts");
  const authRoute = read("./src/app/api/auth/route.ts");
  const security = read("./src/lib/security.ts");

  assert.match(security, /NOTEAI_DISABLE_AUTH/);
  assert.doesNotMatch(apiAuth, /if \(!secret \|\| !clientId\) return null/);
  assert.match(apiAuth, /Authentication is not configured/);
  assert.match(authRoute, /isExplicitAuthBypassEnabled/);
});

test("local browser auth bypass is reflected in the auth status endpoint", () => {
  const authRoute = read("./src/app/api/auth/route.ts");

  assert.match(authRoute, /isExplicitAuthBypassEnabled/);
  assert.match(authRoute, /authenticated:\s*true,\s*required:\s*false/);
});

test("release health endpoint is public and non-sensitive", () => {
  const healthRoute = read("./src/app/api/health/route.ts");

  assert.equal(existsSync(new URL("./src/middleware.ts", import.meta.url)), false);
  assert.equal(existsSync(new URL("./src/proxy.ts", import.meta.url)), false);
  assert.match(healthRoute, /ok:\s*true/);
  assert.match(healthRoute, /service:\s*"noteai-web"/);
  assert.doesNotMatch(healthRoute, /requireApiAuth/);
  assert.doesNotMatch(healthRoute, /process\.env/);
});

test("browser API client rejects failed HTTP responses before data reaches list hooks", () => {
  const db = read("./src/lib/db.ts");
  const hooks = read("./src/lib/hooks.ts");

  assert.match(db, /if \(!res\.ok\)/);
  assert.match(db, /throw new Error/);
  assert.match(hooks, /Array\.isArray\(result\)/);
});

test("local dev origins include loopback hosts used by browser testing", () => {
  const nextConfig = read("./next.config.ts");

  assert.match(nextConfig, /allowedDevOrigins/);
  assert.match(nextConfig, /127\.0\.0\.1/);
});

test("missing Turso config uses a non-production local persistence fallback only", () => {
  const serverDb = read("./src/lib/server-db.ts");

  assert.match(serverDb, /isLocalPersistenceEnabled/);
  assert.match(serverDb, /process\.env\.NODE_ENV !== "production"/);
  assert.match(serverDb, /localTables/);
});

test("chat messages are served oldest-first for conversation rendering", () => {
  const serverDb = read("./src/lib/server-db.ts");

  assert.match(serverDb, /function orderDirection/);
  assert.match(serverDb, /table === "chatMessages" \? "ASC" : "DESC"/);
});

test("programmatic API auth is not derived from NOTEAI_AUTH_SECRET", () => {
  const apiAuth = read("./src/lib/api-auth.ts");
  const apiKeyRoute = read("./src/app/api/auth/apikey/route.ts");
  const security = read("./src/lib/security.ts");

  assert.match(security, /NOTEAI_API_KEY_HASHES/);
  assert.doesNotMatch(apiAuth, /hmacSign\("noteai-api-key",\s*secret\)/);
  assert.doesNotMatch(apiKeyRoute, /return NextResponse\.json\(\{\s*apiKey/);
});

test("provider API keys are write-only from browser settings APIs", () => {
  const settingsRoute = read("./src/app/api/settings/route.ts");
  const settingsComponent = read("./src/components/Settings.tsx");

  assert.match(settingsRoute, /isEncryptedSettingKey/);
  assert.match(settingsRoute, /configured:\s*Boolean/);
  assert.doesNotMatch(settingsComponent, /getSetting\(`api_key_\$\{k\}`\)/);
});

test("cost-bearing AI endpoints enforce local request bounds", () => {
  const aiClient = read("./src/lib/ai.ts");
  const chatRoute = read("./src/app/api/chat/route.ts");
  const upstreamAbort = read("./src/lib/upstream-abort.ts");
  const transcribeRoute = read("./src/app/api/transcribe/route.ts");
  const ttsRoute = read("./src/app/api/tts/route.ts");

  assert.match(aiClient, /CLIENT_CHAT_TIMEOUT_MS\s*=\s*75_000/);
  assert.match(aiClient, /AI copilot request timed out/);
  assert.match(chatRoute, /MAX_CHAT_MESSAGES/);
  assert.match(chatRoute, /MAX_CHAT_TOKENS/);
  assert.match(chatRoute, /CHAT_UPSTREAM_TIMEOUT_MS\s*=\s*60_000/);
  assert.match(chatRoute, /consumeUpstreamResponse\(/);
  assert.match(chatRoute, /request\.signal/);
  assert.match(upstreamAbort, /await operation\(scope\.signal\)/);
  assert.match(upstreamAbort, /requestSignal\.addEventListener\("abort"/);
  assert.match(upstreamAbort, /controller\.abort\(\)/);
  assert.match(chatRoute, /returned an empty response/);
  assert.match(chatRoute, /supportsTemperature/);
  assert.match(chatRoute, /model\.startsWith\("aws\/anthropic\/"\)/);
  assert.match(transcribeRoute, /MAX_AUDIO_BYTES/);
  assert.match(ttsRoute, /MAX_TTS_CHARS/);
});

test("web app uses crypto.randomUUID instead of the uuid dependency", () => {
  const paths = [
    "./src/app/page.tsx",
    "./src/components/ChatPanel.tsx",
    "./src/components/T5TComposer.tsx",
    "./src/lib/hooks.ts",
  ];

  for (const path of paths) {
    const source = read(path);
    assert.doesNotMatch(source, /from ["']uuid["']/);
  }
});

test("development CSP permits React dev tooling eval without weakening production", () => {
  const nextConfig = read("./next.config.ts");

  assert.match(nextConfig, /process\.env\.NODE_ENV\s*!==\s*"production"/);
  assert.match(nextConfig, /'unsafe-eval'/);
  assert.match(nextConfig, /scriptSrc/);
});

test("Google Docs sync feature is removed from the web app", () => {
  const packageJson = read("./package.json");
  const todoDetail = read("./src/components/TodoDetail.tsx");
  const types = read("./src/lib/types.ts");
  const apiDir = new URL("./src/app/api/integrations/", import.meta.url);

  assert.equal(existsSync(new URL("./GOOGLE_DOCS_SETUP.md", import.meta.url)), false);
  assert.equal(existsSync(new URL("./src/lib/google-docs.ts", import.meta.url)), false);
  assert.doesNotMatch(todoDetail, /google-docs|sync-todo|syncedToGoogleDocs/i);
  assert.doesNotMatch(types, /syncedToGoogleDocs|googleDocsSyncedAt|Google Docs sync/i);
  assert.doesNotMatch(packageJson, /googleapis/);
  if (existsSync(apiDir)) {
    assert.equal(readdirSync(apiDir).includes("google-docs"), false);
  }
});

test("NVIDIA provider uses current API catalog endpoint and model IDs", () => {
  const chatRoute = read("./src/app/api/chat/route.ts");
  const nextConfig = read("./next.config.ts");
  const settings = read("./src/components/Settings.tsx");

  assert.match(chatRoute, /https:\/\/inference-api\.nvidia\.com\/v1\/chat\/completions/);
  assert.match(nextConfig, /https:\/\/inference-api\.nvidia\.com/);
  assert.doesNotMatch(nextConfig, /integrate\.api\.nvidia\.com/);
  assert.doesNotMatch(chatRoute, /integrate\.api\.nvidia\.com/);
  assert.match(settings, /aws\/anthropic\/bedrock-claude-opus-4-7/);
  assert.match(settings, /nvidia\/llama-3\.3-nemotron-super-49b-v1\.5/);
  assert.doesNotMatch(settings, /nvcf\/nvidia/);
  assert.doesNotMatch(settings, /azure\/anthropic/);
});

test("web app exposes a lightweight release health endpoint", () => {
  const healthRoute = read("./src/app/api/health/route.ts");

  assert.match(healthRoute, /ok:\s*true/);
  assert.match(healthRoute, /service:\s*"noteai-web"/);
  assert.doesNotMatch(healthRoute, /requireApiAuth/);
});

test("public Cloudflare Worker deployment path is removed", () => {
  const packageJson = read("./package.json");

  assert.equal(existsSync(new URL("./wrangler.jsonc", import.meta.url)), false);
  assert.equal(existsSync(new URL("./open-next.config.ts", import.meta.url)), false);
  assert.equal(existsSync(new URL("../.github/workflows/web-deploy-cloudflare.yml", import.meta.url)), false);
  assert.doesNotMatch(packageJson, /build:cf|preview:cf|deploy:cf|@opennextjs\/cloudflare/);
});

test("Turso PITR runbook includes an authenticated non-production drill", () => {
  const runbook = read("../docs/security/turso-restore-runbook.md");

  assert.match(runbook, /Authenticated Non-Production PITR Drill/);
  assert.match(runbook, /noteai-pitr-drill-source-YYYYMMDD/);
  assert.match(runbook, /--from-db noteai-pitr-drill-source-YYYYMMDD --timestamp "\$RESTORE_TS"/);
  assert.match(runbook, /pitr-before` count is `1`/);
  assert.match(runbook, /pitr-after` count is `0`/);
});

test("web API auth avoids unsupported Next request interception", () => {
  const apiAuth = read("./src/lib/api-auth.ts");
  const dataRoute = read("./src/app/api/data/[table]/route.ts");
  const chatRoute = read("./src/app/api/chat/route.ts");

  assert.equal(existsSync(new URL("./src/middleware.ts", import.meta.url)), false);
  assert.equal(existsSync(new URL("./src/proxy.ts", import.meta.url)), false);
  assert.match(apiAuth, /export async function requireApiAuth/);
  assert.match(dataRoute, /requireApiAuth/);
  assert.match(chatRoute, /requireApiAuth/);
});
