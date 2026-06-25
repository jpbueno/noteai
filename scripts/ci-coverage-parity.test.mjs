import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const ciCoverageWorkflowPath = ".github/workflows/ci-coverage.yml";
const ciCoverageWorkflow = existsSync(ciCoverageWorkflowPath)
  ? readFileSync(ciCoverageWorkflowPath, "utf8")
  : "";
const webWorkflow = readFileSync(".github/workflows/web-ci.yml", "utf8");
const macOSWorkflow = readFileSync(".github/workflows/macos-ci.yml", "utf8");
const cicdRunbook = readFileSync("docs/linear-cicd.md", "utf8");
const followups = readFileSync("docs/ci-security-followups.md", "utf8");

const webTestFiles = readdirSync("web")
  .filter((entry) => entry.endsWith(".test.mjs"))
  .sort();

function assertWorkflowCoversPath(workflow, path) {
  const escaped = path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  assert.match(workflow, new RegExp(`["']?${escaped}["']?`));
}

test("CI coverage staleness check runs on workflow, docs, and test changes", () => {
  assert.ok(existsSync(ciCoverageWorkflowPath), `${ciCoverageWorkflowPath} should exist`);
  assert.match(ciCoverageWorkflow, /^name:\s*CI Coverage Staleness/m);
  assert.match(ciCoverageWorkflow, /pull_request:/);
  assert.match(ciCoverageWorkflow, /push:/);
  assert.match(ciCoverageWorkflow, /workflow_dispatch:/);
  assert.match(ciCoverageWorkflow, /node --test scripts\/ci-coverage-parity\.test\.mjs/);

  [
    ".github/workflows/**",
    ".gitignore",
    "CONTRIBUTING.md",
    "README.md",
    "docs/linear-cicd.md",
    "docs/ci-security-followups.md",
    "scripts/ci-coverage-parity.test.mjs",
    "scripts/repository-hygiene.test.mjs",
    "web/*.test.mjs",
    "NoteAITests/**",
  ].forEach((path) => assertWorkflowCoversPath(ciCoverageWorkflow, path));

  assert.match(
    ciCoverageWorkflow,
    /node --test scripts\/ci-coverage-parity\.test\.mjs scripts\/repository-hygiene\.test\.mjs/,
  );
});

test("web CI invokes every checked-in web regression test", () => {
  assert.ok(webTestFiles.length > 0, "expected at least one web regression test");
  assert.match(webWorkflow, /node-version:\s*22/);
  assert.match(webWorkflow, /npm ci/);
  assert.match(webWorkflow, /npm run lint/);
  assert.match(webWorkflow, /tsc --noEmit --pretty false/);
  assert.match(webWorkflow, /npm audit --omit=dev --audit-level=high/);
  assert.match(webWorkflow, /npm run build/);

  for (const testFile of webTestFiles) {
    assert.match(
      webWorkflow,
      new RegExp(`node --test (?:[^\\n]*\\*\\.test\\.mjs|[^\\n]*${testFile.replaceAll(".", "\\.")})`),
      `web CI should run ${testFile}`,
    );
  }
});

test("macOS CI documents the current Xcode build and test gate", () => {
  assert.match(macOSWorkflow, /runs-on:\s*macos-15/);
  assert.match(macOSWorkflow, /xcodebuild -version/);
  assert.match(macOSWorkflow, /swift --version/);
  assert.match(macOSWorkflow, /xcodebuild -resolvePackageDependencies -project NoteAI\.xcodeproj -scheme NoteAI/);
  assert.match(macOSWorkflow, /CODE_SIGNING_ALLOWED=NO[\s\\]+build/);
  assert.match(macOSWorkflow, /CODE_SIGNING_ALLOWED=NO[\s\\]+test/);

  assert.match(followups, /builds and tests the Xcode project/);
  assert.doesNotMatch(followups, /Restore full Xcode project build\/test CI/);
});

test("CI runbook records the parity matrix and required branch checks", () => {
  assert.match(cicdRunbook, /## CI Coverage Matrix/);
  assert.match(cicdRunbook, /Web CI \/ Lint, build, and security regression/);
  assert.match(cicdRunbook, /macOS CI \/ Xcode build and test/);
  assert.match(cicdRunbook, /CI Coverage Staleness \/ Coverage parity cleanup check/);
  assert.match(cicdRunbook, /Secret Scan \/ Gitleaks git history scan/);
  assert.match(cicdRunbook, /macos-15/);
  assert.match(cicdRunbook, /Node\.js 22/);
  assert.match(cicdRunbook, /JPB-32/);
});
