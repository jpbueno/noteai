# CI and Security Scanning Follow-ups

This document tracks CI and security automation follow-ups from `JPB-23`, `JPB-32`, `JPB-33`, and later release validation work.

## Current MVP

- `.github/workflows/web-ci.yml` runs on web changes, pull requests, pushes to `main`, and manual dispatch.
- The web job installs with `npm ci`, runs ESLint, typechecks with TypeScript, executes every checked-in `web/*.test.mjs` regression test, audits production dependencies for high-or-higher findings, and builds the Next.js app.
- `.github/workflows/macos-ci.yml` builds and tests the Xcode project on macOS runners when Swift/Xcode files change.
- `.github/workflows/ci-coverage.yml` is the JPB-32 staleness/cleanup check. It runs `scripts/ci-coverage-parity.test.mjs` on workflow, CI documentation, web regression test, and macOS test changes so the web and Swift/macOS verification matrix does not drift silently.
- `.github/workflows/secret-scan.yml` runs Gitleaks on pull requests, pushes to `main`, weekly scheduled scans, and manual dispatch.
- `.github/workflows/web-deploy-cloudflare.yml` builds the OpenNext Cloudflare bundle and deploys the production Worker after relevant `main` pushes.

## Follow-ups

1. Enable branch protection in GitHub.
   - Require the web CI workflow before merge.
   - Require the macOS CI workflow for Swift/Xcode changes.
   - Require `CI Coverage Staleness / Coverage parity cleanup check` once the first staleness run is stable.
   - Add `Secret Scan / Gitleaks git history scan` once the first scheduled scan is stable and the baseline is reviewed.
   - Keep release validation tied to CI results instead of only local command output.

2. Add a manually triggered macOS release artifact workflow if signing and notarization credentials become available.

3. Promote the Cloudflare health smoke check into a required post-deploy check once the production auth and health endpoint policy is stable.
