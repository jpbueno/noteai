# NoteAI v6 Transcript Import and Memory Design

Issue: JPB-203

## Goal

Build a separate NoteAI v6 macOS variant that can be shown to other people without the security concerns of live meeting recording. The v6 flow should import pasted Microsoft Teams transcripts, summarize them as meetings, and lay the first source-grounded memory foundation for future Outlook, Slack, Google Drive, Teams, and code activity adapters.

## Version Isolation

The current NoteAI app remains intact. The new variant uses a separate app identity and install path:

- Display name: `NoteAI v6`
- Bundle identifier: `com.noteai.app.v6`
- Local install path: `/Applications/NoteAI v6.app`
- Local data namespace: `NoteAI-v6`

This prevents the v6 demo app from overwriting `/Applications/NoteAI.app` or sharing the current app's local database by accident.

## Transcript Import Flow

The primary v6 capture path is transcript import, not live recording:

1. User clicks `Import Transcript`.
2. User pastes raw Teams transcript text.
3. NoteAI parses the transcript into `TranscriptSegment` records.
4. User names the meeting.
5. NoteAI creates a `Meeting`, stores the original transcript source as evidence, and runs the existing summarization pipeline.

The importer accepts simple pasted formats such as:

```text
Speaker Name
0:01
Transcript text...

Speaker Name 10:24
Transcript text...
```

When timestamps or speakers are missing, the importer still preserves text using sequential timestamps and an unknown speaker.

## Memory Foundation

v6 starts the Option B architecture: source-grounded memory. This first slice does not implement external connectors. It creates the local Module and Interface needed for future adapters.

Core Modules:

- `TranscriptImportParser`: converts pasted transcript text into structured transcript segments.
- `EvidenceSource`: records where imported content came from.
- `MemoryCandidate`: represents reviewable extracted memory, not permanent memory.
- `SourceAdapter` protocol: future seam for Outlook, Slack, Google Drive, Teams, and code activity adapters.

Security posture:

- Imported transcript content stays local.
- No Slack, Outlook, Google Drive, or Teams API access is added in this slice.
- No durable personal memory is written without a reviewable candidate.
- Transcript summaries remain summaries; they do not auto-create tasks or todos.

## Architecture Notes

`MeetingCaptureWorkflow` remains the leverage point for creating meetings and failed summaries. Transcript import should feed the same Meeting and summarization pipeline used by recordings, with a new adapter-style entrypoint.

The memory foundation should stay shallow in scope but deep at its Interface: future sources should be able to plug into the same source/evidence model without changing meeting import code.

## Verification

Required verification:

- Focused XCTest for transcript parsing.
- Focused XCTest for evidence/memory candidate creation.
- Existing architecture tests.
- Debug macOS build.
- Confirm `/Applications/NoteAI.app` is not overwritten.
- Install verified build to `/Applications/NoteAI v6.app`.

