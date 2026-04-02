#!/usr/bin/swift

import Foundation
import SQLite3

// Simulate a realistic Teams meeting with multiple speakers,
// transcript segments, and AI-generated summary.

struct SimTranscriptSegment: Codable {
    let id: Int
    let text: String
    let startTime: Float
    let endTime: Float
    let speaker: String?
    let confidence: Float?
}

struct SimActionItem: Codable {
    let task: String
    let owner: String?
    let deadline: String?
}

struct SimSummary: Codable {
    let decisions: [String]
    let actionItems: [SimActionItem]
    let topics: [String]
    let openQuestions: [String]
}

struct SimMeeting: Codable {
    let id: String
    let title: String
    let date: Date
    let duration: Double
    let transcript: [SimTranscriptSegment]
    let summary: SimSummary
}

// Build a realistic 15-minute Teams standup meeting
let transcript: [SimTranscriptSegment] = [
    .init(id: 1, text: "Alright, let's get started everyone. Good morning.", startTime: 0, endTime: 3, speaker: "Sarah (PM)", confidence: 0.95),
    .init(id: 2, text: "Morning! Can everyone hear me okay?", startTime: 4, endTime: 6, speaker: "James (Eng Lead)", confidence: 0.93),
    .init(id: 3, text: "Yep, sounds good. Let me share my screen real quick.", startTime: 7, endTime: 10, speaker: "Maria (Designer)", confidence: 0.91),
    .init(id: 4, text: "So first item on the agenda — the Q2 roadmap. We need to finalize which features make the cut by end of this week.", startTime: 12, endTime: 20, speaker: "Sarah (PM)", confidence: 0.96),
    .init(id: 5, text: "I think the real-time collaboration feature should be our top priority. We've had multiple enterprise customers asking for it.", startTime: 22, endTime: 30, speaker: "James (Eng Lead)", confidence: 0.94),
    .init(id: 6, text: "Agreed. From the design side, we already have the mockups ready for the collaborative editing flow. I can share those in Figma after this call.", startTime: 32, endTime: 42, speaker: "Maria (Designer)", confidence: 0.92),
    .init(id: 7, text: "What about the API v2 migration? DevOps has been pushing for that.", startTime: 44, endTime: 49, speaker: "Carlos (Backend)", confidence: 0.90),
    .init(id: 8, text: "That's important but I'd rank it second. The collaboration feature has direct revenue impact. Let's target API v2 for the second half of Q2.", startTime: 50, endTime: 62, speaker: "Sarah (PM)", confidence: 0.95),
    .init(id: 9, text: "Makes sense. I can start scoping the collaboration backend this sprint. We'll need WebSocket infrastructure.", startTime: 64, endTime: 74, speaker: "James (Eng Lead)", confidence: 0.93),
    .init(id: 10, text: "I already looked into that. We could use Socket.IO or go with a custom solution on top of Redis pub/sub. I'd recommend the custom approach for better control.", startTime: 76, endTime: 90, speaker: "Carlos (Backend)", confidence: 0.91),
    .init(id: 11, text: "Let's go with the custom approach then. Carlos, can you write up a technical design doc by Thursday?", startTime: 92, endTime: 100, speaker: "James (Eng Lead)", confidence: 0.94),
    .init(id: 12, text: "Sure, I'll have it ready by Thursday EOD.", startTime: 101, endTime: 105, speaker: "Carlos (Backend)", confidence: 0.96),
    .init(id: 13, text: "Perfect. Now, the mobile app — where are we on the iOS release?", startTime: 108, endTime: 114, speaker: "Sarah (PM)", confidence: 0.95),
    .init(id: 14, text: "We're about 80% done. The main blocker is the offline sync feature. It's more complex than we estimated.", startTime: 116, endTime: 126, speaker: "James (Eng Lead)", confidence: 0.92),
    .init(id: 15, text: "How much more time do we need?", startTime: 128, endTime: 131, speaker: "Sarah (PM)", confidence: 0.97),
    .init(id: 16, text: "Probably another two weeks. We need to handle conflict resolution properly or we'll have data corruption issues.", startTime: 132, endTime: 142, speaker: "James (Eng Lead)", confidence: 0.93),
    .init(id: 17, text: "Okay, let's push the iOS release to April 4th then. Better to ship something solid than rush it.", startTime: 144, endTime: 154, speaker: "Sarah (PM)", confidence: 0.95),
    .init(id: 18, text: "One more thing — the onboarding redesign. Maria, how's that coming along?", startTime: 158, endTime: 165, speaker: "Sarah (PM)", confidence: 0.94),
    .init(id: 19, text: "I finished the user testing last week. The new flow cuts onboarding time by 40%. I'll present the results in our design review tomorrow.", startTime: 167, endTime: 180, speaker: "Maria (Designer)", confidence: 0.91),
    .init(id: 20, text: "That's a huge improvement. Great work Maria.", startTime: 182, endTime: 186, speaker: "James (Eng Lead)", confidence: 0.95),
    .init(id: 21, text: "Thanks! Should I also prepare implementation specs for the engineering team?", startTime: 187, endTime: 193, speaker: "Maria (Designer)", confidence: 0.92),
    .init(id: 22, text: "Yes please, that would be super helpful. Coordinate with James on the timeline.", startTime: 194, endTime: 200, speaker: "Sarah (PM)", confidence: 0.96),
    .init(id: 23, text: "Will do. I'll set up a sync with James for Friday.", startTime: 201, endTime: 206, speaker: "Maria (Designer)", confidence: 0.93),
    .init(id: 24, text: "Alright, anything else before we wrap up?", startTime: 210, endTime: 214, speaker: "Sarah (PM)", confidence: 0.97),
    .init(id: 25, text: "Just a heads up — I'll be out next Monday for a dentist appointment. I'll be available on Slack though.", startTime: 215, endTime: 224, speaker: "Carlos (Backend)", confidence: 0.90),
    .init(id: 26, text: "Noted. Okay everyone, great meeting. Let's execute on these action items and sync again on Friday. Have a good day!", startTime: 226, endTime: 238, speaker: "Sarah (PM)", confidence: 0.96),
    .init(id: 27, text: "Thanks everyone, bye!", startTime: 239, endTime: 242, speaker: "James (Eng Lead)", confidence: 0.94),
]

let summary = SimSummary(
    decisions: [
        "Real-time collaboration is the #1 priority for Q2",
        "API v2 migration moved to second half of Q2",
        "Custom WebSocket solution (Redis pub/sub) chosen over Socket.IO",
        "iOS release pushed to April 4th to ensure offline sync quality",
        "New onboarding flow approved based on 40% time reduction in user testing"
    ],
    actionItems: [
        SimActionItem(task: "Write technical design doc for collaboration WebSocket infrastructure", owner: "Carlos", deadline: "Thursday EOD"),
        SimActionItem(task: "Share collaborative editing Figma mockups with team", owner: "Maria", deadline: "Today"),
        SimActionItem(task: "Present onboarding redesign results at design review", owner: "Maria", deadline: "Tomorrow"),
        SimActionItem(task: "Prepare implementation specs for onboarding redesign", owner: "Maria", deadline: "Friday"),
        SimActionItem(task: "Schedule sync with James for onboarding implementation timeline", owner: "Maria", deadline: "Friday"),
        SimActionItem(task: "Scope collaboration backend and WebSocket infrastructure", owner: "James", deadline: "This sprint"),
        SimActionItem(task: "Complete iOS offline sync feature", owner: "James", deadline: "2 weeks"),
        SimActionItem(task: "Finalize Q2 roadmap feature list", owner: "Sarah", deadline: "End of this week")
    ],
    topics: [
        "Q2 roadmap prioritization",
        "Real-time collaboration feature planning",
        "API v2 migration timeline",
        "iOS mobile app release status",
        "Offline sync complexity and timeline",
        "Onboarding redesign user testing results"
    ],
    openQuestions: [
        "What is the exact scope of the collaboration MVP vs full feature?",
        "Do we need to hire additional backend engineers for WebSocket infra?",
        "Should the iOS offline sync support media attachments or just text?"
    ]
)

let meetingId = UUID().uuidString
let meeting = SimMeeting(
    id: meetingId,
    title: "Microsoft Teams — Mar 19, 2026, 2:00 PM",
    date: Date(),
    duration: 242, // ~4 minutes of content, simulating 15-min meeting
    transcript: transcript,
    summary: summary
)

// Encode to JSON
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .secondsSince1970
let jsonData = try! encoder.encode(meeting)
let jsonString = String(data: jsonData, encoding: .utf8)!

// Insert into SQLite database
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let dbDir = appSupport.appendingPathComponent("NoteAI", isDirectory: true)
try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("meetings.sqlite").path

var db: OpaquePointer?
guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
    print("ERROR: Could not open database at \(dbPath)")
    exit(1)
}

// Create table if needed
let createSQL = """
    CREATE TABLE IF NOT EXISTS meetings (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        date REAL NOT NULL,
        duration REAL NOT NULL,
        json_data TEXT NOT NULL
    )
"""
sqlite3_exec(db, createSQL, nil, nil, nil)

// Insert meeting
let insertSQL = "INSERT OR REPLACE INTO meetings (id, title, date, duration, json_data) VALUES (?, ?, ?, ?, ?)"
var stmt: OpaquePointer?
guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
    print("ERROR: Could not prepare statement")
    exit(1)
}

sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
sqlite3_bind_text(stmt, 2, ("Microsoft Teams — Mar 19, 2026, 2:00 PM" as NSString).utf8String, -1, nil)
sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
sqlite3_bind_double(stmt, 4, 242)
sqlite3_bind_text(stmt, 5, (jsonString as NSString).utf8String, -1, nil)

guard sqlite3_step(stmt) == SQLITE_DONE else {
    print("ERROR: Could not insert meeting")
    exit(1)
}
sqlite3_finalize(stmt)

// Verify
let countSQL = "SELECT COUNT(*) FROM meetings"
var countStmt: OpaquePointer?
sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil)
sqlite3_step(countStmt)
let count = sqlite3_column_int(countStmt, 0)
sqlite3_finalize(countStmt)

sqlite3_close(db)

print("SUCCESS: Simulated Teams meeting inserted into database")
print("  Title: Microsoft Teams — Mar 19, 2026, 2:00 PM")
print("  Speakers: Sarah (PM), James (Eng Lead), Maria (Designer), Carlos (Backend)")
print("  Segments: \(transcript.count)")
print("  Decisions: \(summary.decisions.count)")
print("  Action Items: \(summary.actionItems.count)")
print("  Total meetings in DB: \(count)")
print("  DB path: \(dbPath)")

// Also export as Markdown to verify format
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let mdPath = "\(scriptDir)/test_output.md"
var md = "---\n"
md += "title: \"Microsoft Teams — Mar 19, 2026, 2:00 PM\"\n"
md += "date: \(ISO8601DateFormatter().string(from: Date()))\n"
md += "duration: 4m\n"
md += "segments: \(transcript.count)\n"
md += "tags: [meeting]\n"
md += "type: meeting-notes\n"
md += "---\n\n"
md += "# Microsoft Teams — Mar 19, 2026, 2:00 PM\n\n"
md += "**Date:** \(Date().formatted(date: .long, time: .shortened))\n"
md += "**Duration:** 4m\n\n---\n\n"
md += "## Summary\n\n"
md += "### Key Decisions\n\n"
for d in summary.decisions { md += "- \(d)\n" }
md += "\n### Action Items\n\n"
for a in summary.actionItems {
    var line = "- [ ] \(a.task)"
    if let o = a.owner { line += " — **\(o)**" }
    if let d = a.deadline { line += " (by \(d))" }
    md += line + "\n"
}
md += "\n### Topics Discussed\n\n"
for t in summary.topics { md += "- \(t)\n" }
md += "\n### Open Questions\n\n"
for q in summary.openQuestions { md += "- \(q)\n" }
md += "\n---\n\n## Transcript\n\n"
for s in transcript {
    let mins = Int(s.startTime) / 60
    let secs = Int(s.startTime) % 60
    let ts = String(format: "%02d:%02d", mins, secs)
    md += "**[\(ts)] \(s.speaker ?? "Speaker"):** \(s.text)\n\n"
}
try! md.write(toFile: mdPath, atomically: true, encoding: .utf8)
print("\n  Markdown exported to: \(mdPath)")
