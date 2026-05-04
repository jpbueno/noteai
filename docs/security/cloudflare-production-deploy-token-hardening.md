# Cloudflare Production Deploy Token Hardening

Date: 2026-05-04

Related Linear issues: JPB-76, JPB-84, JPB-22

## Decision

GitHub production deployments must be restricted to the `production` environment and the `main` branch. The Cloudflare deploy credential should live as a GitHub `production` environment secret named `CLOUDFLARE_API_TOKEN`.

Repository-scope storage for the previous `CLOUDFLARE_API_TOKEN` was intentionally accepted for the prior token lifecycle because GitHub does not reveal existing secret values for copying and local Cloudflare auth was invalid.

Status as of JPB-84 on 2026-05-04: resolved. The deploy credential now lives only as the GitHub `production` environment secret named `CLOUDFLARE_API_TOKEN`; the repository-scoped `CLOUDFLARE_API_TOKEN` was deleted after a successful production deploy from `main`.

## GitHub Changes Applied

Configured the existing GitHub `production` environment with a custom deployment branch policy:

- environment: `production`
- branch policy: enabled
- allowed deployment branch pattern: `main`
- production environment policy id observed: `53847189`
- deployment branch policy id observed: `48594943`

The deploy workflow already references the `production` environment:

```yaml
environment:
  name: production
  url: https://noteai-web.noteai-jp.workers.dev
```

The workflow also has:

- `permissions: contents: read`
- no `pull_request` trigger
- `concurrency: cloudflare-production`
- manual dispatch restricted to `refs/heads/main`
- `npx wrangler deploy --env="" --keep-vars`
- post-deploy `/api/health` smoke check

Repository Actions default workflow permissions are read-only:

```json
{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}
```

## Previous Accepted Exception Evidence

GitHub metadata after the environment hardening still showed:

- repository secret `CLOUDFLARE_API_TOKEN` exists;
- production environment secret inventory is empty.

Cloudflare CLI access was not available in this session:

```text
npx wrangler whoami
A request to the Cloudflare API (/accounts) failed.
Invalid access token [code: 9109]
```

Because the previous Cloudflare token value was not readable from GitHub and the local Wrangler OAuth token was invalid, the secret could not be moved into the environment by Codex without a fresh token value or Cloudflare re-authentication. This was tracked as JPB-84 and is now resolved.

## JPB-84 Rotation Evidence

Completed on 2026-05-04:

- Created a replacement Cloudflare User API Token named `noteai-cloudflare-production-deploy-20260504c`.
- Token expiration: 2027-05-04T18:00:00Z.
- Scope: user `Memberships Read`, account `Edit Cloudflare Workers` template permissions for the Cloudflare account that owns `noteai-web`.
- Set the token as GitHub environment secret `CLOUDFLARE_API_TOKEN` on environment `production`.
- Deleted the repository-scoped GitHub Actions secret `CLOUDFLARE_API_TOKEN`.
- Revoked two intermediate account-owned tokens created during validation:
  - the first was exposed in a local Playwright snapshot and immediately revoked;
  - the second validated locally but failed GitHub deploy because Wrangler 4.85 requested `/memberships`, which requires user `Memberships Read`.

GitHub metadata after rotation:

```bash
gh secret list --repo jpbueno/noteai
# no CLOUDFLARE_API_TOKEN

gh secret list --env production --repo jpbueno/noteai
# CLOUDFLARE_API_TOKEN present, updated 2026-05-04T18:08:22Z
```

## Minimum Cloudflare Token Posture

Use a scoped Cloudflare API token for the account that owns `noteai-web`, not a global API key. The token should be limited to the Cloudflare account used for NoteAI deployment and to Wrangler's required read/write permissions.

Recommended starting point:

- Cloudflare template: Edit Cloudflare Workers
- Additional user permission: Memberships Read, required by Wrangler deploy's `/memberships` lookup
- Resource scope: only the account that owns `noteai-web`
- Avoid all-zone/all-account access unless Wrangler deploy fails and the extra permission is documented
- Prefer a token with an expiration date and rotate it with the same operational discipline as Turso

## Verification

The JPB-84 rotation was verified with:

```bash
gh api repos/jpbueno/noteai/actions/secrets --jq '.secrets[]?.name'
gh api repos/jpbueno/noteai/environments/production/secrets --jq '.secrets[]?.name'
gh workflow run web-deploy-cloudflare.yml --ref main
gh run watch 25335165060 --repo jpbueno/noteai --exit-status
curl --fail --silent --show-error https://noteai-web.noteai-jp.workers.dev/api/health
curl --silent --output /tmp/noteai-data-notes-status.txt --write-out '%{http_code}\n' https://noteai-web.noteai-jp.workers.dev/api/data/notes
```

Results:

- `CLOUDFLARE_API_TOKEN` is absent from repository secrets.
- `CLOUDFLARE_API_TOKEN` is present in production environment secrets.
- GitHub Actions run `25335165060` succeeded from `main` at commit `624dce8dac6d45e0110ba73085db90c02164b8c1`.
- The production Cloudflare deploy and workflow health smoke check succeeded.
- Live `/api/health` returned `ok: true`.
- Live unauthenticated `/api/data/notes` returned `401`.

## Source References

- GitHub environment secrets are only available to jobs that reference the environment, and protection rules must pass before access: https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments
- GitHub deployment environments can use protection rules and branch policies: https://docs.github.com/en/rest/deployments/environments
- GitHub deployment branch policies restrict which branch patterns may deploy to an environment: https://docs.github.com/en/rest/deployments/branch-policies
- Cloudflare recommends using CI/CD secrets for `CLOUDFLARE_API_TOKEN` and scoping the token to only the deployment account: https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/
