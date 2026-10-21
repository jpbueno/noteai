# CI and Security Scanning Follow-ups

This document tracks CI and security automation follow-ups from `JPB-23`, `JPB-32`, `JPB-33`, and later release validation work.

## Current MVP

- `.github/workflows/macos-ci.yml` builds and tests the Xcode project on macOS runners when Swift/Xcode files change.
- `.github/workflows/ci-coverage.yml` is the JPB-32 staleness/cleanup check. It runs `scripts/ci-coverage-parity.test.mjs` and `scripts/repository-hygiene.test.mjs` on workflow, CI documentation, contributor documentation, ignore-rule, and macOS test changes.
- `.github/workflows/secret-scan.yml` runs Gitleaks on pull requests, pushes to `main`, weekly scheduled scans, and manual dispatch.
- JPB-191 permanently retires the web client and its CI, deployment, and database-migration tooling. Native CI and secret scanning remain in place.

## Follow-ups

1. Keep GitHub branch protection aligned with applicable checks.
   - Require the macOS CI workflow for Swift/Xcode changes.
   - Require `CI Coverage Staleness / Coverage parity cleanup check` once the first staleness run is stable.
   - Add `Secret Scan / Gitleaks git history scan` once the first scheduled scan is stable and the baseline is reviewed.
   - Keep release validation tied to CI results instead of only local command output.

2. Add a manually triggered macOS release artifact workflow if signing and notarization credentials become available.
