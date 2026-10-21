# Focused NoteAI macOS Implementation Plan

> **For agentic workers:** Use the current session and parallel agents with disjoint file ownership. Track completion with checkboxes.

**Goal:** Retain meeting transcription and AI Solutions Architect and remove the unused macOS workflows.

**Architecture:** Preserve capture and coach Interfaces/Implementations. Delete unused feature code and narrow meeting persistence without destructive migration.

**Tech Stack:** SwiftUI, GRDB, WhisperKit, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-21-focused-macos-design.md`

## Global constraints

- macOS only; leave web and its retired deployment unchanged.
- Preserve primary bundle identity, existing meeting JSON, Keychain service, and legacy data.
- Retain session-safe AI SA and recording behavior from main.
- Use JPB-26 and deliver through PR/main with checks.

## Review focus

- Existing database opens without modifying retired rows or tables.
- Search and navigation never reference deleted entities.
- Meeting recap/export/speaker context survives retirement of note/task helpers.
- Recording/AI SA controls and session cancellation remain functional.
- Generated project and test references do not include removed files.

## Tasks

- [x] Narrow MeetingManager, persistence/repository/library and summary modules; remove retired models/generators; verify persistence and legacy-data preservation.
- [x] Replace multi-feature shell/dashboard with meeting navigation; remove retired feature views; update affected architecture tests.
- [x] Remove retired settings, imports and work-activity integrations; retain meeting-specific export/edit/read-aloud.
- [x] Remove general assistant app wiring, update version/docs, regenerate Xcode project, run focused and full macOS checks.
- [ ] Review changes, commit JPB-26, push/open PR, verify CI, merge main, verify post-merge checks, update Linear.

## Verification evidence

- `xcodegen generate` succeeded.
- Primary macOS `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` succeeded.
- Full primary macOS `xcodebuild ... CODE_SIGNING_ALLOWED=NO test` succeeded; xcresult summary: 198 passed, zero failures/skips/runtime warnings.
- `node --test scripts/ci-coverage-parity.test.mjs scripts/repository-hygiene.test.mjs` passed all six checks.
- Independent source review found one missing primary-app import entry point; the fix adds an ungated action in meeting history, covered by the passing regression suite.
- `git diff --check` passed; no web source, workflow, or dependency-lock changes.
