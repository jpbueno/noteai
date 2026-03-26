# NoteAI — Product Requirements Document (PRD)

## Context

Knowledge workers spend ~31 hours/month in meetings. Most discussion is lost because manual note-taking is incomplete and distracting. Existing solutions require meeting bots (often blocked by organizations), cloud recording (privacy concerns in regulated industries), or platform-specific plugins. NoteAI solves this by capturing system audio directly via macOS APIs, transcribing on-device with AI, and delivering structured summaries — all without bots, plugins, or sending audio to the cloud.

---

## 1. Product Vision & Overview

**NoteAI** is a **macOS-native menu bar application** that passively captures system audio from Microsoft Teams and Google Meet meetings, transcribes the conversation using on-device AI, identifies speakers, and delivers a structured summary once the meeting ends.

### Target Users
- **Primary**: Knowledge workers attending 3-10+ meetings/day on Teams and Meet
- **Secondary**: Engineering managers, PMs, executives needing meeting records for decision tracking
- **Tertiary**: Professionals in regulated industries where cloud recording is prohibited

### Key Differentiators
1. **No meeting bot required** — captures system audio directly, invisible to other participants
2. **On-device processing** — audio never leaves the machine by default
3. **Platform-agnostic** — works with Teams, Meet, and any audio-outputting app
4. **Native macOS experience** — menu bar, native notifications, Spotlight integration

---

## 2. Core Features

### F1: Meeting Audio Capture
- Capture system audio from specific apps (Teams desktop, Chrome/Edge/Arc for Meet)
- Simultaneous microphone capture for local user's voice (better diarization)
- Auto-detection of meeting start/end via audio activity + calendar integration
- Manual start/stop via menu bar or global shortcut (`Cmd+Shift+R`)

### F2: Real-Time AI Transcription
- On-device speech-to-text via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML on Apple Neural Engine)
- Streaming transcription with ~2-5 second latency
- Multiple model sizes: `tiny-en` (~30MB) through `large-v3` (~1.5GB)
- Optional cloud tier via Deepgram or OpenAI Whisper API

### F3: Speaker Diarization
- Identify distinct speakers in audio stream
- On-device via CoreML-converted [pyannote.audio](https://huggingface.co/pyannote/speaker-diarization)
- Speaker labeling: assign names post-meeting or pre-populate from calendar invitees
- Cross-meeting voice fingerprinting for automatic recurring speaker recognition

### F4: Meeting Summarization
- LLM-based structured summaries: Key Decisions, Action Items (with owners), Discussion Topics, Open Questions
- On-device: Llama 3.2 3B via [llama.cpp](https://github.com/ggml-org/llama.cpp) / MLX
- Cloud: OpenAI GPT-4o or Claude API (user-configurable)
- Chunked summarization for long meetings (>1 hour)

### F5: Note-Taking & Editing
- In-app transcript viewer with synchronized timeline
- Inline editing, markdown/PDF export, tagging, full-text search
- Linked notes: attach free-form notes to specific timestamps

### F6: Delivery & Notifications
- macOS native notification when summary is ready
- In-app meeting library for persistent access
- Email delivery (configurable)
- Auto-export to Markdown directory (e.g., Obsidian vault)
- Copy-to-clipboard option

---

## 3. Technical Architecture

### 3.1 System Audio Capture

**Primary: Core Audio Taps (macOS 14.2+)**
- `AudioHardwareCreateProcessTap` to tap specific application processes by PID
- Apple's sanctioned API for per-app audio capture without disrupting playback
- References: [AudioCap](https://github.com/insidegui/AudioCap), [AudioTee](https://github.com/makeusabrew/audiotee)

**Fallback: ScreenCaptureKit (macOS 13+)**
- `SCStream` with `capturesAudio = true`, very low frame rate to minimize overhead
- Filter by `SCRunningApplication` for target meeting app

**Microphone**: Standard `AVAudioEngine` tap on default input device (separate channel)

### 3.2 Audio Processing Pipeline

```
[System Audio Tap] ──→ [Audio Buffer Ring] ──→ [VAD Filter] ──→ [Chunker (5-10s)]
[Mic Audio Tap]    ──→ [Audio Buffer Ring] ──→ [VAD Filter] ──→ [Chunker]
                                                                      │
                                                                      ▼
                                                          [WhisperKit Transcription]
                                                                      │
                                                                      ▼
                                                          [Speaker Diarization]
                                                                      │
                                                                      ▼
                                                          [Transcript Assembly]
                                                                      │
                                                                      ▼
                                                          [Local SQLite Store]
                                                                      │
                                                          (on meeting end)
                                                                      ▼
                                                          [LLM Summarization]
                                                                      │
                                                                      ▼
                                                          [Notification + Delivery]
```

### 3.3 Transcription Engine
- **On-device (default)**: WhisperKit Swift package → CoreML → Apple Neural Engine
- Default model: `base-en` (~140MB), user-selectable up to `large-v3`
- Streaming: overlapping 5-10 second audio chunks
- **Cloud (optional)**: Deepgram Nova-2 or OpenAI Whisper API

### 3.4 Speaker Diarization
- CoreML-converted pyannote segmentation model
- Spectral clustering per meeting
- Mic channel identifies local user vs remote participants
- Cross-meeting speaker matching via local embedding database (cosine similarity)

### 3.5 Summarization Engine
- **On-device**: MLX-optimized Llama 3.2 3B or Phi-3 Mini
- **Cloud**: OpenAI GPT-4o / Claude API with structured JSON output
- Template: Key Decisions, Action Items (owner + deadline), Topics, Open Questions
- Long meetings: summarize 15-min blocks → meta-summarize

### 3.6 Data Storage
- **SQLite** (via GRDB.swift or SwiftData): meetings, transcripts, summaries, speaker profiles
- **File system**: temporary `.caf` audio files, deleted after transcription (configurable retention)
- **Encryption**: SQLCipher or Apple Data Protection at rest
- **Location**: `~/Library/Application Support/NoteAI/`

---

## 4. Platform Integration

### Meeting Detection

| Method | Description |
|--------|-------------|
| Process monitoring | Detect launch/audio of Teams, Chrome, Edge, Arc |
| Calendar integration | EventKit / Microsoft Graph API; auto-arm 1 min before meeting |
| Audio activity detection | VAD on captured stream to confirm meeting started |
| URL monitoring (optional) | Detect `meet.google.com` in browser via accessibility APIs |

### App-Specific Audio Routing
- **Teams desktop**: Tap process by PID via Core Audio Taps
- **Google Meet (browser)**: Tap browser process; use VAD + speech detection to filter non-meeting audio
- **Teams (browser)**: Same as Meet approach

### Required Permissions

| Permission | Purpose | API |
|------------|---------|-----|
| Screen Recording | ScreenCaptureKit fallback | `CGPreflightScreenCaptureAccess()` |
| Microphone | Local user voice | `AVCaptureDevice.requestAccess(for: .audio)` |
| Accessibility (optional) | Browser tab detection | Accessibility API |
| Calendar (optional) | Meeting auto-detection | EventKit |
| Notifications | Summary alerts | `UNUserNotificationCenter` |

---

## 5. User Experience

### Key Screens

**Menu Bar (Primary Interface)**
- Persistent icon: idle / listening / recording / processing states
- Click: dropdown with current status, recent meetings, quick actions
- Global shortcut: `Cmd+Shift+R`

**Meeting Library (Main Window)**
- Searchable list of past meetings
- Each entry: date, duration, participants, summary preview, tags

**Transcript Viewer**
- Full transcript with speaker labels + timestamps
- Click-to-play audio (if retained), inline editing, annotations

**Summary View**
- Structured card: Decisions, Action Items, Topics, Open Questions
- One-click copy/export/share

**Settings**
- Audio, AI model selection, privacy, delivery, calendar, shortcuts

### Core Workflow
1. NoteAI runs in menu bar (launches at login)
2. Meeting starts → auto-detected or manual trigger
3. Icon turns red; audio capture + transcription begin
4. Meeting ends → auto-stop (60s silence) or manual
5. Processing: final transcription, diarization, summarization (30-120s)
6. Notification: "Your meeting summary is ready"
7. User views/exports summary

---

## 6. AI/ML Pipeline

| Stage | Description |
|-------|-------------|
| 1. Ingestion | Capture at 16kHz mono; 30s ring buffer; VAD to skip silence |
| 2. Transcription | WhisperKit 5-10s chunks on Neural Engine; overlap-add for boundaries |
| 3. Diarization | Speaker segmentation → embedding extraction → clustering |
| 4. Post-processing | Punctuation restoration, capitalization, NER |
| 5. Summarization | Full transcript → LLM structured prompt → JSON output |
| 6. Delivery | Store locally, notify, email/export as configured |

---

## 7. Data & Privacy

### Privacy-First Architecture

| Data | Default | Configurable |
|------|---------|-------------|
| Raw audio | Deleted after transcription | Retain N days |
| Transcripts | Local, encrypted at rest | Cloud backup (opt-in) |
| Summaries | Local, encrypted at rest | Cloud backup (opt-in) |
| Speaker embeddings | Local only | Delete on uninstall |
| Cloud API calls | Audio sent to API, not stored | Disable cloud entirely |

### Principles
- **Local-first by default**: all processing on-device unless user enables cloud
- **No audio leaves device** in default config
- **Consent**: clear recording indicator; user responsible for participant consent
- **Data portability**: JSON/Markdown export, no lock-in
- **Secure deletion**: audio securely erased on retention expiry
- **GDPR-friendly**: all data local, user controls deletion

---

## 8. Non-Functional Requirements

| Requirement | Target |
|-------------|--------|
| Transcription latency | < 5s behind real-time (base-en on M1+) |
| Summary generation | < 120s for 1-hour meeting |
| CPU usage during recording | < 15% (Neural Engine offload) |
| Memory usage | < 500 MB RSS |
| Battery impact | < 10%/hour on MacBook Air M2 |
| Storage per meeting hour | ~5 MB (transcript + summary) |
| App launch time | < 2s to menu bar ready |
| Reliability | 99.5% successful capture |
| Minimum macOS | 14.2+ (Sonoma) — Core Audio Taps |
| Hardware | Apple Silicon required (Intel: cloud-only mode) |

---

## 9. Technical Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Core Audio Taps API changes | High | ScreenCaptureKit fallback; monitor WWDC |
| Browser captures non-meeting audio | Medium | VAD + speech classifier; user confirmation |
| Whisper accuracy on technical jargon | Medium | Custom vocabulary; cloud tier option |
| Mac App Store rejection | High | Direct download + notarization |
| Battery drain on laptops | Medium | Neural Engine offload; adaptive model selection |
| Diarization accuracy with system audio | Medium | Mic channel for local user; cross-meeting learning |
| Legal liability for recording | High | Consent UI; recording indicator; user responsibility |

---

## 10. Roadmap

### Phase 1 — MVP (Months 1-3)
- Menu bar app, manual start/stop
- Core Audio Taps capture for Teams + Chrome/Meet
- On-device transcription (WhisperKit base-en)
- Cloud summarization (OpenAI/Claude)
- In-app transcript + summary viewer
- macOS notification delivery

### Phase 2 (Months 4-6)
- Speaker diarization (on-device)
- Calendar integration for auto-detection
- On-device summarization (MLX Llama)
- Email delivery + Markdown/Obsidian export
- Model selection + privacy settings UI

### Phase 3 (Months 7-9)
- Cross-meeting speaker recognition
- Action item extraction with owner assignment
- Spotlight search across transcripts
- Zoom desktop support
- Real-time floating transcript overlay

### Phase 4 (Months 10-12)
- Slack/Notion/webhook integrations
- Meeting analytics dashboard
- Multi-language transcription
- Custom vocabulary fine-tuning
- iOS companion app (view summaries)

---

## 11. Recommended Project Structure

```
NoteAI/
├── NoteAI.xcodeproj
├── NoteAI/
│   ├── App/
│   │   ├── NoteAIApp.swift
│   │   └── AppDelegate.swift
│   ├── Audio/
│   │   ├── AudioCaptureManager.swift
│   │   ├── ProcessTapProvider.swift
│   │   ├── ScreenCaptureProvider.swift
│   │   ├── MicrophoneCaptureManager.swift
│   │   └── AudioBufferRing.swift
│   ├── Transcription/
│   │   ├── TranscriptionEngine.swift
│   │   ├── CloudTranscriptionService.swift
│   │   └── TranscriptionModels.swift
│   ├── Diarization/
│   │   ├── SpeakerDiarizationEngine.swift
│   │   ├── SpeakerEmbeddingStore.swift
│   │   └── SpeakerProfile.swift
│   ├── Summarization/
│   │   ├── SummarizationEngine.swift
│   │   ├── LocalLLMProvider.swift
│   │   ├── CloudLLMProvider.swift
│   │   └── SummaryTemplates.swift
│   ├── MeetingDetection/
│   │   ├── MeetingDetector.swift
│   │   ├── CalendarIntegration.swift
│   │   └── ProcessMonitor.swift
│   ├── Storage/
│   │   ├── MeetingStore.swift
│   │   ├── Models/
│   │   │   ├── Meeting.swift
│   │   │   ├── Transcript.swift
│   │   │   └── Summary.swift
│   │   └── AudioFileManager.swift
│   ├── Delivery/
│   │   ├── NotificationManager.swift
│   │   ├── EmailDeliveryService.swift
│   │   └── ExportManager.swift
│   ├── UI/
│   │   ├── MenuBar/
│   │   ├── MeetingLibrary/
│   │   ├── TranscriptViewer/
│   │   ├── SummaryView/
│   │   └── Settings/
│   └── Utilities/
│       ├── KeyboardShortcutManager.swift
│       ├── Logger.swift
│       └── Constants.swift
├── NoteAITests/
└── NoteAIUITests/
```

---

## 12. Key Technical References

- [Apple: Core Audio Taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) — primary audio capture
- [AudioCap](https://github.com/insidegui/AudioCap) — Core Audio taps reference implementation
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/) — fallback capture
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device transcription
- [pyannote speaker diarization](https://huggingface.co/pyannote/speaker-diarization) — diarization model
- [Azayaka](https://github.com/Mnpn/Azayaka) — menu bar recorder using ScreenCaptureKit

---

## Verification

To validate the implementation end-to-end:
1. Build and run the Xcode project on an Apple Silicon Mac running macOS 14.2+
2. Grant Screen Recording and Microphone permissions when prompted
3. Start a Teams or Google Meet call, trigger recording via `Cmd+Shift+R`
4. Verify live transcription appears in the transcript viewer within ~5 seconds
5. End the meeting; confirm summary notification arrives within 2 minutes
6. Open the summary and verify structured sections (Decisions, Action Items, Topics)
7. Export as Markdown and verify formatting
8. Check `~/Library/Application Support/NoteAI/` for proper data storage
9. Verify audio files are deleted after transcription (default privacy setting)
