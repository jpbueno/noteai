# JPB-22 Cloudflare and Turso Production Security Controls

Date: 2026-05-02

## Scope

JPB-22 verifies the production security controls that were left unassessed by the 2026-04-26 audit:

- Cloudflare API token posture, Worker route binding, Access/WAF/rate-limit posture, logs, and runtime headers.
- Turso token posture, read/write separation, backup/restore posture, and preview vs production database separation.
- Production and preview secret configuration without recording secret values.

No secret values were printed or committed. Evidence below uses configuration, GitHub metadata, Cloudflare Wrangler metadata, live HTTP smoke checks, and public vendor documentation.

## Evidence Reviewed

| Area | Evidence |
| --- | --- |
| Cloudflare deploy | `.github/workflows/web-deploy-cloudflare.yml` deploys `main` web changes to `noteai-web` with `npx wrangler deploy --keep-vars` and GitHub secret `CLOUDFLARE_API_TOKEN`. |
| Web CI | `.github/workflows/web-ci.yml` runs lint, typecheck, checked-in web regression tests, production dependency audit, and Next build. |
| Worker config | `web/wrangler.jsonc` names the Worker, assets binding, Node compatibility, workers.dev routing, required runtime secrets, and observability. |
| Runtime headers | `web/next.config.ts` configures CSP, HSTS, frame, content-type, referrer, and permissions headers. |
| Runtime auth | `web/src/lib/api-auth.ts` fails closed when production browser auth is not configured and requires session or programmatic bearer auth for data APIs. |
| Turso client | `web/src/lib/server-db.ts` reads `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` only on the server side, uses parameterized Turso HTTP pipeline calls, and whitelists tables/columns before dynamic SQL. |
| Release docs | `docs/linear-cicd.md` and `docs/release-checklist.md` list required Cloudflare Worker secrets and deploy verification expectations. |
| GitHub metadata | Repository secret metadata showed `CLOUDFLARE_API_TOKEN` present. The `production` GitHub environment exists but has no protection rules and no environment-level secrets. |
| Cloudflare metadata | `wrangler secret list --name noteai-web` showed these Worker secrets: `GOOGLE_ALLOWED_EMAILS`, `GOOGLE_CLIENT_ID`, `NOTEAI_API_KEY`, `NOTEAI_AUTH_SECRET`, `TURSO_AUTH_TOKEN`, `TURSO_DATABASE_URL`. |
| Live smoke | `GET /api/health` returned `ok: true`; unauthenticated `GET /api/data/notes` returned `401`; production root included CSP, HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, and `Permissions-Policy`. |
| Turso CLI | `turso` CLI is installed, but not authenticated, so database inventory, token scope, and restore settings could not be verified directly. |

## External References

- Cloudflare Wrangler configuration documents `observability`, `workers_dev`, route/custom-domain configuration, and `secrets.required`: https://developers.cloudflare.com/workers/wrangler/configuration/
- Cloudflare Workers secrets documentation recommends secrets for sensitive runtime values and supports required secret validation: https://developers.cloudflare.com/workers/configuration/secrets/
- Cloudflare API token documentation recommends scoped API tokens, resource restrictions, optional client IP filtering, and token TTLs: https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
- Turso database token creation supports read-only tokens and expiration: https://docs.turso.tech/cli/db/tokens/create
- Turso Platform API database auth tokens support `full-access` and `read-only` authorization: https://docs.turso.tech/api-reference/databases/create-token
- Turso point-in-time recovery creates a new database from an existing database at a timestamp and requires updating the application connection string/token: https://docs.turso.tech/features/point-in-time-recovery

## Findings

### Medium: Turso token least privilege is not evidenced

The production app uses a single `TURSO_AUTH_TOKEN` for schema creation/migrations, reads, upserts, deletes, and table clears. That may be necessary for the current generic CRUD implementation, but the token scope, authorization level, expiration, and rotation cadence were not verifiable from repo metadata or unauthenticated Turso CLI output.

Remediation: verify the current production token in Turso, document whether it is database-scoped or group-scoped, confirm its expiration/rotation posture, and decide whether read/write separation is worth the added implementation depth.

### Medium: Preview and production data-plane separation is not evidenced

The repo and GitHub metadata show one production Worker workflow and one required Turso URL/token pair. There is no `wrangler` preview environment, preview Cloudflare Worker, preview Turso database, or preview secret set documented. Pull requests run CI but do not deploy a preview Worker or use a preview database.

Remediation: create a documented preview environment before testing production-like changes against shared data, or explicitly record that preview deploys are out of scope and only local/test fixtures are used pre-merge.

### Medium: Cloudflare deploy token is repository-wide

The GitHub repository has `CLOUDFLARE_API_TOKEN` as a repository secret. The `production` environment exists but has no environment-level secrets or protection rules. The workflow uses `environment: production`, but the deploy credential is available as a repo secret to any workflow that can reference it. Manual dispatch is now guarded to `refs/heads/main`, which prevents accidental production deploys from feature branches, but it does not replace environment-scoped credential storage.

Remediation: move `CLOUDFLARE_API_TOKEN` to the `production` environment, add the minimum viable environment protection, and confirm the token itself is scoped to the `noteai-web` Worker/account permissions required for deploy.

### Low: Cloudflare Access/WAF/rate-limit policy is not evidenced

The production app currently runs on the public workers.dev route. Application APIs are auth-gated, but no Cloudflare Access app, WAF rule, or rate-limit rule was found in repo configuration, and those account-level controls were not available through the local evidence path.

Remediation: decide whether NoteAI should remain a public workers.dev app protected by application auth only, or add Cloudflare Access/rate limiting for production routes. Record the chosen policy and evidence.

### Low: Turso backup/restore drill is not documented

No repo docs or workflow evidence described Turso point-in-time recovery, restore drills, recovery owner, recovery time objective, or the operational steps to switch `TURSO_DATABASE_URL` and regenerate a database token after a restore.

Remediation: add a small restore runbook and record the first restore-drill evidence in Linear.

### Low: Worker secret inventory contains an unused legacy-looking secret

Cloudflare secret inventory includes `NOTEAI_API_KEY`, while current code and docs use `NOTEAI_API_KEY_HASHES` for programmatic bearer authentication. This did not block production auth because API routes are still session-gated, but the unused secret should be either mapped to a current runtime need or removed.

Remediation: confirm whether `NOTEAI_API_KEY` is obsolete. If obsolete, remove it from Cloudflare after confirming no deployed Worker version still needs it. If current, document its purpose and update code/docs accordingly.

## Controls Confirmed

- Production data APIs fail closed without auth. A live unauthenticated request to `/api/data/notes` returned `401`.
- Production health endpoint is intentionally public and returned `{"ok":true,"service":"noteai-web"}`.
- Runtime security headers are configured and present on the live Worker.
- Worker runtime secrets are configured in Cloudflare, and deploys preserve dashboard secrets with `wrangler deploy --keep-vars`.
- Required Worker secrets are now declared in `wrangler.jsonc` so future deploys fail early if the production Worker is missing a required secret.
- Worker observability is now explicit in `wrangler.jsonc` with 10% head sampling.
- Next.js `X-Powered-By` output is disabled in `next.config.ts`.
- Production deploy now runs an automated `/api/health` smoke check immediately after `wrangler deploy`.
- Turso is accessed only from server API code; browser code calls same-origin `/api/*` endpoints.
- Server DB access uses parameterized SQL arguments and table/column whitelists for generic CRUD.
- Encrypted provider API key settings are write-only through browser reads; reads return configured status, not plaintext.

## Accepted Risks and Follow-Up Work

JPB-22 is a verification and documentation slice. The following items require account-level action or product/security policy choices and should be tracked separately:

1. Move the Cloudflare deploy token into the GitHub `production` environment and document its minimum Cloudflare API scopes.
2. Document or implement Cloudflare Access/WAF/rate-limit policy for the public workers.dev production route.
3. Verify and document Turso production token scope, expiration, and rotation cadence.
4. Decide whether to implement Turso read/write token separation or keep a single full-access server token behind app auth.
5. Add Turso preview-vs-production database separation if preview deploys become part of the delivery workflow.
6. Add a Turso PITR restore runbook and record the first restore drill.
7. Remove or document the `NOTEAI_API_KEY` Worker secret.

## Verification Commands and Results

Local and remote checks run for this slice:

- `git status --short --branch` in the coordinator checkout: dirty with unrelated pre-existing work, so JPB-22 used an isolated worktree.
- `git check-ignore -v .worktrees`: `.worktrees/` is ignored.
- `node -p "JSON.stringify(require('./web/package.json').scripts,null,2)"`: confirmed `dev`, `build`, `start`, `build:cf`, `preview:cf`, `deploy:cf`, and `lint`.
- `gh api repos/jpbueno/noteai/actions/secrets`: confirmed repository secret metadata for `CLOUDFLARE_API_TOKEN`.
- `gh api repos/jpbueno/noteai/environments`: confirmed `production` environment exists with no protection rules.
- `gh api repos/jpbueno/noteai/environments/production/secrets`: returned no environment-level secrets.
- `npx wrangler whoami`: confirmed logged-in Cloudflare account and broad OAuth scopes for the local user token.
- `npx wrangler secret list --name noteai-web`: confirmed required runtime Worker secrets by name, no values exposed.
- `turso auth whoami`: Turso CLI is not logged in, so direct Turso account checks are blocked.
- `curl -sSI https://noteai-web.noteai-jp.workers.dev`: confirmed live security headers and observed `x-powered-by: Next.js` before the `poweredByHeader` hardening in this slice.
- `curl -sS https://noteai-web.noteai-jp.workers.dev/api/health`: returned `ok: true`.
- `curl -sS -o /dev/null -w '%{http_code}\n' https://noteai-web.noteai-jp.workers.dev/api/data/notes`: returned `401`.
- `npm run lint`: passed.
- `npx tsc --noEmit --pretty false`: passed.
- `node --test *.test.mjs`: passed, 87 tests.
- `npm audit --omit=dev --audit-level=high`: passed, 0 vulnerabilities.
- `npm run build`: passed.
- `npm run build:cf`: passed. Wrangler warned that the `secrets` config field is experimental.
- `npx wrangler deploy --dry-run --outdir /tmp/noteai-jpb22-dry-run`: passed and validated the updated Worker config without publishing.
- The exact workflow health-smoke command now in `.github/workflows/web-deploy-cloudflare.yml` passed locally against production.
