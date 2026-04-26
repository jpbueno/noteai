/**
 * Markdown ↔ HTML conversion for the Notion-style editor.
 *
 * Storage format is always Markdown. Tiptap works with HTML internally,
 * so we convert on load (md → html) and on save (html → md).
 */

import { marked } from "marked";

// ── Markdown → HTML (load) ──────────────────────────────────────────

marked.setOptions({ gfm: true, breaks: false });

function isAlreadyHtml(content: string): boolean {
  return /<(p|div|h[1-6]|ul|ol|blockquote|pre)\b/i.test(content);
}

export function mdToHtml(content: string | null | undefined): string {
  if (!content?.trim()) return "";
  // Strip Mac-app custom-scheme images the web app can't resolve
  const c = content.replace(
    /<img[^>]*src="noteai-image:\/\/[^"]*"[^>]*\/?>/gi,
    "",
  );
  // If content is already HTML (e.g. legacy save), pass through
  if (isAlreadyHtml(c)) return c;
  return marked.parse(c, { async: false }) as string;
}

// ── HTML → Markdown (save) ──────────────────────────────────────────

let _td: InstanceType<typeof import("turndown")> | null = null;

async function getTurndown() {
  if (_td) return _td;
  const mod = await import("turndown");
  const TurndownService = mod.default ?? mod;
  _td = new TurndownService({
    headingStyle: "atx",
    hr: "---",
    bulletListMarker: "-",
    codeBlockStyle: "fenced",
    emDelimiter: "*",
    strongDelimiter: "**",
  });
  // Underline → keep as <u> since markdown has no native underline
  _td.addRule("underline", {
    filter: ["u"],
    replacement: (c) => `<u>${c}</u>`,
  });
  // Images with resize/align metadata → keep as <img> tag
  _td.addRule("customImage", {
    filter: (node) =>
      node.nodeName === "IMG" &&
      !!(
        node.getAttribute("data-width") || node.getAttribute("data-align")
      ),
    replacement: (_c, node) => {
      const el = node as HTMLElement;
      const parts: string[] = [];
      for (const a of ["src", "alt", "data-width", "data-align"]) {
        const v = el.getAttribute(a);
        if (v) parts.push(`${a}="${v}"`);
      }
      const w = el.getAttribute("data-width");
      if (w) parts.push(`style="width: ${w}px"`);
      return `\n\n<img ${parts.join(" ")} />\n\n`;
    },
  });
  return _td;
}

export async function htmlToMd(html: string): Promise<string> {
  if (!html?.trim()) return "";
  const td = await getTurndown();
  return td.turndown(html).trim();
}

// ── Plain text extraction (for TTS) ─────────────────────────────────

export function htmlToPlainText(html: string): string {
  return html
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|h[1-6]|li|div|blockquote)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
