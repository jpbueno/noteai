# Cloudflare Access, WAF, and Rate Limit Policy

Date: 2026-05-04

Related Linear issues: JPB-77, JPB-22

## Decision

Keep the current NoteAI production Worker public on `workers.dev` and rely on application authentication for user data routes for now. Do not add a Cloudflare Access application in front of the full production app yet.

This is an accepted risk for the current deployment because:

- The app has its own Google/session gate and unauthenticated data APIs return `401`.
- The health endpoint is intentionally public for deployment smoke checks.
- A whole-app Access gate would add a second identity layer in front of Google sign-in and would need a careful OAuth callback/API automation design.
- The production URL is currently `https://noteai-web.noteai-jp.workers.dev`; zone-level WAF and rate-limiting rules should be configured when NoteAI moves to a custom Cloudflare zone hostname.

## Current Required Controls

These controls must remain true while production stays public:

- Browser/user access is enforced by the application auth layer.
- Programmatic API access uses `NOTEAI_API_KEY_HASHES`, not raw API keys.
- `/api/health` remains public and returns only service health metadata.
- Unauthenticated data routes return `401`.
- Cost-bearing API routes keep application-level request size and token limits.
- Response security headers remain present on the deployed Worker.
- Worker observability stays enabled in `web/wrangler.jsonc`.

## Future Cloudflare Controls

When NoteAI moves from `workers.dev` to a custom Cloudflare zone hostname, add Cloudflare controls in this order:

1. Create a custom hostname/route for the production Worker.
2. Add WAF custom rules in log or managed-challenge mode for obviously hostile traffic, scanner user agents, and unexpected countries only if the traffic pattern justifies it.
3. Add rate-limiting rules for cost-bearing and auth-sensitive endpoints after checking normal request-rate baselines:
   - `/api/auth/*`
   - `/api/chat`
   - `/api/transcribe`
   - `/api/tts`
   - `/api/data/*`
4. Keep `/api/health` low-noise and public, but rate-limit abusive volume if it becomes a monitoring target.
5. Consider Cloudflare Access only for an admin-only hostname or a future maintainer-only preview environment, not as a blanket control in front of the current production Google-auth flow.

## Log and Alert Posture

Current posture:

- Worker observability is enabled with `head_sampling_rate: 0.1`.
- The production deploy workflow smoke-checks `/api/health` after deploy.
- No Cloudflare dashboard alert, Logpush sink, WAF event alert, or rate-limit alert is currently configured from repo evidence.

Accepted risk:

- For a personal/single-maintainer app, sampled Worker observability plus application auth is acceptable until either a custom domain or repeated suspicious traffic appears.

Trigger to revisit:

- Add a custom production hostname.
- Enable preview Worker deployments.
- See repeated 401/403 spikes, provider spend anomalies, or route-level abuse.
- Add more users beyond the current allowed-user model.

## Verification Commands

```bash
curl --fail --silent --show-error https://noteai-web.noteai-jp.workers.dev/api/health
curl --silent --output /dev/null --write-out '%{http_code}\n' https://noteai-web.noteai-jp.workers.dev/api/data/notes
```

Expected:

- `/api/health` returns `ok: true`.
- `/api/data/notes` returns `401` without auth.

## Source References

- Cloudflare Access self-hosted applications can protect public hostnames and Workers, but require policy and token validation design: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/
- Cloudflare Access policy rules are deny-by-default unless an Allow policy matches: https://developers.cloudflare.com/cloudflare-one/access-controls/policies/
- Cloudflare WAF custom rules are zone-level security rules for filtering incoming traffic: https://developers.cloudflare.com/waf/custom-rules/
- Cloudflare rate-limiting rules should be scoped to expressions and tuned to observed request rates: https://developers.cloudflare.com/waf/rate-limiting-rules/
