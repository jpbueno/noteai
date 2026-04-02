import { NextRequest, NextResponse } from "next/server";
import { getAll, getById } from "@/lib/server-db";

const STOPWORDS = new Set([
  "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of",
  "with", "by", "from", "is", "it", "this", "that", "was", "are", "be", "has",
  "had", "have", "will", "would", "could", "should", "may", "might", "can",
  "do", "did", "not", "no", "so", "if", "we", "you", "they", "he", "she",
  "my", "your", "our", "their", "its", "all", "just", "about", "up", "out",
  "new", "one", "two", "also", "been", "some", "than", "more", "very", "what",
  "when", "how", "who", "which", "there", "then", "them", "these", "those",
  "get", "got", "going", "need", "know", "think", "like", "yeah", "yes",
  "meeting", "note", "task", "report", "top", "things",
]);

function extractTerms(item: Record<string, unknown>, type: string): string[] {
  const terms = new Set<string>();

  // Use structured metadata first (topics, tags)
  if (type === "meeting") {
    const summary = item.summary as { topics?: string[]; decisions?: string[] } | undefined;
    if (summary?.topics) summary.topics.forEach((t: string) => terms.add(t.toLowerCase()));
  }

  if (type === "note" || type === "task") {
    const tags = item.tags as string[] | undefined;
    if (tags) tags.forEach((t: string) => terms.add(t.toLowerCase()));
  }

  // Extract significant words from title (2+ chars, not stopwords)
  const title = (item.title as string) || "";
  title.split(/\s+/).forEach((w) => {
    const clean = w.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (clean.length >= 3 && !STOPWORDS.has(clean)) {
      terms.add(clean);
    }
  });

  return [...terms].filter((t) => t.length >= 3);
}

function getSearchableText(item: Record<string, unknown>, type: string): string {
  const parts: string[] = [];
  parts.push(String(item.title || ""));

  if (type === "meeting") {
    const summary = item.summary as { decisions?: string[]; topics?: string[]; openQuestions?: string[]; actionItems?: { task: string }[] } | undefined;
    if (summary) {
      if (summary.decisions) parts.push(summary.decisions.join(" "));
      if (summary.topics) parts.push(summary.topics.join(" "));
      if (summary.openQuestions) parts.push(summary.openQuestions.join(" "));
      if (summary.actionItems) parts.push(summary.actionItems.map((a) => a.task).join(" "));
    }
    const transcript = item.transcript as { text: string }[] | undefined;
    if (transcript) parts.push(transcript.map((s) => s.text).join(" "));
  } else if (type === "note") {
    parts.push(String(item.content || ""));
    const tags = item.tags as string[] | undefined;
    if (tags) parts.push(tags.join(" "));
  } else if (type === "task") {
    parts.push(String(item.description || ""));
    const tags = item.tags as string[] | undefined;
    if (tags) parts.push(tags.join(" "));
  } else if (type === "t5t") {
    const sections = item.sections as { insights?: { headline: string; explanation: string }[]; accountUpdates?: { headline: string; explanation: string }[]; futurePlans?: { headline: string; explanation: string }[] } | undefined;
    if (sections) {
      for (const entries of [sections.insights, sections.accountUpdates, sections.futurePlans]) {
        if (entries) entries.forEach((e) => { parts.push(e.headline); parts.push(e.explanation); });
      }
    }
  }

  return parts.join(" ").toLowerCase();
}

export async function GET(request: NextRequest) {
  try {
    const type = request.nextUrl.searchParams.get("type");
    const id = request.nextUrl.searchParams.get("id");

    if (!type || !id) {
      return NextResponse.json({ error: "type and id required" }, { status: 400 });
    }

    const tableMap: Record<string, string> = { meeting: "meetings", note: "notes", task: "tasks", t5t: "t5tReports" };
    const table = tableMap[type];
    if (!table) {
      return NextResponse.json({ error: "Invalid type" }, { status: 400 });
    }

    const item = await getById(table, id);
    if (!item) {
      return NextResponse.json({ error: "Item not found" }, { status: 404 });
    }

    const terms = extractTerms(item, type);
    if (terms.length === 0) {
      return NextResponse.json({ meetings: [], notes: [], tasks: [], t5tReports: [] });
    }

    // Fetch all items and search for matches
    const [allMeetings, allNotes, allTasks, allT5T] = await Promise.all([
      getAll("meetings"), getAll("notes"), getAll("tasks"), getAll("t5tReports"),
    ]);

    const search = (items: Record<string, unknown>[], itemType: string) => {
      return items
        .filter((i) => !(itemType === type && i.id === id)) // exclude self
        .map((i) => {
          const text = getSearchableText(i, itemType);
          const matched = terms.filter((t) => text.includes(t));
          if (matched.length === 0) return null;
          return {
            id: i.id as string,
            type: itemType,
            title: (i.title as string) || "Untitled",
            date: (i.date || i.createdDate || "") as string,
            matchedTerms: matched,
          };
        })
        .filter(Boolean)
        .sort((a, b) => (b!.matchedTerms.length - a!.matchedTerms.length));
    };

    return NextResponse.json({
      meetings: search(allMeetings, "meeting"),
      notes: search(allNotes, "note"),
      tasks: search(allTasks, "task"),
      t5tReports: search(allT5T, "t5t"),
    });
  } catch {
    return NextResponse.json({ error: "Failed to compute backlinks" }, { status: 500 });
  }
}
