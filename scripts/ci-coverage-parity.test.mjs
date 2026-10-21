import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

const ciCoverageWorkflowPath = ".github/workflows/ci-coverage.yml";
const ciCoverageWorkflow = existsSync(ciCoverageWorkflowPath)
  ? readFileSync(ciCoverageWorkflowPath, "utf8")
  : "";
const macOSWorkflow = readFileSync(".github/workflows/macos-ci.yml", "utf8");
const cicdRunbook = readFileSync("docs/linear-cicd.md", "utf8");
const followups = readFileSync("docs/ci-security-followups.md", "utf8");

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
    "web/**",
    "NoteAITests/**",
  ].forEach((path) => assertWorkflowCoversPath(ciCoverageWorkflow, path));

  assert.match(
    ciCoverageWorkflow,
    /node --test scripts\/ci-coverage-parity\.test\.mjs scripts\/repository-hygiene\.test\.mjs/,
  );
});

test("retired web source and automation cannot return unnoticed", () => {
  for (const path of [
    "web",
    ".github/workflows/web-ci.yml",
    ".github/workflows/web-deploy-cloudflare.yml",
    ".github/workflows/web-migrate-turso.yml",
    "scripts/turso-to-macos-sync.mjs",
    "scripts/turso-to-macos-sync.test.mjs",
  ]) {
    assert.equal(existsSync(path), false, `${path} belongs to the retired web app`);
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
  assert.match(cicdRunbook, /macOS CI \/ Xcode build and test/);
  assert.match(cicdRunbook, /CI Coverage Staleness \/ Coverage parity cleanup check/);
  assert.match(cicdRunbook, /Secret Scan \/ Gitleaks git history scan/);
  assert.match(cicdRunbook, /macos-15/);
  assert.match(cicdRunbook, /JPB-32/);
});
