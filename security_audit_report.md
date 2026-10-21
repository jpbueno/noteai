# Security Audit Report

## Executive Summary

This document retains the native findings from the original NoteAI audit. It is a historical audit record, not a new verification of the current macOS build. The web client and all supported web runtime/migration tooling were permanently retired in JPB-191; the prior web findings no longer describe an active repository application.

Native code and user data were not changed by the retirement. The unresolved native data-at-rest decision remains explicit below.

## Scope and Evidence

- Retained native audit scope: `NoteAI/`, `Package.swift`, `Package.resolved`, `README.md`, and `SECURITY.md`.
- The original remediation run reported passing `swift test`; those historical results are preserved in the findings below and were not rerun as part of this document edit.
- JPB-191 scope review confirmed the native app uses GRDB and Keychain independently of the retired web client. `NoteAI/LocalHelper`, its native integration/tests, project files, and the AI coach fixture in `SharedTests/` remain native assets.
- Prior web findings SEC-001/002/003/004/005/008/010/011/012 and web operations records remain available in Git history. Their operational instructions are retired with the web product.
- Removing repository web files does not establish that external credentials were revoked or hosted data was erased. External retirement evidence must be recorded separately in Linear.

## Critical Findings

No critical finding was confirmed in the original audit.

## High Findings

No native high-severity finding was confirmed in the original audit.

## Medium Findings

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

### SEC-009: Keychain items do not specify accessibility or access-control attributes

- Severity: Low
- Status: Fixed
- Evidence: `NoteAI/Auth/KeychainHelper.swift:20-25` stores generic password items with class/service/account/value only.
- Impact: Keychain defaults may be broader than desired for OAuth refresh tokens and provider API keys.
- Details: The app does use Keychain rather than UserDefaults for secrets, which is good. The gap is hardening the access policy.
- Recommendation: Completed. New Keychain saves set `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Remediation risk: Low to Medium. Changing accessibility may affect background access or migration of existing items.
- Verification: `swift test` passed. Existing Keychain entries will receive the new attribute when re-saved or rotated.

## Not Assessed / Missing Evidence

- Native macOS distribution posture: signing, notarization, hardened runtime, sandbox entitlements, update channel, and release artifact handling were not assessed by the original audit.
- Current runtime state, external credential revocation, and hosted-data retention are not verified by this document update.
- The retained finding line references describe the original audit snapshot; consult the current source before implementing a remediation.

## Prioritized Remediation Plan

1. Needs decision: define the macOS local data-at-rest policy before attempting encryption or a file-protection migration.
2. Preserve the historical OAuth state-validation and Keychain-accessibility fixes during future native changes.
3. Review signing, notarization, and release handling when a native distribution change is requested.
