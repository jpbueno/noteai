import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

const trackedFiles = execFileSync("git", ["ls-files"], { encoding: "utf8" })
  .split("\n")
  .filter(Boolean);
const gitignore = readFileSync(".gitignore", "utf8");

const forbiddenTrackedPatterns = [
  /^output\//,
  /^scratch\//,
  /(^|\/)\.DS_Store$/,
  /(^|\/)\.env(?:\.|$)/,
  /(^|\/)(?:node_modules|\.next|\.open-next|\.wrangler|DerivedData|\.xcode-build|\.build)\//,
  /\.(?:sqlite|sqlite3|db|log|xcresult)$/,
  /\.(?:profraw)$/,
];

test("repository does not track local artifacts or runtime data", () => {
  const forbiddenFiles = trackedFiles.filter((file) =>
    forbiddenTrackedPatterns.some((pattern) => pattern.test(file)),
  );

  assert.deepEqual(forbiddenFiles, []);
});

test("gitignore documents local artifact directories", () => {
  assert.match(gitignore, /^output\/$/m);
  assert.match(gitignore, /^scratch\/$/m);
  assert.match(gitignore, /^\.env$/m);
  assert.match(gitignore, /^\.env\.\*$/m);
});
