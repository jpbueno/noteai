import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sidebar = readFileSync(new URL("./src/components/Sidebar.tsx", import.meta.url), "utf8");
const settings = readFileSync(new URL("./src/components/Settings.tsx", import.meta.url), "utf8");
const page = readFileSync(new URL("./src/app/page.tsx", import.meta.url), "utf8");
const sources = readFileSync(new URL("./src/lib/recording-sources.ts", import.meta.url), "utf8");

test("Sidebar exposes Teams Desktop as a visible local-helper recording source", () => {
  assert.match(sidebar, /recordingSources/);
  assert.match(sources, /Teams Desktop/);
  assert.match(sidebar, /disabledReason/);
  assert.match(sidebar, /onOpenLocalHelper/);
  assert.match(sidebar, /activeRecordingSource\.id/);
  assert.match(sidebar, /onStartRecording\(undefined, activeRecordingSource\.id === "browser-tab", activeRecordingSource\.id\)/);
});

test("Settings includes local helper diagnostics and capture-control status", () => {
  assert.match(settings, /TeamsDesktopHelperDiagnosticsPanel/);
  assert.match(settings, /Local Helper Diagnostics/);
  assert.match(settings, /detectLocalCaptureHelper/);
  assert.match(settings, /formatLocalHelperDiagnosticRows/);
  assert.match(settings, /requestLocalCaptureHelperPairing/);
  assert.match(settings, /confirmLocalCaptureHelperPairing/);
  assert.match(settings, /Pair Helper/);
  assert.match(settings, /Teams Desktop capture starts from the sidebar/);
  assert.doesNotMatch(settings, /getLocalCaptureHelperStatus\([^)]*token:\s*""/s);
});

test("Page polls helper health and passes source options into the sidebar", () => {
  assert.match(page, /detectLocalCaptureHelper/);
  assert.match(page, /openLocalCaptureHelper/);
  assert.match(page, /buildRecordingSourceOptions/);
  assert.match(page, /recordingSources=\{recordingSources\}/);
});
