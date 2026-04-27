# Linear-Managed Zero-Cost CI/CD

This runbook describes the NoteAI workflow for moving from a Linear issue to committed, pushed, tested, and deployed code without paid CI/CD infrastructure.

## Operating Model

- Linear is the planning and status source of truth.
- GitHub is the source-control and automation engine.
- GitHub Actions runs CI on pull requests and `main`.
- Cloudflare Workers hosts the web app through the existing OpenNext/Wrangler setup.
- Codex may commit and push implementation branches when the user asks it to finish a task, but production deploys happen only from `main`.

## Linear Setup

Enable the official Linear GitHub integration for the NoteAI repository.

Use these conventions:

- Team: `Jpbueno`
- Project: `NoteAI Product Roadmap`
- Branches include the Linear issue ID, such as `codex-jpb-34-zero-cost-cicd`.
- Commit messages include the Linear issue ID, such as `JPB-34 Add Cloudflare deploy workflow`.
- Pull request titles include the Linear issue ID.

With the GitHub integration enabled, Linear links branches, commits, and pull requests to issues automatically and can move issues through workflow states as PRs open, review, merge, or close.

## GitHub Actions

Required checks for branch protection:

- `Web CI / Lint, build, and security regression`
- `macOS CI / Swift package tests`
- `CI Coverage Staleness / Coverage parity cleanup check`
- `Secret Scan / Gitleaks git history scan`

## CI Coverage Matrix

JPB-32 tracks parity between the web and Swift/macOS verification gates. The first parity slice is a staleness/cleanup check: keep workflow triggers, branch-protection names, documentation, and lightweight regression tests aligned before expanding runner-heavy native coverage.

| Area | Workflow check | Runner | Current gate | Cleanup guard |
| --- | --- | --- | --- | --- |
| Web app | `Web CI / Lint, build, and security regression` | Ubuntu with Node.js 22 | `npm ci`, ESLint, `tsc --noEmit`, every checked-in `web/*.test.mjs`, production dependency audit, and Next.js build | `CI Coverage Staleness / Coverage parity cleanup check` fails if a checked-in web regression test is not invoked by web CI. |
| Swift/macOS | `macOS CI / Swift package tests` | GitHub-hosted `macos-15` | Toolchain version logging and `swift test` for shared Swift logic | `CI Coverage Staleness / Coverage parity cleanup check` records the current Swift gate and keeps the deferred Xcode build/test follow-up visible. |
| Secrets | `Secret Scan / Gitleaks git history scan` | Ubuntu | Full-history Gitleaks scan with the reviewed baseline and uploaded SARIF report | `scripts/secret-scanning-workflow.test.mjs` keeps the secret-scan workflow and docs aligned. |
| CI parity docs | `CI Coverage Staleness / Coverage parity cleanup check` | Ubuntu | `node --test scripts/ci-coverage-parity.test.mjs` | Runs on workflow, CI documentation, web regression test, and macOS test changes. |

Recommended branch protection for `main`:

- Require pull request before merge.
- Require status checks to pass.
- Require conversation resolution before merge.
- Allow squash merge.
- Disable direct pushes to `main` for normal development.
- Add `Secret Scan / Gitleaks git history scan` to required checks after the first scheduled run is stable and any reviewed baseline entries are committed.
- Add `CI Coverage Staleness / Coverage parity cleanup check` to required checks after the first run is stable so CI drift is caught before merge.

This keeps automatic deploys cheap and predictable: Codex can push branches freely, but production only changes after checks pass and the PR merges.

## Web Deployment

The workflow `.github/workflows/web-deploy-cloudflare.yml` deploys the web app to Cloudflare Workers after a push to `main` that changes `web/**` or the deploy workflow itself.

Required GitHub repository secret:

- `CLOUDFLARE_API_TOKEN`

The token should have the minimum permissions needed to deploy the `noteai-web` Worker. Runtime app secrets stay in Cloudflare and are preserved by `wrangler deploy --keep-vars`.

Required Cloudflare Worker secrets:

- `TURSO_DATABASE_URL`
- `TURSO_AUTH_TOKEN`
- `NOTEAI_AUTH_SECRET`
- `GOOGLE_CLIENT_ID`

Optional Cloudflare Worker secrets:

- `GOOGLE_ALLOWED_EMAILS`
- `NOTEAI_API_KEY_HASHES`

## macOS Deployment

The macOS workflow runs Swift package tests on GitHub-hosted macOS runners. It does not notarize, sign for distribution, or publish a user-facing app update. That keeps this zero-cost and avoids requiring Apple Developer release automation in CI.

Treat macOS CI as a merge gate for shared Swift logic. Create release artifacts manually when needed, or add a separate manually triggered release workflow later after the checked-in Xcode project is regenerated and signing/notarization credentials are available.

## Codex Finish Workflow

When Codex completes a NoteAI task:

1. Update the Linear issue to `In Progress` or `In Review`.
2. Run the relevant local verification commands.
3. Commit only the files changed for that task and include the Linear issue ID in the commit message.
4. Push completed and tested work to `main` so `main` remains the source of truth. If branch protection blocks direct push, push a branch, open a PR with the Linear issue ID in the title, merge it, and then verify `main`.
5. Confirm the commit is visible on the remote `main` branch.
6. Confirm GitHub Actions ran for the `main` push.
7. For web-affecting changes, confirm `Web Deploy to Cloudflare` completed successfully and smoke-check the deployed Worker when the workflow exposes a URL or health endpoint.
8. Delete obsolete local and remote branches only after confirming their useful commits are included in `main` by ancestry or patch equivalence.
9. Update Linear with changed files, verification results, remote commit, deployment status, branch cleanup, and follow-ups.

Do not mark a Linear item `Done` while its completed implementation exists only on a local worktree or side branch. If any local check, push, CI job, or Cloudflare deployment fails, keep the issue active, record the failure, and create or link follow-up work rather than treating the task as complete.

## Cost Guardrails

- Keep the repository public if unlimited standard GitHub-hosted runner usage is required.
- If the repository is private, stay within GitHub Free's included Actions minutes and artifact storage.
- Avoid running macOS CI on web-only changes.
- Avoid storing large build artifacts.
- Prefer Cloudflare Worker secrets and GitHub repository secrets over paid secret-management services.
- Use manual `workflow_dispatch` reruns when debugging expensive CI failures.

## Secret and History Scanning

`.github/workflows/secret-scan.yml` runs Gitleaks on pull requests, pushes to `main`, a weekly Monday schedule, and manual dispatch. It checks out the full git history with `fetch-depth: 0`, runs the pinned `ghcr.io/gitleaks/gitleaks` container, redacts findings in logs, and uploads the SARIF report as a workflow artifact for review.

The committed `.gitleaks.baseline.json` is intentionally empty. If a historical finding is confirmed as already rotated or otherwise accepted, regenerate a Gitleaks JSON report, review each entry, commit only the approved baseline entries, and document the accepted risk in Linear before making the secret scan a required branch protection check.
