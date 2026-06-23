<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Required Linear Workflow

Linear is the source of truth and second brain for NoteAI work.

Every Codex agent working in `web/` must keep Linear in sync for meaningful work. This includes features, bugs, functionality tests, security findings/remediation, architecture improvements, refactors, documentation, deployment/release work, product decisions, and follow-up tasks.

Before or during work:
- Use the `Jpbueno` Linear team.
- Use the `NoteAI Product Roadmap` project by default unless a more specific NoteAI project exists.
- Find the relevant existing issue, or create one before implementation/test work continues.
- Move active implementation or test work to `In Progress` or `In Review`.

End-to-end Linear item handling:
- This is a general rule for every Linear item the user asks Codex to tackle; it is not limited to `JPB-24`, functionality test sessions, or any specific project-process issue.
- When the user asks Codex to tackle any Linear item, treat the request as permission to complete the item end-to-end unless the user explicitly limits scope or asks for planning only.
- Do not leave a completable item parked in `In Progress` waiting for the user to say "finish the remaining tasks/tests." Continue through implementation, relevant verification/tests, documentation updates, and Linear bookkeeping in the same session when feasible.
- If the work is completed and verification is satisfactory, move the Linear issue to `Done` without requiring an additional user prompt.
- If the item cannot be completed, keep it in the appropriate active state, explain the blocker, record completed work and verification results in Linear, and create or link follow-up issues for any deferred work.

Default main/deployment workflow:
- `main` is the source of truth for completed NoteAI web work. Completed and tested work should not remain only on a Codex, feature, or temporary branch.
- Before marking a Linear issue `Done`, verify the relevant web changes are committed, pushed to `main`, and visible on the remote.
- Run `npm run lint`, `npx tsc --noEmit --pretty false`, `node --test *.test.mjs`, and `npm run build` for web changes unless a narrower command is explicitly justified in Linear.
- Push completed work to `main` unless the user explicitly asks for a PR-only flow. If branch protection blocks direct push, open the PR, merge it, and then verify `main`.
- After `main` updates, confirm GitHub Actions ran for the push. The public Cloudflare web deployment has been decommissioned; do not recreate it without an explicit security review and new Linear issue.
- If tests, push, or CI fails, keep the Linear issue active, document the failure clearly in Linear and chat, and create or link follow-up issues instead of silently leaving the work on a branch.
- Delete obsolete local and remote branches only after confirming their useful commits are included in `main` by ancestry or patch equivalence.

After work:
- Update the relevant Linear issue with what changed, affected files/modules, verification commands/results, and remaining follow-ups.
- Create linked follow-up issues for discovered bugs, deferred risks, or new improvements.
- If the work spans several issues, add or update a worklog issue summarizing the session.

Standing Linear anchor:
- `JPB-24` records this operating rule.
- `JPB-26` tracks the current functionality test session if no more specific test issue exists.

## Required Architecture & Security Primitives

All NoteAI web improvements and new features managed in Linear must explicitly follow the relevant architecture and security primitives before implementation is treated as complete.

- For improvements, new features, refactors, architecture work, and codebase-shaping follow-ups, use the `improve-codebase-architecture` skill. Frame architecture decisions with its vocabulary: Module, Interface, Implementation, Depth, Seam, Adapter, Leverage, and Locality.
- For security findings/remediation, hardening, infrastructure, authentication, authorization, secrets, deployment, dependency, and operational security work, use the `security-auditor` skill.
- For JavaScript/TypeScript secure-by-default coding, explicit security best-practices guidance, or security reports, use the `security-best-practices` skill alongside `security-auditor`.
- Linear issues for improvements and new features must capture the architecture/security checks performed, verification commands/results, affected modules/files, accepted risks or deferred decisions, and linked follow-up issues for new risks or improvements.

## NoteAI Web Architecture

- The web app is local/CI-only. Do not add Cloudflare Workers, Pages, Vercel, or other public deployment automation without explicit approval and security review.
- Keep React components focused on view state and event wiring.
- Put reusable behavior in `src/lib/`:
  - `library.ts` for entity drafts, search, source selection, and selection clearing
  - `recording-workflow.ts` for stop-recording completion and fallback behavior
  - `ai-tasks.ts` for prompt construction and JSON parsing
  - `assistant-actions.ts` for AI chat action parsing and execution
  - `repositories.ts` for typed persistence adapters
- Validate with `npm run lint`, `npx tsc --noEmit --pretty false`, and `npm run build`.

<!-- VERCEL BEST PRACTICES START -->
## Best practices for developing on Vercel

These defaults are optimized for AI coding agents (and humans) working on apps that deploy to Vercel.

- Treat Vercel Functions as stateless + ephemeral (no durable RAM/FS, no background daemons), use Blob or marketplace integrations for preserving state
- Edge Functions (standalone) are deprecated; prefer Vercel Functions
- Don't start new projects on Vercel KV/Postgres (both discontinued); use Marketplace Redis/Postgres instead
- Store secrets in Vercel Env Variables; not in git or `NEXT_PUBLIC_*`
- Provision Marketplace native integrations with `vercel integration add` (CI/agent-friendly)
- Sync env + project settings with `vercel env pull` / `vercel pull` when you need local/offline parity
- Use `waitUntil` for post-response work; avoid the deprecated Function `context` parameter
- Set Function regions near your primary data source; avoid cross-region DB/service roundtrips
- Tune Fluid Compute knobs (e.g., `maxDuration`, memory/CPU) for long I/O-heavy calls (LLMs, APIs)
- Use Runtime Cache for fast **regional** caching + tag invalidation (don't treat it as global KV)
- Use Cron Jobs for schedules; cron runs in UTC and triggers your production URL via HTTP GET
- Use Vercel Blob for uploads/media; Use Edge Config for small, globally-read config
- If Enable Deployment Protection is enabled, use a bypass secret to directly access them
- Add OpenTelemetry via `@vercel/otel` on Node; don't expect OTEL support on the Edge runtime
- Enable Web Analytics + Speed Insights early
- Use AI Gateway for model routing, set AI_GATEWAY_API_KEY, using a model string (e.g. 'anthropic/claude-sonnet-4.6'), Gateway is already default in AI SDK
  needed. Always curl https://ai-gateway.vercel.sh/v1/models first; never trust model IDs from memory
- For durable agent loops or untrusted code: use Workflow (pause/resume/state) + Sandbox; use Vercel MCP for secure infra access
<!-- VERCEL BEST PRACTICES END -->
