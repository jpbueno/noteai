# Security Audit Report

## Executive Summary

This audit reviewed NoteAI as a combined Swift/macOS app plus Next.js 16 web app deployed to Cloudflare Workers with Turso/libSQL persistence. The strongest controls observed are: `.env*` files are ignored, web database access is server-side, dynamic SQL table/column names are whitelisted, macOS provider keys are migrated to Keychain, and the web app has baseline response headers.

No critical finding was confirmed from repository evidence. The highest risks are: a vulnerable Next.js dependency reported by `npm audit`, decrypted LLM provider API keys being returned to browser code despite documentation saying they are never browser-exposed, and fail-open web authentication when required auth configuration is missing.

## Scope and Evidence

- Reviewed: `NoteAI/`, `web/src/`, `web/wrangler.jsonc`, `web/package.json`, `web/package-lock.json`, `README.md`, `SECURITY.md`, `.gitignore`, `Package.swift`, `Package.resolved`.
- Security skill references used: Cloudflare, Turso, scope map, control checklist, reporting, JavaScript/TypeScript Next.js server security, React/frontend security.
- Tools run:
  - `rg` static searches for secrets, auth, Turso, Cloudflare, network endpoints, browser sinks, and local storage.
  - `git ls-files web/.env*`: no tracked env files found.
  - Redacted local env inventory: `web/.env.local`, `web/.env.prod`, and `web/.env.vercel` exist locally with set secret-like values, but are ignored by `.gitignore`.
  - `npm audit --audit-level=low`: failed in sandbox due DNS, then succeeded with approved network access; found 1 high and 5 moderate advisories.
  - `npm run lint`: passed.
  - `swift test`: passed, 5 XCTest tests.
- Remediation verification run after fixes:
  - `node --test web/security-regression.test.mjs`: passed, 5 regression tests.
  - `npm run lint`: passed.
  - `npx tsc --noEmit --pretty false`: passed.
  - `swift test`: passed, 6 XCTest tests.
  - `npm audit --audit-level=low`: passed, 0 vulnerabilities.
  - `npm run build`: passed.
  - `npm run build:cf`: passed.
- Not reviewed in the original audit: production Cloudflare account settings, Cloudflare API token scopes, Turso token scopes/read-only status, deployed runtime headers, DNS/WAF/rate-limit settings, git history secret scanning, GitHub branch protections, and CI/CD because no workflow directory was present. Later JPB-22/76/77/78/79/80/81 follow-ups added CI/CD, deploy, environment, secret, and operations evidence in `docs/security/`.

## Critical Findings

No critical findings confirmed.

## High Findings

### SEC-001: Vulnerable Next.js dependency reported by npm audit

- Severity: High
- Status: Fixed
- Original evidence: `web/package.json:27` pinned `next` to `16.2.1`.
- Original evidence: `npm audit --audit-level=low` reported `next >=9.3.4-canary.0` as High severity: "Next.js has a Denial of Service with Server Components", with fix via `next@16.2.4`.
- Fixed in: `web/package.json`, `web/package-lock.json`.
- Impact: A public Cloudflare-hosted Next.js app may be susceptible to a server component denial-of-service path until Next.js is upgraded.
- Details: This is directly relevant because `README.md:112` documents a production Worker URL and `web/package.json:9-11` deploys the app through OpenNext Cloudflare.
- Recommendation: Completed. Upgraded Next.js/OpenNext, removed the unused `uuid` dependency, and added a PostCSS override to resolve transitive audit findings.
- Remediation risk: Medium. Next.js patch upgrades can alter framework/runtime behavior; verify OpenNext compatibility.
- Verification: `npm audit --audit-level=low`, `npm run build`, and `npm run build:cf` passed.

### SEC-002: Decrypted provider API keys are returned to browser code

- Severity: High
- Status: Fixed
- Original evidence: `web/src/lib/server-db.ts:287-297` decrypted encrypted setting values for `ENCRYPTED_KEYS`.
- Original evidence: `web/src/app/api/settings/route.ts:4-9` returned `{ value }` for any valid setting key.
- Original evidence: `web/src/components/Settings.tsx:111-115` loaded every `api_key_*` setting into React state, and `web/src/components/Settings.tsx:196-216` rendered the key into a password/text input.
- Fixed in: `web/src/app/api/settings/route.ts`, `web/src/components/Settings.tsx`, `web/src/lib/db.ts`, `web/src/lib/server-db.ts`.
- Evidence: `README.md:151-153` says web API keys are "stored server-side as Cloudflare Worker secrets, never exposed to the browser"; the implementation contradicts this.
- Impact: Any authenticated browser session, browser extension, XSS bug, compromised device, or shoulder-surfed "show key" state can recover provider API keys.
- Details: The keys are encrypted at rest in Turso, but the settings route is a read API that decrypts and returns them. This makes the browser a secret handling surface.
- Recommendation: Completed. Provider API keys are now write-only from browser settings APIs; the UI receives configured status and can replace keys without reading plaintext.
- Remediation risk: Medium. The settings UI will need to change because it currently expects to repopulate the input with the real key.
- Verification: `node --test web/security-regression.test.mjs`, `npm run lint`, `npx tsc --noEmit --pretty false`, and both web builds passed.

### SEC-003: Web authentication fails open when required auth configuration is missing

- Severity: High
- Status: Fixed
- Original evidence: `web/src/middleware.ts:35-39` read `NOTEAI_AUTH_SECRET` and `GOOGLE_CLIENT_ID`, then skipped middleware auth entirely if either was missing.
- Original evidence: `web/src/app/api/auth/route.ts:99-105` returned `{ authenticated: true, required: false }` when either value was missing.
- Fixed in: `web/src/middleware.ts`, `web/src/app/api/auth/route.ts`, `web/src/app/page.tsx`, `web/src/lib/security.ts`.
- Evidence: `README.md:120-126` documents these values as Cloudflare secrets that must be set for deployment.
- Impact: A production or preview Worker deployed without either secret becomes unauthenticated, exposing API routes and stored data.
- Details: Fail-open can be convenient for local development, but public edge deployments should require an explicit development bypass rather than silently disabling auth.
- Recommendation: Completed. Missing browser auth config now blocks APIs with 503 unless `NOTEAI_DISABLE_AUTH=true` is explicitly set outside production.
- Remediation risk: Medium. Existing local/dev workflows may rely on the current no-auth behavior.
- Verification: `node --test web/security-regression.test.mjs`, `npm run build`, and `npm run build:cf` passed.

## Medium Findings

### SEC-004: Programmatic API key is deterministic, long-lived, and coupled to the session/encryption secret

- Severity: Medium
- Status: Mitigated
- Evidence: `web/src/middleware.ts:45-54` accepts `HMAC-SHA256("noteai-api-key", NOTEAI_AUTH_SECRET)` as a bearer token.
- Evidence: `web/src/app/api/auth/apikey/route.ts:24-39` returns that same derived token to any valid browser session.
- Evidence: `README.md:131-133` documents the token derivation and retrieval path.
- Impact: Once disclosed, the bearer token grants full API access until `NOTEAI_AUTH_SECRET` is rotated, which also affects sessions and web settings encryption.
- Details: There is no token ID, expiration, revocation list, scope, last-used audit trail, or per-client separation.
- Recommendation: Partially completed. Programmatic API auth now uses explicit SHA-256 hashes in `NOTEAI_API_KEY_HASHES` and no longer derives bearer credentials from `NOTEAI_AUTH_SECRET`. Full per-token revocation/scope metadata remains future work.
- Remediation risk: Medium. Existing agents/scripts using the current derived token need migration.
- Verification: `node --test web/security-regression.test.mjs`, `npm run lint`, `npx tsc --noEmit --pretty false`, and builds passed.

### SEC-005: Cost-bearing AI, transcription, and TTS endpoints lack visible abuse limits

- Severity: Medium
- Status: Mitigated
- Evidence: `web/src/app/api/chat/route.ts:13-14` accepts caller-controlled `messages`, `temperature`, and `maxTokens`.
- Evidence: `web/src/app/api/transcribe/route.ts:20-23` accepts uploaded audio and prompt with no visible size/duration bound before forwarding upstream.
- Evidence: `web/src/app/api/tts/route.ts:17-18` accepts caller-provided text/voice and only later slices text at `web/src/app/api/tts/route.ts:51`.
- Evidence: `web/wrangler.jsonc:1-10` shows no local Worker-level rate limit or environment binding; Cloudflare account-level controls were not available.
- Impact: A stolen session/API token or over-broad allowed user can drive provider spend and resource exhaustion.
- Details: Authentication exists, but authenticated abuse and credential theft are realistic enough for cost-bearing endpoints.
- Recommendation: Partially completed. Added local message count/content limits, max token caps, audio upload size limit, transcription prompt cap, and TTS text length enforcement. JPB-77 documents that Cloudflare WAF/rate-limit rules should be added when NoteAI moves to a custom Cloudflare zone hostname or when traffic evidence justifies them.
- Remediation risk: Low to Medium. Caps must be tuned to expected meeting lengths and T5T workflows.
- Verification: `node --test web/security-regression.test.mjs`, `npm run lint`, `npx tsc --noEmit --pretty false`, and builds passed.

### SEC-006: macOS local meeting database is plaintext at rest

- Severity: Medium
- Status: Needs Decision
- Evidence: `NoteAI/Storage/MeetingStore.swift:8-16` stores `meetings.sqlite` in user Application Support using a normal GRDB `DatabaseQueue`.
- Evidence: `NoteAI/Storage/MeetingStore.swift:23-37`, `NoteAI/Storage/MeetingStore.swift:130-145`, and `NoteAI/Storage/MeetingStore.swift:196-210` persist full JSON payloads for meetings, reports, and notes.
- Impact: Meeting transcripts, notes, and tasks are readable by local processes or backups with filesystem access to the user profile.
- Details: This may be acceptable for a local-first macOS app relying on FileVault and OS account isolation, but meeting transcripts are sensitive content.
- Recommendation: Decide and document the local data-at-rest model. For stronger protection, evaluate SQLCipher/GRDB encryption or file protection controls, plus backup/export guidance.
- Remediation risk: Medium to High. Encrypting an existing SQLite database requires migration and recovery planning.
- Verification: Not changed in this pass; encryption needs a migration design and recovery plan before implementation.

### SEC-007: Desktop OAuth loopback flow lacks an explicit state check

- Severity: Medium
- Status: Fixed
- Evidence: `NoteAI/Auth/GoogleAuthManager.swift:60-68` builds the Google OAuth URL with PKCE fields but no `state` parameter.
- Evidence: `NoteAI/Auth/GoogleAuthManager.swift:239-248` accepts the first `code` query parameter from the loopback request without validating a state value.
- Impact: A local process or malicious page that can reach the random loopback port during login may inject an OAuth response, causing login confusion or binding the app to an unintended account.
- Details: PKCE protects code exchange, and the loopback port is random and bound to `127.0.0.1`, so this is constrained, but state is still the standard CSRF/mix-up guard.
- Recommendation: Completed. The desktop OAuth flow now generates state, sends it to Google, and validates it in the loopback callback before exchanging the code.
- Remediation risk: Low. The callback parser and auth URL builder need a small coordinated change.
- Verification: `swift test` passed with `testOAuthCallbackRequiresExpectedState`.

## Low Findings

### SEC-008: HMAC comparisons are not constant-time

- Severity: Low
- Status: Fixed
- Evidence: `web/src/middleware.ts:21-22` compares session signatures using `expected !== sig`.
- Evidence: `web/src/middleware.ts:53-54` compares bearer API tokens using `token === expected`.
- Evidence: `web/src/app/api/auth/route.ts:19-21` compares session signatures using `expected === signature`.
- Impact: Timing leakage is theoretically possible for signature/token checks, although network jitter makes practical exploitation difficult at the edge.
- Recommendation: Completed. Web session and programmatic API token comparisons now use a constant-time string comparison helper.
- Remediation risk: Low.
- Verification: `node --test web/security-regression.test.mjs`, `npm run lint`, `npx tsc --noEmit --pretty false`, and builds passed.

### SEC-009: Keychain items do not specify accessibility or access-control attributes

- Severity: Low
- Status: Fixed
- Evidence: `NoteAI/Auth/KeychainHelper.swift:20-25` stores generic password items with class/service/account/value only.
- Impact: Keychain defaults may be broader than desired for OAuth refresh tokens and provider API keys.
- Details: The app does use Keychain rather than UserDefaults for secrets, which is good. The gap is hardening the access policy.
- Recommendation: Completed. New Keychain saves set `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Remediation risk: Low to Medium. Changing accessibility may affect background access or migration of existing items.
- Verification: `swift test` passed. Existing Keychain entries will receive the new attribute when re-saved or rotated.

### SEC-010: CSP is not visible in app or Worker configuration

- Severity: Low
- Status: Mitigated
- Evidence: `web/next.config.ts:6-15` sets `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, and HSTS, but no `Content-Security-Policy`.
- Evidence: `web/src/app/layout.tsx:41` loads `https://accounts.google.com/gsi/client` as a third-party script.
- Impact: If an XSS bug is introduced later, the app lacks a visible browser-enforced script policy to reduce impact.
- Details: No confirmed dangerous HTML sink was found in `web/src`; this is defense-in-depth.
- Recommendation: Partially completed. Added a baseline CSP compatible with the current Next/OpenNext and Google Sign-In setup. A stricter nonce-based CSP remains future hardening.
- Remediation risk: Medium. CSP can break Next.js runtime scripts or Google Sign-In if rolled out too aggressively.
- Verification: `npm run build` and `npm run build:cf` passed. Runtime browser CSP verification should still be done after deploy.

## Informational

### SEC-011: Secret handling posture is mostly good in source control

- Severity: Informational
- Status: Fixed
- Evidence: `.gitignore:43-48` ignores `web/node_modules/`, build outputs, `web/.env*`, and `web/.wrangler/`.
- Evidence: `git ls-files web/.env.local web/.env.prod web/.env.vercel web/.env.example` returned no tracked env files.
- Evidence: Local redacted inventory showed `web/.env.local`, `web/.env.prod`, and `web/.env.vercel` contain set secret-like values.
- Impact: Current source control state does not show tracked env secrets, but local env files contain sensitive material that should not be copied into artifacts or support bundles.
- Recommendation: Completed for current remediation scope. `.env*` remains ignored, source searches found no tracked env secrets, and docs now use hashed programmatic API keys.
- Remediation risk: Low.
- Verification: `git status --ignored --short web/.env*` shows ignored local envs only; secret scanner reports no committed credentials.

### SEC-012: Cloudflare Worker config keeps secrets out of `vars`, and environment separation is documented

- Severity: Informational
- Status: Fixed
- Evidence: `web/wrangler.jsonc:1-10` has no `vars` block containing secrets.
- Evidence: `README.md:120-126` instructs using `wrangler secret put` for Turso/auth/Google values.
- Impact: This avoids the common Cloudflare mistake of committing secrets in Wrangler vars. Required Worker secrets are declared, and preview/prod separation is documented without committing secret values.
- Recommendation: Completed for current scope. App-level required secret checks fail closed for APIs, docs include `NOTEAI_API_KEY_HASHES`, `web/wrangler.jsonc` declares required secrets, and `docs/security/cloudflare-turso-environment-separation.md` defines the preview/production boundary.
- Remediation risk: Low.
- Verification: Deploy/preview fails clearly when required secrets are absent, and preview cannot accidentally write production Turso unless explicitly configured.

## Not Assessed / Missing Evidence

- Cloudflare account controls: JPB-76 added GitHub production environment branch policy evidence and JPB-77 documented Access/WAF/rate-limit policy. Cloudflare token scopes and dashboard-side WAF/rate-limit configuration still require valid Cloudflare admin auth.
- Turso controls: JPB-78 documented token expiration metadata and rotation posture, but direct Turso account scope/read-only/full-access evidence still requires Turso CLI auth.
- CI/CD: GitHub workflows now exist and are documented in `docs/linear-cicd.md`; main branch protection is still a separate repository-level control.
- Git history secrets: current tracked files were searched, but full history scanning with tools such as `gitleaks` was not run.
- Runtime security headers: `next.config.ts` was reviewed, but the deployed Cloudflare/OpenNext response headers were not fetched.
- Native macOS distribution posture: signing, notarization, hardened runtime, sandbox entitlements, update channel, and release artifact handling were not assessed from the available files.

## Prioritized Remediation Plan

1. Done: patch dependency advisories and validate Next/OpenNext builds.
2. Done: stop returning decrypted provider API keys to browser code.
3. Done: fail closed for missing web auth config unless an explicit non-production bypass is enabled.
4. Mitigated: replace deterministic derived programmatic API key with server-side SHA-256 API key hashes. Remaining: per-token revocation/scope metadata.
5. Mitigated: add local bounds to AI, transcription, and TTS routes. Remaining: Cloudflare/provider rate limits and spend alerts.
6. Needs decision: decide the macOS local data-at-rest policy before attempting SQLite encryption or file-protection migration.
7. Done: add OAuth `state` validation to the desktop loopback flow.
8. Done: add constant-time token/signature comparisons and stronger Keychain accessibility attributes.
9. Mitigated: add baseline CSP. Remaining: browser-test deployed Google Sign-In and consider nonce-based CSP.
10. Still external: verify Cloudflare and Turso production controls outside the repo: least-privilege tokens, required secrets, rate limits, backups, and alerting.
