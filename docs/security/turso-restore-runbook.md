# Turso Backup and Restore Runbook

Date: 2026-05-03

Related Linear issues: JPB-80, JPB-22

## Purpose

Recover NoteAI web data from a Turso point-in-time recovery event without exposing secret values in git, Linear, shell history, logs, or chat.

## Owner and Targets

- Owner: JP Santana / NoteAI maintainer
- Primary system: production Turso database used by the `noteai-web` Cloudflare Worker
- Recovery target: restore to a new Turso database, validate it, then switch Cloudflare Worker secrets to the restored database
- Target RTO: 60 minutes for a maintainer with Turso and Cloudflare access
- Target RPO: bounded by the Turso plan PITR window and checkpoint timing

Turso documentation says PITR creates a new database from an existing database at a timestamp. The application must then be updated to use the new database URL and a new token.

## Trigger Conditions

Use this runbook when:

- Data was deleted or corrupted in production.
- A bad deploy wrote invalid production data.
- A Turso database migration or manual query needs rollback.
- Production database credentials are suspected compromised and a clean cutover is safer than reusing the current token.

## Preconditions

- Turso CLI is installed and authenticated.
- Cloudflare Wrangler is authenticated or `CLOUDFLARE_API_TOKEN` is available through the approved deployment path.
- You know the production Turso database name and organization/group.
- You have selected a UTC restore timestamp before the bad write or incident.
- The app is not being actively redeployed by another agent.

Do not paste or record raw `TURSO_AUTH_TOKEN`, `NOTEAI_AUTH_SECRET`, OAuth secrets, or programmatic API keys.

## Restore Steps

1. Freeze writes if the app is still corrupting data.

   Disable the production UI path, pause the deployment, or communicate a maintenance window. Do not delete the old database.

2. Create a restored database from the production database at a UTC timestamp.

   ```bash
   turso db create noteai-restore-YYYYMMDD-HHMM --from-db <production-db-name> --timestamp YYYY-MM-DDTHH:MM:SSZ
   ```

3. Inspect the restored database without exposing data unnecessarily.

   ```bash
   turso db show noteai-restore-YYYYMMDD-HHMM
   turso db shell noteai-restore-YYYYMMDD-HHMM "SELECT COUNT(*) FROM meetings;"
   turso db shell noteai-restore-YYYYMMDD-HHMM "SELECT COUNT(*) FROM notes;"
   turso db shell noteai-restore-YYYYMMDD-HHMM "SELECT COUNT(*) FROM todos;"
   ```

4. Create a new database token for the restored database.

   The current app performs schema initialization and writes through the server-side Turso client, so the production app token must support writes unless the app is refactored for read/write token separation.

   ```bash
   turso db tokens create noteai-restore-YYYYMMDD-HHMM --expiration 90d
   ```

5. Switch Cloudflare Worker database secrets.

   Use interactive secret input so values are not committed or printed:

   ```bash
   cd web
   npx wrangler secret put TURSO_DATABASE_URL --name noteai-web
   npx wrangler secret put TURSO_AUTH_TOKEN --name noteai-web
   ```

6. Smoke check production.

   ```bash
   curl --fail --silent --show-error https://noteai-web.noteai-jp.workers.dev/api/health
   curl --silent --output /dev/null --write-out '%{http_code}\n' https://noteai-web.noteai-jp.workers.dev/api/data/notes
   ```

   Expected results:

   - `/api/health` returns `ok: true`.
   - Unauthenticated `/api/data/notes` returns `401`.

7. Validate the app with authenticated browser access.

   Check recent meetings, notes, todos, settings preflight, and any known incident-specific records. Avoid exporting sensitive transcript or API key data into Linear.

8. Record the restore in Linear.

   Include:

   - Restore timestamp.
   - Restored database name.
   - Count-only validation results.
   - Cloudflare secret names updated, not values.
   - Production smoke results.
   - Decision on whether and when to delete the old database.

9. Keep the old database temporarily.

   Delete it only after validation and retention review:

   ```bash
   turso db destroy <old-production-db-name>
   ```

## Non-Production Restore Drill Simulation

First simulation date: 2026-05-03

Turso CLI was not authenticated in the local environment (`turso auth whoami` returned "You are not logged in"), so this first drill simulated the app-level restore cutover with non-production local SQLite data and validated the no-secret command path. It did not touch production Turso data.

Simulation commands:

```bash
sqlite3 /tmp/noteai-restore-drill-source.sqlite "CREATE TABLE notes(id TEXT PRIMARY KEY, title TEXT NOT NULL); INSERT INTO notes VALUES('drill-1','Restore Drill');"
cp /tmp/noteai-restore-drill-source.sqlite /tmp/noteai-restore-drill-restored.sqlite
sqlite3 /tmp/noteai-restore-drill-restored.sqlite "SELECT COUNT(*) FROM notes;"
```

Expected result:

```text
1
```

What this proves:

- A restored database cutover has a simple validation target: count-only checks first, then app smoke.
- No production secret values are needed in the runbook.
- The remaining real Turso PITR drill requires Turso authentication and a non-production Turso database.

## Source References

- Turso point-in-time recovery creates a new database, requires updating the app connection string, and requires a new token for the restored database: https://docs.turso.tech/features/point-in-time-recovery
- Turso database tokens can be database-scoped, read-only, and expiring: https://docs.turso.tech/cli/db/tokens/create
- Turso branching creates separate database instances for development and testing: https://docs.turso.tech/features/branching
