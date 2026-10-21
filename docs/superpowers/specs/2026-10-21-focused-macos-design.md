# Focused NoteAI macOS

## Intent and scope

JP uses NoteAI for meeting transcription and AI Solutions Architect. Update the existing macOS app only. Keep the public web app retired, as recorded in JPB-191. Track this session in JPB-26 because Linear rejected dedicated issue creation at the workspace issue limit.

Keep recording and automatic detection, transcription and transcript import, meeting history/search, speaker context, meeting summaries and their editing, meeting export/read-aloud, and the live AI Solutions Architect with interactive questions. Preserve the current capture and session-safe coach behavior from main.

Remove standalone notes, T5T reports, durable tasks, lightweight to dos, and the general multi-entity AI assistant, including their navigation, creation/editing paths, generation code, settings, and external work-activity integrations. Action items embedded in meeting summaries and SA insights remain meeting content rather than a standalone task system.

## Architecture

The Meeting Capture Module and AI SA Module keep their existing Interfaces and actor Implementations. Existing capture/provider Seams and Adapters stay intact. Removing the unused library workflows increases Depth and Leverage for the retained meeting Interface and improves Locality by eliminating cross-entity orchestration. Shared layout, meeting Markdown editing, credentials, authentication, and export remain where the retained modules use them.

## Data and security

Keep the primary bundle identity, storage namespace, and Keychain service so the update can read existing meetings and provider credentials. Do not drop, clear, or migrate retired SQLite tables or delete associated files. Stop creating and using retired tables in the focused app. Preserve the Meeting Codable shape and existing stored summary/speaker data. No live database mutation or running-app interruption is part of source implementation.

## Delivery and verification

Build the macOS app and run relevant automated tests, including capture/coach regressions, meeting persistence/export, and legacy-table preservation. Update the Xcode project from project.yml after source deletions. Deliver a commit referencing JPB-26 through a green PR to main, verify post-merge checks, and record evidence in Linear. Web code and deployment stay unchanged.

## Implementation calls

Use the existing SwiftUI/GRDB/WhisperKit stack and current-main checkout. Introduce the focused product as version 7.0 for the primary NoteAI target; keep the existing v6 transcript-import target's identity. Replace the multi-feature dashboard with meeting-focused navigation, keeping capture controls and onboarding discoverable.
