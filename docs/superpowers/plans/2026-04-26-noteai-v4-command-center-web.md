# NoteAI v4 Command Center Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin the NoteAI web app into a v4 Command Center interface while preserving the existing NoteAI logo component.

**Architecture:** Keep the existing Next.js SPA and data hooks intact. Update the shell, sidebar, dashboard, list/detail surfaces, and chat drawer through scoped component and CSS changes without changing persistence, API routes, or domain types.

**Tech Stack:** Next.js 16, React 19, TypeScript, Tailwind CSS 4, lucide-react.

---

### Task 1: App Shell And Theme

**Files:**
- Modify: `web/src/app/globals.css`
- Modify: `web/src/app/page.tsx`

- [ ] Update global theme tokens to a v4 graphite command-center palette with cyan/green accent and refined focus/hover states.
- [ ] Replace the fixed floating brand header with an integrated shell header that still uses `BrainHeadIcon`.
- [ ] Update the chat launcher and drawer divider to match v4 surfaces.

### Task 2: Command Center Sidebar

**Files:**
- Modify: `web/src/components/Sidebar.tsx`

- [ ] Keep all existing navigation callbacks and delete behavior.
- [ ] Restyle recording control, search, sections, selected states, empty states, and settings footer to match the mockup.
- [ ] Preserve existing NoteAI logo by keeping logo rendering in `page.tsx`.

### Task 3: Dashboard And Lists

**Files:**
- Modify: `web/src/components/HomeDashboard.tsx`
- Modify: `web/src/components/SectionListView.tsx`

- [ ] Replace the task-only home page with a Command Center overview: operational metrics, priority tasks, and due-grouped task lanes.
- [ ] Restyle notes, meetings, and T5T list views with denser command-center rows and stronger metadata.

### Task 4: Detail Surfaces And Chat

**Files:**
- Modify: `web/src/components/MeetingDetail.tsx`
- Modify: `web/src/components/ChatPanel.tsx`

- [ ] Give meeting detail the v4 report treatment with a polished title/meta/action area, tab styling, and summary blocks.
- [ ] Update the AI copilot drawer styling to match Command Center.

### Task 5: Verification

**Files:**
- Verify: `web/src/**/*.tsx`
- Verify: `web/src/app/globals.css`

- [ ] Run `npm run build` from `web`.
- [ ] Run the dev server and inspect the UI in the browser.
- [ ] Fix TypeScript, layout, and responsive issues found during verification.
