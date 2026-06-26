# NoteAI v6 Transcript Import and Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an isolated NoteAI v6 macOS app variant that imports pasted Teams transcripts for summarization and starts a local source-grounded memory foundation.

**Architecture:** Add small local Modules behind explicit seams: transcript import parsing, imported meeting creation, and evidence-backed memory candidates. Keep recording internals intact and only change the v6-facing entrypoints/UI.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB, XCTest, XcodeGen project.yml.

---

### Task 1: Transcript Import Parser

**Files:**
- Create: `NoteAI/App/TranscriptImportParser.swift`
- Modify: `NoteAITests/ArchitectureModuleTests.swift`

- [ ] Add failing tests for Teams-style transcript parsing in `ArchitectureModuleTests`.
- [ ] Implement `TranscriptImportParser.parse(_:) -> [TranscriptSegment]`.
- [ ] Verify parser preserves speakers, timestamps, and fallback text.

### Task 2: Source-Grounded Memory Foundation

**Files:**
- Create: `NoteAI/Memory/MemoryModels.swift`
- Modify: `NoteAITests/ArchitectureModuleTests.swift`

- [ ] Add tests for `EvidenceSource`, `MemoryCandidate`, and the future `SourceAdapter` seam.
- [ ] Implement minimal codable models with local-only source metadata.
- [ ] Verify no external connector or network behavior is introduced.

### Task 3: Imported Meeting Workflow

**Files:**
- Modify: `NoteAI/App/MeetingCaptureWorkflow.swift`
- Modify: `NoteAI/App/MeetingManager.swift`
- Modify: `NoteAITests/ArchitectureModuleTests.swift`

- [ ] Add tests for imported transcript meeting creation.
- [ ] Add a `MeetingManager.importTranscriptMeeting(title:rawTranscript:source:)` async entrypoint.
- [ ] Reuse existing summarization and persistence behavior.
- [ ] Ensure no task/todo creation is added.

### Task 4: v6 App Identity and Storage Namespace

**Files:**
- Modify: `project.yml`
- Modify: `NoteAI/Info.plist`
- Modify: `NoteAI/Storage/MeetingStore.swift`

- [ ] Add build settings for `NoteAI v6` identity.
- [ ] Add data namespace selection so v6 uses `Application Support/NoteAI-v6`.
- [ ] Verify current `NoteAI` storage namespace remains unchanged for the existing app.

### Task 5: Transcript Import UI

**Files:**
- Modify: `NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift`
- Create if useful: `NoteAI/UI/MeetingLibrary/TranscriptImportView.swift`

- [ ] Replace the prominent recording action in v6-facing UI with `Import Transcript`.
- [ ] Add paste modal with meeting title and transcript body.
- [ ] Call `MeetingManager.importTranscriptMeeting`.
- [ ] Preserve live recording internals for the existing app.

### Task 6: Verification, Install, and Delivery

**Files:**
- Update docs and Linear with verification output.

- [ ] Run focused XCTest.
- [ ] Run macOS debug build.
- [ ] Install to `/Applications/NoteAI v6.app`.
- [ ] Confirm `/Applications/NoteAI.app` is not overwritten.
- [ ] Commit and push branch with JPB-203 in the commit message.

