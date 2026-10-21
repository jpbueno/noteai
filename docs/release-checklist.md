# NoteAI Release Checklist

Use this checklist before shipping macOS or repository tooling changes.

## Required Verification

- Run `swift test` for native changes, or the appropriate Xcode build/test.
- Run `node --test scripts/ci-coverage-parity.test.mjs scripts/repository-hygiene.test.mjs scripts/secret-scanning-workflow.test.mjs` for repository CI and documentation changes.
- Confirm applicable pull-request checks pass before merge and post-merge checks pass on `main`.
- For native distribution changes, verify the app's affected user flow.
- Keep provider credentials and Google OAuth tokens in macOS Keychain.
- Confirm no user data, secrets, or local build artifacts are included.

## Retired Web Product

The web version was permanently retired in JPB-191. NoteAI is a macOS application; there is no supported web client, web API, web deployment, or Turso migration workflow. Reintroducing a web product requires a new explicit product decision and security review.

The retirement does not change the native application, its permissions, local database, or packaged helper. No web deployment or database migration is part of a macOS release.

## Release Notes Template

```markdown
## Summary

- 

## User-Facing Changes

- 

## Verification

- 

## Rollout Notes

- 
```
