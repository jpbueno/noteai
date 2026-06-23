# NoteAI Release Checklist

Use this checklist before shipping macOS or web changes.

## Required Verification

- Run `swift test`.
- From `web/`, run `npm run lint`.
- From `web/`, run `npx tsc --noEmit --pretty false`.
- From `web/`, run `npm run build`.
- Confirm no public web deployment is being created unless a new security review and Linear issue explicitly approve it.
- Confirm the Turso production token rotation date has not passed.
- If a web change affects Turso schema or stored encrypted settings format, run `Web Turso Migration` from `main` before using the updated code against production data.

## Web Runtime Configuration

Required server-side runtime values when the web app is run in a controlled local or private environment:

- `TURSO_DATABASE_URL`
- `TURSO_AUTH_TOKEN`
- `NOTEAI_AUTH_SECRET`
- `GOOGLE_CLIENT_ID`

Optional secrets:

- `GOOGLE_ALLOWED_EMAILS`
- `NOTEAI_API_KEY_HASHES`

Provider API keys are stored through the app settings API and must remain write-only from browser reads.

Do not configure the legacy `NOTEAI_API_KEY` Worker secret. Programmatic REST access uses `NOTEAI_API_KEY_HASHES`.

Public web deployments are intentionally disabled. Do not create preview or production web deployments that target production Turso.

Turso schema/data migrations are explicit. Use `npm run migrate:turso` locally or the `Web Turso Migration` workflow in production with `TURSO_MIGRATION_AUTH_TOKEN`; normal request-time reads should not create tables, alter columns, or encrypt legacy plaintext settings.

Historical Cloudflare Access/WAF/rate-limit notes remain in `docs/security/`, but they are audit records, not approval to expose the web app again.

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
