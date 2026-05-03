# JPB-81 Worker Secret Cleanup

Date: 2026-05-03

Related Linear issues: JPB-81, JPB-22

## Result

`NOTEAI_API_KEY` was obsolete and was removed from the production `noteai-web` Cloudflare Worker.

No secret values were printed or committed.

## Evidence

Current code and documentation use `NOTEAI_API_KEY_HASHES` for programmatic API authentication. Current `origin/main` had no runtime code reference to plain `NOTEAI_API_KEY`.

Evidence commands:

```bash
git grep -n -e 'NOTEAI_API_KEY' origin/main -- . ':!docs/security/jpb-22-cloudflare-turso-production-controls.md'
npx wrangler deployments status --name noteai-web
npx wrangler secret list --name noteai-web
npx wrangler secret delete NOTEAI_API_KEY --name noteai-web
npx wrangler secret list --name noteai-web
```

Active deployment evidence:

- Active Worker version at cleanup time: `d3d10661-8da8-4020-8f4c-7f5f9106aca4`
- Active deployment created: `2026-05-02T18:07:56.983Z`
- Active deployment source: Cloudflare deployment for the JPB-22 `main` merge

Secret inventory after cleanup:

- `GOOGLE_ALLOWED_EMAILS`
- `GOOGLE_CLIENT_ID`
- `NOTEAI_AUTH_SECRET`
- `TURSO_AUTH_TOKEN`
- `TURSO_DATABASE_URL`

`NOTEAI_API_KEY_HASHES` is optional and should only be configured when programmatic REST access is needed.

Post-cleanup smoke checks:

```bash
curl --fail --silent --show-error https://noteai-web.noteai-jp.workers.dev/api/health
curl --silent --output /dev/null --write-out '%{http_code}\n' https://noteai-web.noteai-jp.workers.dev/api/data/notes
```

Expected and observed:

- `/api/health` returned `ok: true`.
- Unauthenticated `/api/data/notes` returned `401`.

## Future Guardrail

Do not recreate `NOTEAI_API_KEY`. Programmatic API access must use a raw bearer key stored outside git and a base64 SHA-256 digest stored in `NOTEAI_API_KEY_HASHES`.
