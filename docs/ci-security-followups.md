# CI and Security Scanning Follow-ups

This document tracks the work intentionally left out of the first `JPB-23` CI slice.

## Current MVP

- `.github/workflows/web-ci.yml` runs on web changes, pull requests, pushes to `main`, and manual dispatch.
- The web job installs with `npm ci`, runs ESLint, executes `security-regression.test.mjs`, audits production dependencies for high-or-higher findings, and builds the Next.js app.

## Follow-ups

1. Add a Swift/macOS workflow.
   - Run XcodeGen if needed, then `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI -configuration Debug build`.
   - Add `xcodebuild -project NoteAI.xcodeproj -scheme NoteAI test` once the runner has the required macOS and dependency setup.
   - Document any required Apple/Xcode runner assumptions.

2. Add secret and history scanning.
   - Add a tool such as Gitleaks or TruffleHog for pull requests and scheduled scans.
   - Generate and commit a reviewed baseline if existing historical findings need to be grandfathered.
   - Document how to rotate credentials if the scanner finds a real secret.

3. Document branch protection expectations.
   - Require the web CI workflow before merge.
   - Add the Swift and secret scanning checks once those follow-ups land.
   - Keep release validation tied to CI results instead of only local command output.
