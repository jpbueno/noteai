# Linear-Managed Zero-Cost CI/CD

This runbook describes the NoteAI workflow for moving from a Linear issue to committed, pushed, tested, and deployed code without paid CI/CD infrastructure.

## Operating Model

- Linear is the planning and status source of truth.
- GitHub is the source-control and automation engine.
- GitHub Actions runs CI on pull requests and `main`.
- Cloudflare Workers hosts the web app through the existing OpenNext/Wrangler setup.
- Codex may commit and push implementation branches when the user asks it to finish a task, but production deploys happen only from `main`.
- The current NoteAI remote is GitHub. If the repository moves to GitLab later, update this runbook and the automation references before relying on the same workflow names.

## Done Means Delivered

Do not mark a NoteAI Linear issue as `Done` just because local work is complete or a chat summary says it is complete.

For any task with repository changes, `Done` requires all of this evidence:

- The branch contains committed changes with the Linear issue ID in the commit message.
- The branch has been pushed to `origin`.
- A pull request exists and references the Linear issue ID.
- Required pull request checks pass.
- The pull request is merged into `main`.
- Post-merge `main` checks are green, or the task is in a path that intentionally does not trigger checks.
- For web or deployment-impacting changes, the Cloudflare deploy workflow succeeds after merge.
- For web deployments, a live smoke check passes, starting with `GET /api/health`.
- Linear has a completion comment with the PR link, merge commit, verification commands/results, deployment status, affected files/modules, and any follow-ups.

If the task did not require repository changes, the Linear completion comment must explicitly say `No repository changes required` and explain why.

If Linear updates are blocked by connector or credential handling, complete the git, CI, merge, and deployment path anyway, then provide a manual Linear update for the user to paste. Do not treat the issue as delivered based only on local verification.

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
- `macOS CI / Xcode build and test`

Recommended branch protection for `main`:

- Require pull request before merge.
- Require status checks to pass.
- Require conversation resolution before merge.
- Allow squash merge.
- Disable direct pushes to `main` for normal development.

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

The macOS workflow builds and tests the Xcode project on GitHub-hosted macOS runners. It does not notarize, sign for distribution, or publish a user-facing app update. That keeps this zero-cost and avoids requiring Apple Developer release automation in CI.

Treat macOS CI as a merge gate for the native app. Create release artifacts manually when needed, or add a separate manually triggered release workflow later if signing/notarization credentials are available.

## Codex Finish Workflow

When Codex completes a NoteAI task:

1. Update the Linear issue to `In Progress` or `In Review`.
2. Run the relevant local verification commands.
3. Commit only the files changed for that task.
4. Include the Linear issue ID in the commit message.
5. Push the branch.
6. Open a PR with the Linear issue ID in the title.
7. Let GitHub Actions and branch protection gate the merge.
8. After merge, the Cloudflare workflow deploys web changes automatically.
9. For web or deployment-impacting changes, verify the Cloudflare deployment succeeded and run a live smoke check.
10. Update Linear with changed files, verification results, deployment status, and follow-ups.
11. Move Linear to `Done` only after the required evidence above is complete.

## Cost Guardrails

- Keep the repository public if unlimited standard GitHub-hosted runner usage is required.
- If the repository is private, stay within GitHub Free's included Actions minutes and artifact storage.
- Avoid running macOS CI on web-only changes.
- Avoid storing large build artifacts.
- Prefer Cloudflare Worker secrets and GitHub repository secrets over paid secret-management services.
- Use manual `workflow_dispatch` reruns when debugging expensive CI failures.
