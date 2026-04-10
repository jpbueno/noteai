/**
 * T5T Generation Engine
 *
 * Template-driven weekly report generation following NVIDIA's T5T (Top 5 Things) culture.
 * Ported from the Claude Code T5T skill to work in the NoteAI web app.
 */

import type {
  T5TConfig,
  T5TReportSection,
  T5TReportTemplateSection,
  DailyLog,
  Meeting,
  Note,
  TaskItem,
} from "./types";
import { chatWithAI } from "./ai";

// ===== System Prompt =====

function buildSystemPrompt(config: T5TConfig): string {
  const { identity, writingPrinciples, reportTemplate } = config;

  const sectionNames = reportTemplate.map((s) => s.name).join(", ");
  const mappingDesc = config.sectionMapping
    .map((m) => `  - "${m.dailySection}" -> "${m.reportSection}"`)
    .join("\n");

  return `You are an expert technical writer specializing in executive communication for engineering teams. You generate weekly reports following NVIDIA's T5T (Top 5 Things) culture.

## Writer Identity
${identity.name ? `Writing as: ${identity.name}` : "Writing in first person"}
${identity.role ? `Role: ${identity.role}` : ""}
${identity.team ? `Team: ${identity.team}` : ""}

## Report Sections
Generate content for these sections: ${sectionNames}

## Section Mapping (Daily Log -> Report)
${mappingDesc}

## Core T5T Principles

1. MISSION-FOCUSED: Open with context — what mission does this work serve?
2. PRIORITY-DRIVEN: Top 5 priorities and outcomes, not a comprehensive to-do list
3. AUDIENCE: Write for busy managers AND a broad audience. Scannable on phones. 2-3 minute read
4. OUTCOMES OVER ACTIVITIES: "Completed X, enabling Y" not "Worked on X"
5. PLAIN SPOKEN: Clear, direct language. Minimize jargon
6. AMANALAP: "As Much As Necessary, As Little As Possible." Every word earns its place
7. ALERT / ALIGNED / AGILE: Surface threats, opportunities, direction changes
8. DATA-DRIVEN: Ground claims in data — test counts, pass rates, time saved
9. USE THE WHOLE TEAM: Credit colleagues by name. Flag when you need help
10. EARLY INDICATORS: Flag signals that predict future success or failure

## Writing Style
- Audience: ${writingPrinciples.audience}
- Tone: ${writingPrinciples.tone}
- Person: ${writingPrinciples.person === "first" ? "First person (\"I completed...\", \"I delivered...\")" : "Third person"}
- Detail: ${writingPrinciples.detailDepth}
- Data: ${writingPrinciples.dataStyle}

## Section-Specific Rules

### Summary
- 3-5 items MAX representing the week's top priorities and outcomes
- Each bullet answers: "What mission? What outcome? Why does it matter?"
- Lead with metrics when available

### Key Issues / Bugs
- Only from content mapped to this section
- Format: "[B] Bug ID: Title" with Impact and Status sub-bullets
- Maximum 5 bugs, prioritized by impact
- Write "None" if no bugs

### Projects
- Group by project/test suite name
- HIGH-LEVEL status: what was done, pass/fail results, completion status
- Format: "{Project} ({Ticket}): {Status}. {metrics}"
- EXCLUDE troubleshooting details, environment setup, workarounds

### Automation / Tooling
- Focus on completed automation work and business impact
- Include identifiers: Template IDs, MR numbers
- Explain business value: time saved, reliability improved

### Other Activities
- Collaboration, knowledge sharing, process improvements
- Credit colleagues by name

### Meetings Attended
- Markdown table with Subject, Start Time, End Time columns
- Group by day with bold day headers
- Write "None" if no meeting data

### Next Week
- 3-5 actionable items, prioritized (most important first)
- Format: "{Action verb} {what} ({links}) - {expected outcome}"
- Write "None" if no items

## Quality Rules
- No cross-section contamination
- No personal content leakage
- Max 2-level bullet nesting (except bug entries)
- No bullet exceeds ~120 chars unless single cohesive statement
- Every statement must be traceable to source data
- All sections present, even if empty ("None")

## Bullet Structure
- Main bullet: One sentence headline achievement
- Sub-bullets: Supporting details, one per line
- Max 3-4 sub-bullets per main bullet
- Decompose long bullets (>120 chars with multiple facts)

## Link Formatting
${config.jiraBaseUrl ? `- JIRA tickets: [TICKET-ID](${config.jiraBaseUrl}/TICKET-ID)` : ""}
${config.nvbugBaseUrl ? `- NVBugs: [BugID](${config.nvbugBaseUrl}/BugID)` : ""}

## Output Format
Return a JSON object with a "sections" array. Each section has "name" (matching the report template section name exactly) and "content" (markdown string for that section).

Example:
{"sections": [{"name": "Summary", "content": "* Completed X with 100% pass rate\\n* Delivered Y, reducing manual effort by 3 hours"}, {"name": "Key Issues", "content": "None"}, ...]}

CRITICAL: Return ONLY the JSON object. No markdown fences. No additional text.`;
}

// ===== Context Builder =====

function buildSourceContext(
  dailyLogs: DailyLog[],
  meetings: Meeting[],
  notes: Note[],
  tasks: TaskItem[],
  config: T5TConfig,
): string {
  const parts: string[] = [];

  // Daily logs — primary source, organized by date with section names
  if (dailyLogs.length > 0) {
    parts.push("# Daily Logs (Primary Source)\n");
    const sorted = [...dailyLogs].sort((a, b) => a.date.localeCompare(b.date));
    for (const log of sorted) {
      parts.push(`## ${log.date}`);
      for (const section of log.sections) {
        if (!section.content.trim()) continue;
        // Check classification
        const templateSection = config.dailyTemplate.find(
          (t) => t.name === section.name
        );
        const isPersonal = templateSection?.classification === "personal";
        if (isPersonal) {
          parts.push(`### ${section.name} [PERSONAL - EXCLUDE FROM REPORT]`);
          parts.push("(Content excluded per classification)");
        } else {
          parts.push(`### ${section.name}`);
          parts.push(section.content);
        }
        parts.push("");
      }
      parts.push("");
    }
  }

  // Meetings — secondary source
  if (meetings.length > 0) {
    parts.push("# Meetings\n");
    for (const m of meetings) {
      parts.push(`## ${m.title} (${m.date.slice(0, 10)})`);
      if (m.summary.wasSummarized) {
        if (m.summary.decisions.length > 0)
          parts.push("Decisions: " + m.summary.decisions.join("; "));
        if (m.summary.topics.length > 0)
          parts.push("Topics: " + m.summary.topics.join("; "));
        if (m.summary.actionItems.length > 0)
          parts.push(
            "Actions: " +
              m.summary.actionItems.map((a) => a.task).join("; ")
          );
      } else {
        const text = m.transcript.map((s) => s.text).join(" ");
        parts.push(text.slice(0, 1500));
      }
      parts.push("");
    }
  }

  // Notes — supplementary source
  if (notes.length > 0) {
    parts.push("# Notes\n");
    for (const n of notes) {
      parts.push(`## ${n.title}`);
      parts.push(n.content.slice(0, 800));
      parts.push("");
    }
  }

  // Tasks — supplementary source
  if (tasks.length > 0) {
    parts.push("# Tasks\n");
    for (const t of tasks) {
      parts.push(`- ${t.title || "Untitled"} [${t.status}]${t.description ? ": " + t.description.slice(0, 200) : ""}`);
    }
    parts.push("");
  }

  return parts.join("\n");
}

// ===== Quality Checks =====

export interface QualityCheck {
  id: string;
  name: string;
  passed: boolean;
  message: string;
}

export function runQualityChecks(
  sections: T5TReportSection[],
  config: T5TConfig,
): QualityCheck[] {
  const checks: QualityCheck[] = [];

  // 1. All template sections present
  const sectionNames = new Set(sections.map((s) => s.name));
  const missingCount = config.reportTemplate.filter(
    (t) => !sectionNames.has(t.name)
  ).length;
  checks.push({
    id: "completeness",
    name: "All sections present",
    passed: missingCount === 0,
    message:
      missingCount === 0
        ? "All sections present"
        : `${missingCount} section(s) missing`,
  });

  // 2. Summary has 3-5 items
  const summary = sections.find((s) => s.name === "Summary");
  if (summary) {
    const bullets = summary.content
      .split("\n")
      .filter((l) => l.trim().startsWith("*") || l.trim().startsWith("-"));
    const count = bullets.length;
    checks.push({
      id: "summary_count",
      name: "Summary: 3-5 items",
      passed: count >= 3 && count <= 5,
      message: `${count} item(s) in summary${count < 3 ? " (aim for at least 3)" : count > 5 ? " (trim to top 5)" : ""}`,
    });
  }

  // 3. No excessively long bullets
  let longBullets = 0;
  for (const s of sections) {
    const lines = s.content.split("\n");
    for (const line of lines) {
      if (
        (line.trim().startsWith("*") || line.trim().startsWith("-")) &&
        line.length > 150
      ) {
        longBullets++;
      }
    }
  }
  checks.push({
    id: "bullet_length",
    name: "Bullet length (<150 chars)",
    passed: longBullets === 0,
    message:
      longBullets === 0
        ? "All bullets concise"
        : `${longBullets} bullet(s) may be too long`,
  });

  // 4. Next Week items
  const nextWeek = sections.find(
    (s) => s.name === "Next Week" || s.name.toLowerCase().includes("next week")
  );
  if (nextWeek) {
    const nwBullets = nextWeek.content
      .split("\n")
      .filter((l) => l.trim().startsWith("*") || l.trim().startsWith("-"));
    checks.push({
      id: "nextweek_count",
      name: "Next Week: actionable items",
      passed: nwBullets.length > 0 || nextWeek.content.trim() === "None",
      message:
        nextWeek.content.trim() === "None"
          ? "No next-week items (OK if intentional)"
          : `${nwBullets.length} planned item(s)`,
    });
  }

  // 5. Data-driven check — look for numbers/metrics in summary
  if (summary) {
    const hasNumbers = /\d+/.test(summary.content);
    checks.push({
      id: "data_driven",
      name: "Data-driven summary",
      passed: hasNumbers,
      message: hasNumbers
        ? "Summary includes quantifiable data"
        : "Consider adding metrics (counts, percentages, time saved)",
    });
  }

  // 6. Empty sections check
  const emptySections = sections.filter(
    (s) => !s.content.trim() || s.content.trim().length < 4
  );
  checks.push({
    id: "no_empty",
    name: "No empty sections",
    passed: emptySections.length === 0,
    message:
      emptySections.length === 0
        ? 'All sections have content (or "None")'
        : `${emptySections.length} section(s) empty — write "None" if intentional`,
  });

  return checks;
}

// ===== Report Generation =====

export async function generateT5TReport(
  config: T5TConfig,
  dailyLogs: DailyLog[],
  meetings: Meeting[],
  notes: Note[],
  tasks: TaskItem[],
  periodStart: string,
  periodEnd: string,
): Promise<T5TReportSection[]> {
  const systemPrompt = buildSystemPrompt(config);
  const context = buildSourceContext(dailyLogs, meetings, notes, tasks, config);

  const startDate = new Date(periodStart).toLocaleDateString("en-US", {
    month: "2-digit",
    day: "2-digit",
    year: "2-digit",
  });
  const endDate = new Date(periodEnd).toLocaleDateString("en-US", {
    month: "2-digit",
    day: "2-digit",
    year: "2-digit",
  });

  const userPrompt = `Generate a T5T weekly report for the period ${startDate} to ${endDate}.

Here is the source data:

${context}

Generate the report following the template and T5T principles. Return JSON with the sections array.`;

  const result = await chatWithAI(
    [{ role: "user", content: userPrompt }],
    systemPrompt,
  );

  // Parse JSON response
  const cleaned = result
    .replace(/```json\n?/g, "")
    .replace(/```\n?/g, "")
    .trim();
  const parsed = JSON.parse(cleaned);

  const sections: T5TReportSection[] = [];
  const responseSections: { name: string; content: string }[] =
    parsed.sections || [];

  // Map response sections to template sections, ensuring all template sections exist
  for (const templateSection of config.reportTemplate) {
    const found = responseSections.find(
      (s) => s.name.toLowerCase() === templateSection.name.toLowerCase()
    );
    sections.push({
      id: templateSection.id,
      name: templateSection.name,
      content: found?.content || "None",
    });
  }

  return sections;
}

// ===== Markdown Builder =====

export function buildReportMarkdown(
  config: T5TConfig,
  sections: T5TReportSection[],
  periodStart: string,
  periodEnd: string,
): string {
  const { identity, emailSettings } = config;

  const startDate = new Date(periodStart).toLocaleDateString("en-US", {
    month: "2-digit",
    day: "2-digit",
  });
  const endDate = new Date(periodEnd).toLocaleDateString("en-US", {
    month: "2-digit",
    day: "2-digit",
  });

  const managerNames = identity.managers.map((m) => m.name).join(" and ");

  // Build greeting
  let greeting = emailSettings.greeting
    .replace("{{managers}}", managerNames || "Team")
    .replace("{{name}}", identity.name || "");

  // Build closing
  let closing = emailSettings.closing.replace(
    "{{name}}",
    identity.name || ""
  );

  const lines: string[] = [];
  lines.push(greeting);
  lines.push("");

  // Summary first (no bracket header)
  const summary = sections.find((s) => s.name === "Summary");
  if (summary) {
    lines.push("Summary:");
    lines.push(summary.content);
    lines.push("");
  }

  // Rest of sections with bracket headers
  for (const section of sections) {
    if (section.name === "Summary") continue;
    lines.push(`[${section.name}]`);
    lines.push(section.content);
    lines.push("");
  }

  lines.push(closing);

  return lines.join("\n");
}

// ===== Email Subject Builder =====

export function buildEmailSubject(
  config: T5TConfig,
  periodStart: string,
  periodEnd: string,
): string {
  const startDate = new Date(periodStart).toLocaleDateString("en-US", {
    month: "2-digit",
    day: "2-digit",
  });
  const endDate = new Date(periodEnd).toLocaleDateString("en-US", {
    month: "2-digit",
    day: "2-digit",
  });

  return config.emailSettings.subjectFormat
    .replace("{{start_date}}", startDate)
    .replace("{{end_date}}", endDate);
}
