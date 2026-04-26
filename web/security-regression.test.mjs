import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("web auth fails closed unless an explicit non-production bypass is enabled", () => {
  const middleware = read("./src/middleware.ts");
  const authRoute = read("./src/app/api/auth/route.ts");
  const security = read("./src/lib/security.ts");

  assert.match(security, /NOTEAI_DISABLE_AUTH/);
  assert.doesNotMatch(middleware, /if \(!secret \|\| !clientId\) return NextResponse\.next\(\)/);
  assert.doesNotMatch(authRoute, /authenticated:\s*true,\s*required:\s*false/);
});

test("programmatic API auth is not derived from NOTEAI_AUTH_SECRET", () => {
  const middleware = read("./src/middleware.ts");
  const apiKeyRoute = read("./src/app/api/auth/apikey/route.ts");
  const security = read("./src/lib/security.ts");

  assert.match(security, /NOTEAI_API_KEY_HASHES/);
  assert.doesNotMatch(middleware, /hmacSign\("noteai-api-key",\s*secret\)/);
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
  const chatRoute = read("./src/app/api/chat/route.ts");
  const transcribeRoute = read("./src/app/api/transcribe/route.ts");
  const ttsRoute = read("./src/app/api/tts/route.ts");

  assert.match(chatRoute, /MAX_CHAT_MESSAGES/);
  assert.match(chatRoute, /MAX_CHAT_TOKENS/);
  assert.match(transcribeRoute, /MAX_AUDIO_BYTES/);
  assert.match(ttsRoute, /MAX_TTS_CHARS/);
});

test("web app uses crypto.randomUUID instead of the uuid dependency", () => {
  const paths = [
    "./src/lib/recording-workflow.ts",
    "./src/lib/assistant-actions.ts",
    "./src/app/page.tsx",
    "./src/components/ChatPanel.tsx",
    "./src/components/T5TComposer.tsx",
  ];

  for (const path of paths) {
    const source = read(path);
    assert.doesNotMatch(source, /from ["']uuid["']/);
  }
});
