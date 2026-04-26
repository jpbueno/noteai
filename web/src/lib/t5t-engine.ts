/**
 * T5T Generation Engine — "Top 5 Things" format
 *
 * Generates an outcome-focused weekly email following the format:
 *   Subject: Top 5 Things - {focus} | {region} | {roleShort}
 *
 *   Industry Business Development / Account Updates
 *   **{Outcome headline}**
 *   {Paragraph explaining what was delivered and the outcome/value}
 *   ... (4-5 items)
 *
 *   Future Plans
 *   - {short bullet}
 *   ... (3-5 bullets)
 *
 *   Thank you,
 *   {name} | {role}
 *   Email: {email}
 *   Mobile: {mobile}
 *
 * Only Todos/Tasks are used as input. Meetings and notes are ignored.
 */

import type {
  T5TConfig,
  T5TReportSection,
  TodoItem,
} from "./types";
import { chatWithAI } from "./ai";

// ===== System Prompt =====

function buildSystemPrompt(config: T5TConfig): string {
  const { identity } = config;

  return `You are JP Santana's writing assistant, drafting his weekly "Top 5 Things" (T5T) email following NVIDIA's T5T culture. Write in FIRST PERSON as JP.

## Writer
- Name: ${identity.name || "JP Santana"}
- Role: ${identity.role || "Senior Solutions Architect"}${identity.focus ? `\n- Focus: ${identity.focus}` : ""}${identity.region ? `\n- Region: ${identity.region}` : ""}

## Output Format — strict JSON
Return ONLY a JSON object with this exact shape (no markdown fences, no extra text):

{
  "accountUpdates": [
    { "headline": "Outcome-focused bold headline", "paragraph": "3-5 sentence paragraph explaining what was delivered and why it matters." }
  ],
  "futurePlans": [
    "Short concrete upcoming priority",
    "Another short priority"
  ]
}

## accountUpdates — 4-5 items (hard cap: 5)
Each item represents a meaningful outcome delivered this week. STRUCTURE each one as:

### Headline
- Starts with a strong past-tense action verb focused on the OUTCOME, not the activity:
  - "Enabled ..."
  - "Delivered ..."
  - "Expanded ..."
  - "Built ..."
  - "Unblocked ..."
  - "Accelerated ..."
- Names the specific capability, customer, partner, or tech when possible.
- ~10-18 words. Title case. No trailing period.

### Paragraph (3-5 sentences, one paragraph, no bullets)
Follow this EXACT 3-beat structure. Study the gold-standard example below carefully.

**Beat 1: Set the context (the "why" / the problem being solved)**
- Open with a short phrase that states the mission, need, or problem this work addressed.
- Patterns: "To {goal}, I {verb}...", "To {solve/enable/unblock X}, I...", "With {initiative/customer} needing {outcome}, I..."
- Keep the context framing POSITIVE and mission-focused. Do NOT dwell on internal challenges, blockers, or difficulties. Focus on what we were trying to enable.

**Beat 2: What was delivered (the "what" with specifics)**
- Name the deliverable concretely in first person: "I built...", "I deployed...", "I delivered...", "I presented...", "I onboarded...".
- Name the specific NVIDIA tech, version numbers, counts, tool names, repositories, meetings, customers, partners.
- Include HOW it works when useful (cadence, channels, outputs, integrations).

**Beat 3: Positive result / value (the "so what")**
- Close with the concrete outcome in positive framing: what it unlocks, eliminates, accelerates, aligns, or enables going forward.
- Patterns: "This eliminates...", "This ensures...", "This unblocks...", "This enables...", "This raises...", "This gives...".
- Connect to broader motions when natural (GTC alignment, managed inference roadmap, federal/air-gapped enablement, customer readiness, team scalability).

### Other paragraph rules
- Name NVIDIA tech specifically when relevant: Dynamo, NIM, NIM Operator, Triton, TensorRT-LLM, vLLM, SGLang, Grove, Planner, NIXL, KVBM, Nemotron, Virtuoso, Cadence JedAI, NVCF, AI Workbench, NeMo, GPU Operator, etc.
- Name customers, partners, and people when present in the source (Crusoe, Cadence, Palantir, etc.). Credit collaborators naturally.
- Active voice. First person ("I delivered", "I enabled", "I built"). No "we" unless the task description explicitly uses it.
- Concrete and specific. Avoid passive filler: "worked on", "helped with", "engaged with", "supported".
- Do NOT describe challenges, blockers, difficulties, or troubleshooting. Frame everything around positive delivery and results.

### GOLD-STANDARD EXAMPLE (study the rhythm and match it)
**Built Automated Agent to Keep the Inference Reference Architecture Continuously Updated**

To keep our Inference Reference Architecture always up to date, I built a fully unattended weekly Claude Code routine that automatically scans the 24 NVIDIA Inference Reference Architecture components, including Dynamo, TensorRT-LLM, GPU Operator, Triton, and NIXL, for new releases, CVEs, deprecations, and ecosystem changes. Every Monday morning, the agent posts structured Slack alerts to #inference-ra-maintenance with severity classifications, specific RA page links, and concrete proposed update text, requiring zero manual intervention. This eliminates the manual effort of tracking two dozen fast-moving components and ensures the RA stays current as the inference stack evolves.

Notice the three beats:
1. "To keep our Inference Reference Architecture always up to date," (context / why)
2. "I built a fully unattended weekly Claude Code routine that automatically scans the 24 NVIDIA Inference Reference Architecture components... Every Monday morning, the agent posts..." (what + specifics)
3. "This eliminates the manual effort of tracking two dozen fast-moving components and ensures the RA stays current..." (positive result / value)

## futurePlans — 3-5 items
- ONE line each, concrete and terse.
- Format: "{what}, {short qualifier}" — no full sentences, no paragraphs.
- Examples: "April Dynamo workshop (Planner + Grove), reusable package", "Crusoe support through GTC, repeatable guidance", "Cadence JedAI environment handover to engineering".

## Source rules
- Only use the todo list provided. Nothing else.
- Completed todos become accountUpdates (pick the 4-5 most substantive; skip trivial ones).
- Pending todos become futurePlans OR can be folded into accountUpdates if they represent in-flight work with meaningful partial outcomes.
- If a todo has thin detail, infer reasonable specifics but NEVER fabricate customer names, dates, or deliverables that aren't in the source.
- If fewer than 4 substantive completed todos exist, produce as many as you can (minimum 2).

## Tone (study this, match exactly)
- Professional, outcome-oriented, executive-readable.
- Every paragraph follows context → action → positive result.
- POSITIVE framing only. Do not describe blockers, setbacks, struggles, or troubleshooting. Frame everything as delivery and outcomes.
- Confident and concrete. Avoid hedging ("tried to", "attempted", "hoped to").
- Uses phrases like: "To {goal}, I {verb}...", "This eliminates...", "This ensures...", "This enables...", "This unblocks...", "directly responding to feedback that...", "so future deployments have a clearer reference".
- Acknowledges the bigger picture when natural: GTC, roadmap, managed inference, federal/air-gapped, enablement, continuous readiness.
- No emojis. No exclamation marks.

## PUNCTUATION — CRITICAL RULE (read twice)
NEVER use em-dashes (—) or en-dashes (–) anywhere in the output. These are AI-tells and this user explicitly bans them.

Forbidden: "components — Dynamo, TensorRT-LLM", "this was great — it enabled X".

Use instead:
- A period and new sentence: "...components. Dynamo, TensorRT-LLM..."
- A comma: "...components, Dynamo, TensorRT-LLM..."
- A colon: "...components: Dynamo, TensorRT-LLM..."
- Parentheses: "...components (Dynamo, TensorRT-LLM)..."
- A semicolon when joining two related clauses.

Regular hyphens inside hyphenated words ARE fine and should be used normally:
- "on-prem", "air-gapped", "low-latency", "end-to-end", "TensorRT-LLM", "TP-parallel", "high-priority", "real-time", "production-grade"

Double-check every paragraph before returning. If you see an em-dash (—) or en-dash (–), rewrite that sentence.

CRITICAL: Return ONLY the JSON object. No preamble, no markdown fences, no commentary.`;
}

// ===== Context Builder — Todos only =====

function buildSourceContext(todos: TodoItem[]): string {
  const parts: string[] = [];

  parts.push("# Tasks / Todos");
  parts.push("");

  const completed = todos.filter((t) => t.completed);
  const pending = todos.filter((t) => !t.completed);

  if (completed.length > 0) {
    parts.push("## Completed (use these as the basis for accountUpdates)");
    for (const t of completed) {
      const due = t.dueDate ? ` (due: ${t.dueDate})` : "";
      const created = t.createdDate ? ` (created: ${t.createdDate.slice(0, 10)})` : "";
      parts.push(`- [DONE] ${t.title || "Untitled"}${due}${created}${t.description ? "\n  Description: " + t.description : ""}`);
    }
    parts.push("");
  }

  if (pending.length > 0) {
    parts.push("## Pending / In-Progress (use these for futurePlans, or in-flight accountUpdates)");
    for (const t of pending) {
      const due = t.dueDate ? ` (due: ${t.dueDate})` : "";
      parts.push(`- [PENDING] ${t.title || "Untitled"}${due}${t.description ? "\n  Description: " + t.description : ""}`);
    }
    parts.push("");
  }

  if (todos.length === 0) {
    parts.push("(No todos available — generate minimal placeholder with clear 'Needs tasks' messaging.)");
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
  _config: T5TConfig,
): QualityCheck[] {
  const checks: QualityCheck[] = [];

  const accountUpdates = sections.find((s) => s.id === "account-updates" || s.name.toLowerCase().includes("account updates"));
  const futurePlans = sections.find((s) => s.id === "future-plans" || s.name.toLowerCase().includes("future plans"));

  // 1. Account updates count (by counting bold headlines)
  if (accountUpdates) {
    const boldHeadlines = (accountUpdates.content.match(/\*\*[^*]+\*\*/g) || []).length;
    checks.push({
      id: "updates_count",
      name: "Account Updates: 4-5 items",
      passed: boldHeadlines >= 3 && boldHeadlines <= 5,
      message: `${boldHeadlines} outcome item(s)${boldHeadlines < 3 ? " (aim for 4-5)" : boldHeadlines > 5 ? " (trim to top 5)" : ""}`,
    });
  }

  // 2. Headlines start with action verbs
  if (accountUpdates) {
    const headlines = (accountUpdates.content.match(/\*\*([^*]+)\*\*/g) || []).map((h) => h.replace(/\*\*/g, "").trim());
    const actionVerbs = /^(Enabled|Delivered|Expanded|Built|Unblocked|Accelerated|Launched|Completed|Drove|Established|Advanced|Shipped|Deployed)\b/i;
    const bad = headlines.filter((h) => !actionVerbs.test(h)).length;
    checks.push({
      id: "action_verbs",
      name: "Headlines lead with action verbs",
      passed: bad === 0,
      message: bad === 0 ? "All headlines start with outcome verbs" : `${bad} headline(s) don't lead with a strong verb`,
    });
  }

  // 3. Future plans count
  if (futurePlans) {
    const bullets = futurePlans.content
      .split("\n")
      .filter((l) => l.trim().startsWith("-") || l.trim().startsWith("*"));
    checks.push({
      id: "plans_count",
      name: "Future Plans: 3-5 items",
      passed: bullets.length >= 2 && bullets.length <= 5,
      message: `${bullets.length} plan(s)${bullets.length < 2 ? " (aim for 3-5)" : bullets.length > 5 ? " (trim to top 5)" : ""}`,
    });
  }

  // 4. Paragraphs are substantive (>= 3 sentences roughly)
  if (accountUpdates) {
    const paragraphs = accountUpdates.content
      .split(/\n\s*\n/)
      .filter((p) => p.trim() && !p.trim().startsWith("**"));
    const thin = paragraphs.filter((p) => {
      const sentenceCount = (p.match(/[.!?]+\s/g) || []).length;
      return sentenceCount < 2;
    }).length;
    checks.push({
      id: "paragraph_depth",
      name: "Paragraphs are substantive",
      passed: thin === 0,
      message: thin === 0 ? "All paragraphs have real substance" : `${thin} paragraph(s) feel thin`,
    });
  }

  // 5. No bullets inside account updates (should be paragraph form)
  if (accountUpdates) {
    const bulletLines = accountUpdates.content
      .split("\n")
      .filter((l) => l.trim().startsWith("-") || l.trim().startsWith("*"))
      .filter((l) => !l.includes("**")); // allow bold
    checks.push({
      id: "no_bullets",
      name: "Account Updates use paragraphs, not bullets",
      passed: bulletLines.length === 0,
      message: bulletLines.length === 0 ? "Clean paragraph form" : `${bulletLines.length} bullet line(s), should be paragraphs`,
    });
  }

  // 6. No em-dashes or en-dashes (user bans them as AI-tells)
  const combined = sections.map((s) => s.content).join("\n");
  const dashCount = (combined.match(/[—–]/g) || []).length;
  checks.push({
    id: "no_dashes",
    name: "No em-dashes or en-dashes",
    passed: dashCount === 0,
    message: dashCount === 0 ? "Clean punctuation" : `${dashCount} forbidden dash(es) found`,
  });

  // 7. Paragraphs open with a context/problem framing (e.g. "To X, I Y...", "With X...", "For X...")
  if (accountUpdates) {
    const paragraphs = accountUpdates.content
      .split(/\n\s*\n/)
      .map((p) => p.trim())
      .filter((p) => p && !p.startsWith("**"));
    const contextOpeners = /^(To\s|With\s|For\s|Following\s|After\s|Ahead of\s|In support of\s|In response to\s|Responding to\s)/i;
    const weakOpeners = paragraphs.filter((p) => !contextOpeners.test(p)).length;
    checks.push({
      id: "context_first",
      name: "Paragraphs open with context (To X / With X / For X)",
      passed: weakOpeners === 0,
      message: weakOpeners === 0
        ? "All paragraphs lead with the 'why'"
        : `${weakOpeners} paragraph(s) jump straight to the action`,
    });
  }

  // 8. Paragraphs close with a positive result statement
  if (accountUpdates) {
    const paragraphs = accountUpdates.content
      .split(/\n\s*\n/)
      .map((p) => p.trim())
      .filter((p) => p && !p.startsWith("**"));
    const resultClosers = /(This\s+(eliminates|ensures|enables|unblocks|accelerates|raises|gives|delivers|equips|aligns|positions|sets up|establishes|frees|lets|allows)|\bso\s+(that\s+)?(we|the\s+team|future|customers))/i;
    const weakClosers = paragraphs.filter((p) => !resultClosers.test(p)).length;
    checks.push({
      id: "result_last",
      name: "Paragraphs close with a positive result",
      passed: weakClosers <= 1,
      message: weakClosers === 0
        ? "All paragraphs land on a clear outcome"
        : `${weakClosers} paragraph(s) miss the 'so what'`,
    });
  }

  return checks;
}

// ===== Report Generation =====

interface GeneratedPayload {
  accountUpdates: { headline: string; paragraph: string }[];
  futurePlans: string[];
}

export async function generateT5TReport(
  config: T5TConfig,
  todos: TodoItem[],
  _meetingsUnused: unknown[],
  _notesUnused: unknown[],
  periodStart: string,
  periodEnd: string,
): Promise<T5TReportSection[]> {
  const systemPrompt = buildSystemPrompt(config);
  const context = buildSourceContext(todos);

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

  const userPrompt = `Generate the Top 5 Things email for the period ${startDate} to ${endDate}.

Source todos:

${context}

Return the JSON object with accountUpdates and futurePlans as specified.`;

  const result = await chatWithAI(
    [{ role: "user", content: userPrompt }],
    systemPrompt,
  );

  // Parse JSON
  const cleaned = result.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
  let parsed: GeneratedPayload;
  try {
    parsed = JSON.parse(cleaned);
  } catch {
    // Try to extract JSON object if the model added any wrapper text
    const match = cleaned.match(/\{[\s\S]*\}/);
    if (!match) throw new Error("LLM did not return valid JSON");
    parsed = JSON.parse(match[0]);
  }

  // Safety net: strip em-dashes and en-dashes the LLM may have slipped in,
  // since they're a clear AI-tell the user bans. Replace with commas or periods
  // depending on surrounding context.
  const stripDashes = (s: string): string => {
    return s
      // " — " or " – " between clauses becomes ", "
      .replace(/\s+[—–]\s+/g, ", ")
      // em-dash or en-dash flush against a word becomes a simple comma
      .replace(/[—–]/g, ",")
      // collapse any accidental ", ," pairs
      .replace(/,\s*,/g, ",")
      // collapse any accidental double-commas with spacing
      .replace(/\s{2,}/g, " ")
      .trim();
  };

  // Build section contents
  const accountUpdatesContent = (parsed.accountUpdates || [])
    .map((u) => `**${stripDashes(u.headline)}**\n\n${stripDashes(u.paragraph)}`)
    .join("\n\n");

  const futurePlansContent = (parsed.futurePlans || [])
    .map((p) => `- ${stripDashes(p)}`)
    .join("\n");

  // Return in section shape for backwards compat with the composer UI
  return [
    {
      id: "account-updates",
      name: "Industry Business Development / Account Updates",
      content: accountUpdatesContent || "(No completed work available to report.)",
    },
    {
      id: "future-plans",
      name: "Future Plans",
      content: futurePlansContent || "- (No pending priorities captured.)",
    },
  ];
}

// ===== Markdown Builder — matches the Top 5 Things email format =====
//
// Output structure (drives both the markdown preview and the Outlook HTML):
//
//   ## Industry Business Development / Account Updates
//
//   **Outcome Headline**
//
//   - Paragraph for this account update.
//
//   **Next Outcome Headline**
//
//   - Paragraph.
//
//   ## Future Plans
//
//   - Short plan 1
//   - Short plan 2
//
//   Thank you,
//    \n JP Santana | Senior Solutions Architect ...

export function buildReportMarkdown(
  config: T5TConfig,
  sections: T5TReportSection[],
  _periodStart: string,
  _periodEnd: string,
): string {
  const { identity, emailSettings } = config;

  const accountUpdates = sections.find(
    (s) => s.id === "account-updates" || s.name.toLowerCase().includes("account updates"),
  );
  const futurePlans = sections.find(
    (s) => s.id === "future-plans" || s.name.toLowerCase().includes("future plans"),
  );

  const closing = (emailSettings.closing || "")
    .replace("{{name}}", identity.name || "")
    .replace("{{role}}", identity.role || "")
    .replace("{{email}}", identity.email || "")
    .replace("{{mobile}}", identity.mobile || "");

  const lines: string[] = [];

  // Section 1: Account Updates
  lines.push("## Industry Business Development / Account Updates");
  lines.push("");

  if (accountUpdates?.content.trim()) {
    // Engine stores each update as `**Headline**\n\nParagraph text`.
    // Convert each "Paragraph" line under a headline into a bulleted paragraph
    // so it lands in Outlook as a nested bullet under the bold headline.
    const blocks = accountUpdates.content.split(/\n\s*\n/);
    for (const block of blocks) {
      const trimmed = block.trim();
      if (!trimmed) continue;
      if (trimmed.startsWith("**") && trimmed.endsWith("**") && !trimmed.includes("\n")) {
        // Bold headline line
        lines.push(trimmed);
        lines.push("");
      } else if (trimmed.startsWith("-") || trimmed.startsWith("*")) {
        // Already a bullet — keep as-is
        lines.push(trimmed);
        lines.push("");
      } else {
        // Paragraph body → render as bullet under the preceding headline
        lines.push(`- ${trimmed.replace(/\n/g, " ")}`);
        lines.push("");
      }
    }
  }

  // Section 2: Future Plans
  lines.push("## Future Plans");
  lines.push("");
  if (futurePlans?.content.trim()) {
    lines.push(futurePlans.content.trim());
  }
  lines.push("");

  if (closing.trim()) {
    lines.push(closing);
  }

  return lines.join("\n").trim() + "\n";
}

// ===== Email Subject Builder =====

export function buildEmailSubject(
  config: T5TConfig,
  _periodStart: string,
  _periodEnd: string,
): string {
  const { identity } = config;
  const format = config.emailSettings.subjectFormat || "Top 5 Things - {{focus}} | {{region}} | {{roleShort}}";
  return format
    .replace("{{focus}}", identity.focus || "")
    .replace("{{region}}", identity.region || "")
    .replace("{{roleShort}}", identity.roleShort || "SA")
    .replace(/\s*\|\s*\|/g, " |") // clean up empty segments
    .replace(/-\s*\|/g, "-")
    .replace(/\|\s*$/, "")
    .trim();
}
