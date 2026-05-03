# Cloudflare and Turso Environment Separation

Date: 2026-05-03

Related Linear issues: JPB-79, JPB-22

## Decision

NoteAI should have an explicit Cloudflare/Turso preview environment before any production-like cloud preview testing. Until the preview Worker and preview Turso database are provisioned, pull requests remain local/CI-only and must not point at production Turso data before merge.

This keeps the current zero-cost delivery path predictable while creating a clear, no-secret contract for future preview deployment.

## Production

Production remains the only automatically deployed cloud environment.

- GitHub workflow: `.github/workflows/web-deploy-cloudflare.yml`
- Branch: `main`
- Worker: `noteai-web`
- URL: `https://noteai-web.noteai-jp.workers.dev`
- Cloudflare deploy command: `npx wrangler deploy --env="" --keep-vars`
- Runtime database: production Turso database only

Required production Worker secrets:

- `TURSO_DATABASE_URL`
- `TURSO_AUTH_TOKEN`
- `NOTEAI_AUTH_SECRET`
- `GOOGLE_CLIENT_ID`

Optional production Worker secrets:

- `GOOGLE_ALLOWED_EMAILS`
- `NOTEAI_API_KEY_HASHES`

Production verification:

```bash
npx wrangler secret list --name noteai-web
curl --fail --silent --show-error https://noteai-web.noteai-jp.workers.dev/api/health
curl --silent --output /dev/null --write-out '%{http_code}\n' https://noteai-web.noteai-jp.workers.dev/api/data/notes
```

Expected results:

- The required secret names are present in Cloudflare.
- `/api/health` returns `ok: true`.
- Unauthenticated `/api/data/notes` returns `401`.

## Preview

Preview is defined as a future Cloudflare Worker environment named `preview` in `web/wrangler.jsonc`. Wrangler creates a separate Worker identity for named environments, so the preview Worker is `noteai-web-preview`.

The preview Worker must not use production Turso data.

Current status as of 2026-05-03: preview is defined in config but not deployed. `npx wrangler secret list --env preview` returned `Worker "noteai-web-preview" (env: preview) not found`, which is expected until a preview Turso database and preview Worker are intentionally provisioned.

Required preview Worker secrets use the same names as production but must have preview-only values:

- `TURSO_DATABASE_URL`: preview Turso database URL, not the production database URL
- `TURSO_AUTH_TOKEN`: preview database token, not the production database token
- `NOTEAI_AUTH_SECRET`: preview-only session secret
- `GOOGLE_CLIENT_ID`: preview OAuth client ID, or a documented decision to reuse the production OAuth client only for maintainer-only preview testing

Optional preview Worker secrets:

- `GOOGLE_ALLOWED_EMAILS`: normally restricted to maintainers
- `NOTEAI_API_KEY_HASHES`: only if programmatic preview API access is required

Provision preview secrets with no values committed to git:

```bash
cd web
npx wrangler secret put TURSO_DATABASE_URL --env preview
npx wrangler secret put TURSO_AUTH_TOKEN --env preview
npx wrangler secret put NOTEAI_AUTH_SECRET --env preview
npx wrangler secret put GOOGLE_CLIENT_ID --env preview
```

Preview deployment remains manual until a separate preview Turso database exists:

```bash
cd web
npm run build:cf
npx wrangler deploy --env preview --keep-vars
```

Because `web/wrangler.jsonc` defines a named preview environment, production deploys should pass `--env=""` explicitly to target the top-level production Worker.

## Guardrails

- Pull requests must use local fixtures, local non-production persistence, or CI tests only.
- Do not point a PR, local preview, or temporary Worker at production `TURSO_DATABASE_URL`.
- Do not copy production `TURSO_AUTH_TOKEN` into preview or local files.
- Never commit `.env*`, `.dev.vars*`, Wrangler local state, or raw API keys.
- A preview Worker should be deleted or disabled when it is no longer actively used.

## Future Codex Verification

When touching preview/production deployment work, verify:

1. `web/wrangler.jsonc` still declares separate `env.preview` required secrets.
2. `npx wrangler secret list --name noteai-web` has production secrets by name only.
3. `npx wrangler secret list --env preview` has preview secrets by name only if preview is active.
4. The production health endpoint returns `ok: true`.
5. The production data API still returns `401` without auth.
6. Linear records whether preview deploys are inactive, manually active, or automated.

## Source References

- Cloudflare Wrangler environments create separate environment Workers and require per-environment secrets: https://developers.cloudflare.com/workers/wrangler/environments/
- Cloudflare Wrangler configuration documents `secrets.required`, `workers_dev`, and route/custom-domain options: https://developers.cloudflare.com/workers/wrangler/configuration/
- Turso branches are separate database instances for development and testing, and require their own connection token: https://docs.turso.tech/features/branching
