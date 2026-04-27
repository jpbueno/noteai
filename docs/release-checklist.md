# NoteAI Release Checklist

Use this checklist before shipping macOS or web changes.

## Required Verification

- Run `swift test`.
- From `web/`, run `npm run lint`.
- From `web/`, run `npx tsc --noEmit --pretty false`.
- From `web/`, run `npm run build`.
- For Cloudflare releases, run `npm run build:cf`.
- Smoke check the deployed web app with `GET /api/health` and confirm `ok: true`.

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
