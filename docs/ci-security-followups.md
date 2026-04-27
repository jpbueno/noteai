# CI and Security Scanning Follow-ups

This document tracks the work intentionally left out of the first `JPB-23` CI slice.

## Current MVP

- `.github/workflows/web-ci.yml` runs on web changes, pull requests, pushes to `main`, and manual dispatch.
- The web job installs with `npm ci`, runs ESLint, typechecks with TypeScript, executes `security-regression.test.mjs`, audits production dependencies for high-or-higher findings, and builds the Next.js app.
- `.github/workflows/macos-ci.yml` builds and tests the Xcode project on macOS runners when Swift/Xcode files change.
- `.github/workflows/web-deploy-cloudflare.yml` builds the OpenNext Cloudflare bundle and deploys the production Worker after relevant `main` pushes.

## Follow-ups

1. Add secret and history scanning.
   - Add a tool such as Gitleaks or TruffleHog for pull requests and scheduled scans.
   - Generate and commit a reviewed baseline if existing historical findings need to be grandfathered.
   - Document how to rotate credentials if the scanner finds a real secret.

2. Enable branch protection in GitHub.
   - Require the web CI workflow before merge.
   - Require the macOS CI workflow for Swift/Xcode changes.
   - Add secret scanning checks once that follow-up lands.
   - Keep release validation tied to CI results instead of only local command output.

3. Add a manually triggered macOS release artifact workflow if signing and notarization credentials become available.
