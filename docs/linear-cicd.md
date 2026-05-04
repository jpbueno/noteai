# Linear, CI, and Deployment Workflow

This runbook describes the NoteAI workflow for Linear-managed development, zero-cost CI, and Cloudflare deployment.

## Operating Model

- Linear is the planning and completion source of truth.
- GitHub is the source-control and CI orchestration layer for the current remote.
- GitHub Actions runs CI on pull requests and `main`.
- Cloudflare Workers hosts the web app through the existing OpenNext/Wrangler setup.
- `main` is the source of truth for completed NoteAI work. Completed and tested work should not remain only on Codex, feature, or temporary branches.
- The current NoteAI remote is GitHub. If the repository moves to GitLab later, update this runbook and the automation references before relying on the same workflow names.

## Done Means Delivered

Do not mark a NoteAI Linear issue as `Done` just because local work is complete or a chat summary says it is complete.

For any task with repository changes, `Done` requires all of this evidence:

- The work is committed with the Linear issue ID in the commit message.
- The commit is pushed to the remote `main` branch, unless branch protection requires a PR-only flow.
- If branch protection requires a PR, the PR references the Linear issue ID, required checks pass, and the PR is merged into `main`.
- Post-push or post-merge GitHub Actions ran for `main`, or the task is in a path that intentionally does not trigger checks.
- For web or deployment-impacting changes, the Cloudflare deploy workflow succeeds after `main` updates.
- For web deployments, a live smoke check passes, starting with `GET /api/health` when that endpoint is expected to be public.
- Linear has a completion comment with the remote commit, verification commands/results, deployment status, affected files/modules, branch cleanup, and any follow-ups.

If the task did not require repository changes, the Linear completion comment must explicitly say `No repository changes required` and explain why.

If Linear updates are blocked by connector or credential handling, complete the git, CI, merge, and deployment path anyway, then provide a manual Linear update for the user to paste. Do not treat the issue as delivered based only on local verification.

## Linear Setup

Use the `Jpbueno` Linear team and the `NoteAI Product Roadmap` project unless a more specific NoteAI project exists. Move active implementation and test work to `In Progress` or `In Review` before leaving chat-only status.

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
- `macOS CI / Xcode build and test`
- `CI Coverage Staleness / Coverage parity cleanup check`
- `Secret Scan / Gitleaks git history scan`

## CI Coverage Matrix

JPB-32 tracks parity between the web and Swift/macOS verification gates. The first parity slice is a staleness/cleanup check: keep workflow triggers, branch-protection names, documentation, and lightweight regression tests aligned before expanding runner-heavy native coverage.

| Area | Workflow check | Runner | Current gate | Cleanup guard |
| --- | --- | --- | --- | --- |
| Web app | `Web CI / Lint, build, and security regression` | Ubuntu with Node.js 22 | `npm ci`, ESLint, `tsc --noEmit`, every checked-in `web/*.test.mjs`, production dependency audit, and Next.js build | `CI Coverage Staleness / Coverage parity cleanup check` fails if a checked-in web regression test is not invoked by web CI. |
| Swift/macOS | `macOS CI / Xcode build and test` | GitHub-hosted `macos-15` | Xcode package resolution, app build, and test suite with code signing disabled | `CI Coverage Staleness / Coverage parity cleanup check` records the current Swift gate and keeps native CI docs visible. |
| Secrets | `Secret Scan / Gitleaks git history scan` | Ubuntu | Full-history Gitleaks scan with the reviewed baseline and uploaded SARIF report | `scripts/secret-scanning-workflow.test.mjs` keeps the secret-scan workflow and docs aligned. |
| CI parity docs | `CI Coverage Staleness / Coverage parity cleanup check` | Ubuntu | `node --test scripts/ci-coverage-parity.test.mjs` | Runs on workflow, CI documentation, web regression test, and macOS test changes. |

Recommended branch protection for `main`:

- Require a pull request before merging when direct pushes are not appropriate.
- Require status checks to pass.
- Require branches to be up to date before merging.
- Require conversation resolution before merge.
- Allow squash merge.
- Disable direct pushes to `main` for normal development unless the user explicitly asks Codex to land verified work directly.
- Add `Secret Scan / Gitleaks git history scan` to required checks after the first scheduled run is stable and any reviewed baseline entries are committed.
- Add `CI Coverage Staleness / Coverage parity cleanup check` to required checks after the first run is stable so CI drift is caught before merge.

This keeps automatic deploys predictable: production changes only after `main` contains the completed, verified work.

## Cloudflare Deployment

The workflow `.github/workflows/web-deploy-cloudflare.yml` deploys the web app to Cloudflare Workers after a push to `main` that changes `web/**` or the deploy workflow itself. Because `web/wrangler.jsonc` also declares `env.preview`, production deploys pass `--env=""` to target the top-level production Worker explicitly.

The workflow `.github/workflows/web-migrate-turso.yml` runs production Turso schema/data migrations manually from `main` before a deploy that needs database shape changes. It uses the GitHub `production` environment and the `TURSO_MIGRATION_AUTH_TOKEN` environment secret so normal request-time reads do not need schema or data-migration privileges.

Target GitHub production environment secret:

- `CLOUDFLARE_API_TOKEN`

The token should have the minimum permissions needed to deploy the `noteai-web` Worker. Runtime app secrets stay in Cloudflare and are preserved by `wrangler deploy --keep-vars`.

The GitHub `production` environment must restrict deployments to `main`. Environment-scoped `CLOUDFLARE_API_TOKEN` is the target posture because environment secrets are only released to jobs that reference the environment after its protection rules pass. If only a repository-scoped `CLOUDFLARE_API_TOKEN` exists, it is accepted only as the bounded current-token exception documented in `docs/security/cloudflare-production-deploy-token-hardening.md`; move it during the next Cloudflare token rotation.

Production is the only automatically deployed cloud environment. Preview is defined but manual-only until a separate preview Turso database and preview Worker secrets exist. Pull requests must stay local/CI-only and must not point at production Turso data before merge. See `docs/security/cloudflare-turso-environment-separation.md`.

Required Cloudflare Worker secrets:

- `TURSO_DATABASE_URL`
- `TURSO_AUTH_TOKEN`
- `NOTEAI_AUTH_SECRET`
- `GOOGLE_CLIENT_ID`

Optional Cloudflare Worker secrets:

- `GOOGLE_ALLOWED_EMAILS`
- `NOTEAI_API_KEY_HASHES`

Do not use or recreate the legacy `NOTEAI_API_KEY` Worker secret. Programmatic API access uses `NOTEAI_API_KEY_HASHES`.

Turso restore/cutover steps live in `docs/security/turso-restore-runbook.md`. Restore operations must update `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` through Cloudflare Worker secrets without committing or printing values.

Turso token rotation policy lives in `docs/security/turso-token-scope-rotation.md`. Schema creation, historical column migrations, and encrypted settings migration now run through `npm run migrate:turso` or the manual `Web Turso Migration` workflow, not normal request-time reads. Configure these GitHub `production` environment secrets before running the workflow:

- `TURSO_DATABASE_URL`
- `TURSO_MIGRATION_AUTH_TOKEN`
- `NOTEAI_AUTH_SECRET`

The runtime `TURSO_AUTH_TOKEN` can be split into read/write tokens in a later slice because schema work now sits behind a separate migration Adapter.

Cloudflare Access/WAF/rate-limit policy lives in `docs/security/cloudflare-access-waf-rate-limit-policy.md`. The current `workers.dev` production app remains public with application auth; WAF and rate-limit rules should be added when NoteAI moves to a custom Cloudflare zone hostname or traffic evidence justifies account-level controls.

## macOS Deployment

The macOS workflow builds and tests the Xcode project on GitHub-hosted macOS runners. It does not notarize, sign for distribution, or publish a user-facing app update. That keeps this zero-cost and avoids requiring Apple Developer release automation in CI.

Treat macOS CI as a merge gate for the native app. Create release artifacts manually when needed, or add a separate manually triggered release workflow later if signing/notarization credentials are available.

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
