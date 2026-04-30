import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(".github/workflows/secret-scan.yml", "utf8");
const securityPolicy = readFileSync("SECURITY.md", "utf8");
const cicdRunbook = readFileSync("docs/linear-cicd.md", "utf8");

test("secret scan workflow covers pull requests, scheduled history scans, and baseline review", () => {
  assert.match(workflow, /pull_request:/);
  assert.match(workflow, /schedule:/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /fetch-depth:\s*0/);
  assert.match(workflow, /gitleaks\/gitleaks:v8\./);
  assert.match(workflow, /--baseline-path\s+\.gitleaks\.baseline\.json/);
  assert.match(workflow, /--report-format\s+sarif/);
  assert.match(workflow, /upload-artifact@v6/);
});

test("security docs explain rotation and branch protection expectations", () => {
  assert.match(securityPolicy, /Credential Rotation for Confirmed Leaks/);
  assert.match(securityPolicy, /Revoke or rotate the leaked credential/);
  assert.match(securityPolicy, /Gitleaks baseline/i);
  assert.match(cicdRunbook, /Secret Scan \/ Gitleaks git history scan/);
  assert.match(cicdRunbook, /branch protection/i);
});
