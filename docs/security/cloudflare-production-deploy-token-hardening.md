# Cloudflare Production Deploy Token Hardening

Date: 2026-05-04

Related Linear issues: JPB-76, JPB-22

## Decision

GitHub production deployments must be restricted to the `production` environment and the `main` branch. The Cloudflare deploy credential should live as a GitHub `production` environment secret named `CLOUDFLARE_API_TOKEN`.

Repository-scope storage for the current `CLOUDFLARE_API_TOKEN` is intentionally accepted for the current token lifecycle because GitHub does not reveal existing secret values for copying and local Cloudflare auth is invalid. This exception is bounded by the GitHub production environment branch policy added in this slice, the deploy workflow's `main` branch guard, read-only default Actions permissions, and the absence of deploy-on-PR behavior.

At the next Cloudflare token rotation, re-enter or recreate the token as a GitHub `production` environment secret and remove the repository-scoped secret.

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

## Accepted Exception Evidence

GitHub metadata after the environment hardening still showed:

- repository secret `CLOUDFLARE_API_TOKEN` exists;
- production environment secret inventory is empty.

Cloudflare CLI access was not available in this session:

```text
npx wrangler whoami
A request to the Cloudflare API (/accounts) failed.
Invalid access token [code: 9109]
```

Because the current Cloudflare token value is not readable from GitHub and the local Wrangler OAuth token is invalid, the secret cannot be moved into the environment by Codex without a fresh token value or Cloudflare re-authentication. The remaining move is a rotation task, not an unbounded hidden gap.

## Next Rotation Step

After creating or retrieving the least-privilege Cloudflare token, set it as a production environment secret:

```bash
gh secret set CLOUDFLARE_API_TOKEN --env production --repo jpbueno/noteai
```

Then delete the repository-scope secret after confirming the next production deploy succeeds:

```bash
gh secret delete CLOUDFLARE_API_TOKEN --repo jpbueno/noteai
```

## Minimum Cloudflare Token Posture

Use a scoped token for the Cloudflare account that owns `noteai-web`, not a global API key. The token should be limited to the Cloudflare account used for NoteAI deployment and to Workers deployment permissions needed by Wrangler.

Recommended starting point:

- Cloudflare template: Edit Cloudflare Workers
- Resource scope: only the account that owns `noteai-web`
- Avoid all-zone/all-account access unless Wrangler deploy fails and the extra permission is documented
- Prefer a token with an expiration date and rotate it with the same operational discipline as Turso

## Verification

After the environment secret is set and the repository secret is deleted:

```bash
gh api repos/jpbueno/noteai/actions/secrets --jq '.secrets[]?.name'
gh api repos/jpbueno/noteai/environments/production/secrets --jq '.secrets[]?.name'
gh workflow run web-deploy-cloudflare.yml --ref main
gh run watch --exit-status
curl --fail --silent --show-error https://noteai-web.noteai-jp.workers.dev/api/health
```

Expected:

- `CLOUDFLARE_API_TOKEN` is absent from repository secrets.
- `CLOUDFLARE_API_TOKEN` is present in production environment secrets.
- The production deploy succeeds from `main`.
- The health endpoint returns `ok: true`.

## Source References

- GitHub environment secrets are only available to jobs that reference the environment, and protection rules must pass before access: https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments
- GitHub deployment environments can use protection rules and branch policies: https://docs.github.com/en/rest/deployments/environments
- GitHub deployment branch policies restrict which branch patterns may deploy to an environment: https://docs.github.com/en/rest/deployments/branch-policies
- Cloudflare recommends using CI/CD secrets for `CLOUDFLARE_API_TOKEN` and scoping the token to only the deployment account: https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/
