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
- Gitleaks scans pull requests, pushes to `main`, scheduled full-history runs, and manual dispatches.
- The Gitleaks baseline is committed at `.gitleaks.baseline.json`; it should contain only reviewed historical findings that have been rotated or explicitly accepted.
- Network calls should use HTTPS endpoints only.
- Local debug logs should avoid raw sensitive content in release builds.
- Build artifacts and local runtime outputs are ignored via `.gitignore`.

## Credential Rotation for Confirmed Leaks

When Gitleaks or manual review confirms that a real credential was committed:

1. Revoke or rotate the leaked credential at the issuing service before treating the repository fix as complete.
2. Update the active runtime location for the replacement secret, such as GitHub repository secrets, Cloudflare Worker secrets, local Keychain entries, or a developer-only `.env` file.
3. Search the current tree and relevant git history for the exposed value or provider-specific token fingerprint.
4. Remove the secret from source, logs, artifacts, and documentation. If history must retain a grandfathered finding, add only the reviewed Gitleaks finding to `.gitleaks.baseline.json`.
5. Rerun the secret scan workflow or local Gitleaks command (`gitleaks git --config=.gitleaks.toml --baseline-path .gitleaks.baseline.json .`) and save the result on the Linear issue.
6. Record the affected service, rotation time, verification result, and any remaining risk in Linear. Do not paste the secret value itself into Linear, GitHub, chat, or logs.

## Pre-GitHub Checklist

- Verify no credentials in source, docs, or sample files.
- Verify local artifacts are excluded (`.build/`, `.xcode-build/`, logs, profiling data).
- Run build/tests before publishing.
- Review dependency versions and update known-vulnerable packages.
