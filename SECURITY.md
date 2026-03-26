# Security Policy

## Supported Versions

This project is currently pre-release. Security fixes are applied on the latest mainline code.

## Reporting a Vulnerability

If you discover a security issue:

1. Do not open a public issue with exploit details.
2. Share a private report with:
   - impact
   - reproduction steps
   - affected files/components
   - suggested remediation (optional)
3. Include logs/screenshots only if they do not expose secrets or personal data.

## Secure Development Practices Used

- Secrets are stored in Keychain when possible (OAuth and LLM API keys).
- No secrets should be committed to source control.
- Network calls should use HTTPS endpoints only.
- Local debug logs should avoid raw sensitive content in release builds.
- Build artifacts and local runtime outputs are ignored via `.gitignore`.

## Pre-GitHub Checklist

- Verify no credentials in source, docs, or sample files.
- Verify local artifacts are excluded (`.build/`, `.xcode-build/`, logs, profiling data).
- Run build/tests before publishing.
- Review dependency versions and update known-vulnerable packages.
