# Turso Token Scope and Rotation Posture

Date: 2026-05-04

Related Linear issues: JPB-78, JPB-22, JPB-80

## Decision

Keep a single server-side write-capable Turso database token for the current production app, but require it to be expiring and rotated on a 90-day cadence.

This is accepted for the current implementation because the normal server database path does schema initialization, reads, writes, deletes, and table clears through one server-only Turso client in `web/src/lib/server-db.ts`. A read-only token cannot support the current generic CRUD and migration path.

Read/write token separation should be implemented only after schema creation and migrations move out of normal request-time read paths.

## Evidence

Turso CLI access was not available in this Codex environment:

```text
turso auth whoami
You are not logged in, please login with turso auth login before running other commands.
```

Local ignored production env metadata was inspected without printing token or database values:

- `TURSO_AUTH_TOKEN` is present in the ignored local production env file.
- The token is a JWT using `EdDSA`.
- Token claim keys observed: `exp`, `iat`, `id`, `rid`.
- Issued at: `2026-03-30T15:05:13Z`.
- Expires at: `2026-06-28T15:05:13Z`.
- The token was not expired at inspection time.
- The JWT claims did not expose read-only/full-access authorization, organization scope, group scope, or database scope in a human-readable field.

A read-only HTTP metadata query using the ignored local env failed with `404`, so the local env values were not treated as proof of active Cloudflare production Worker configuration. No secret values were printed.

## Rotation Owner and Cadence

- Owner: JP Santana / NoteAI maintainer
- Normal cadence: every 90 days, before the current token expires
- Emergency trigger: suspected token exposure, unexpected Turso access, bad deploy writing corrupt data, or maintainer device compromise

## Normal Rotation

1. Create a replacement database token with a bounded expiration:

   ```bash
   turso db tokens create <production-db-name> --expiration 90d
   ```

2. Update the production Worker secret interactively:

   ```bash
   cd web
   npx wrangler secret put TURSO_AUTH_TOKEN --name noteai-web
   ```

3. Smoke-check production:

   ```bash
   curl --fail --silent --show-error https://noteai-web.noteai-jp.workers.dev/api/health
   curl --silent --output /dev/null --write-out '%{http_code}\n' https://noteai-web.noteai-jp.workers.dev/api/data/notes
   ```

4. Record the rotation in Linear with:
   - token creation date,
   - expiration date,
   - secret name updated,
   - smoke-check results,
   - no token value.

## Emergency Invalidation

If a token is suspected compromised:

1. Create a maintenance window because invalidation affects all database auth tokens in the database group.
2. Invalidate existing database tokens:

   ```bash
   turso db tokens invalidate <production-db-name> --yes
   ```

3. Create and install a new expiring token using the normal rotation steps.
4. Re-run application smoke checks and targeted authenticated checks.
5. Record count-only validation and secret names in Linear.

## Deferred Improvement

Implement read/write separation after extracting schema and migration work from normal request-time reads. The target design is:

- migration/admin path: short-lived full-access token;
- application read path: read-only token where possible;
- application write path: bounded write token only for authenticated mutation routes.

## Source References

- Turso database tokens can be read-only and expiring: https://docs.turso.tech/cli/db/tokens/create
- Turso token invalidation invalidates all tokens for the database group and requires regenerated tokens: https://docs.turso.tech/cli/db/tokens/invalidate
- Turso restore operations require a new database token after restore: https://docs.turso.tech/features/point-in-time-recovery
