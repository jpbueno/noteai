# NoteAI Release Checklist

Use this checklist before shipping macOS or web changes.

## Required Verification

- Run `swift test`.
- From `web/`, run `npm run lint`.
- From `web/`, run `npx tsc --noEmit --pretty false`.
- From `web/`, run `npm run build`.
- For Cloudflare releases, run `npm run build:cf`.
- Smoke check the deployed web app with `GET /api/health` and confirm `ok: true`.
- Confirm the environment policy in `docs/security/cloudflare-turso-environment-separation.md` still applies.
- Confirm the GitHub `production` environment allows deployments only from `main`.
- Confirm `CLOUDFLARE_API_TOKEN` is configured as a GitHub `production` environment secret, or record the temporary repository-secret exception in Linear.
- Confirm the Turso production token rotation date has not passed.

## Web Runtime Configuration

Required Cloudflare Worker secrets:

- `TURSO_DATABASE_URL`
- `TURSO_AUTH_TOKEN`
- `NOTEAI_AUTH_SECRET`
- `GOOGLE_CLIENT_ID`

Optional secrets:

- `GOOGLE_ALLOWED_EMAILS`
- `NOTEAI_API_KEY_HASHES`

Provider API keys are stored through the app settings API and must remain write-only from browser reads.

Do not configure the legacy `NOTEAI_API_KEY` Worker secret. Programmatic REST access uses `NOTEAI_API_KEY_HASHES`.

Preview deploys must use preview-only values for the required Worker secrets and must not target production Turso.

The production Turso token is currently accepted as a single server-side write-capable token because schema initialization and CRUD share the same server path. It must be expiring and rotated on the cadence in `docs/security/turso-token-scope-rotation.md`.

Cloudflare Access is not currently required in front of the whole production app. Keep this accepted-risk decision aligned with `docs/security/cloudflare-access-waf-rate-limit-policy.md`, and revisit it before moving production to a custom Cloudflare zone hostname.

## Security Headers

The web release should include these headers on application routes:

- `Content-Security-Policy`
- `Strict-Transport-Security`
- `X-Content-Type-Options`
- `X-Frame-Options`
- `Referrer-Policy`
- `Permissions-Policy`

The current CSP allows same-origin app assets, Google Identity Services frames and scripts, image data URLs, font data URLs, and the configured server-side provider origins documented in `web/next.config.ts`.

## Release Notes Template

```markdown
## Summary

- 

## User-Facing Changes

- 

## Verification

- 

## Rollout Notes

- 
```
