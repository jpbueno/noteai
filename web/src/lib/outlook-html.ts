/**
 * Markdown to Outlook-compatible HTML converter.
 *
 * Ported from T5T skill's markdown_to_outlook_html.py to TypeScript.
 * Uses inline CSS only for Outlook's Word-based rendering engine.
 */

import type { T5TConfig } from "./types";

const LINK_STYLE = "color: #2b579a; text-decoration: underline;";

const TABLE_STYLE =
  "border-collapse: collapse; width: 100%; font-family: Calibri, Arial, sans-serif; " +
  "font-size: 11pt; margin-top: 8px; margin-bottom: 12px;";

const HEADER_CELL_STYLE =
  "background-color: #2b579a; color: #ffffff; font-weight: bold; " +
  "padding: 8px 10px; border: 1px solid #2b579a; text-align: left;";

const DAY_HEADER_STYLE =
  "background-color: #f0f4f8; font-weight: bold; " +
  "padding: 6px 10px; border: 1px solid #ddd; color: #000000;";

const CELL_STYLE = "padding: 6px 10px; border: 1px solid #ddd; color: #000000;";

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function convertMarkdownFormatting(
  text: string,
  config?: T5TConfig,
): string {
  // Convert markdown links [text](url)
  let result = text.replace(
    /\[([^\]]+)\]\(([^)]+)\)/g,
    `<a href="$2" style="${LINK_STYLE}">$1</a>`,
  );

  // Auto-link bare JIRA ticket IDs
  if (config?.jiraProjectKeys?.length) {
    const keys = config.jiraProjectKeys.map(escapeRegex).join("|");
    const pattern = new RegExp(
      `(?<!/)(?<!>)\\b(${keys})-(\\d+)\\b(?!</a>)`,
      "g",
    );
    result = result.replace(
      pattern,
      (match) =>
        `<a href="${config.jiraBaseUrl}/${match}" style="${LINK_STYLE}">${match}</a>`,
    );
  }

  // Auto-link bare NVBug IDs in [B] entries
  if (config?.nvbugBaseUrl) {
    result = result.replace(
      /\[B\]\s+(\d{7,})/g,
      (_, id) =>
        `[B] <a href="${config.nvbugBaseUrl}/${id}" style="${LINK_STYLE}">${id}</a>`,
    );
  }

  // Bold
  result = result.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  // Italic (not already part of **)
  result = result.replace(
    /(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g,
    "<em>$1</em>",
  );

  return result;
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function renderTableHtml(rows: string[], config?: T5TConfig): string {
  const lines: string[] = [`<table style="${TABLE_STYLE}">`];

  for (let idx = 0; idx < rows.length; idx++) {
    const cells = rows[idx]
      .replace(/^\|/, "")
      .replace(/\|$/, "")
      .split("|")
      .map((c) => c.trim());

    // Skip separator rows
    if (cells.every((c) => /^-+$/.test(c.trim()) || !c.trim())) continue;

    if (idx === 0) {
      // Header row
      lines.push("<tr>");
      for (const cell of cells) {
        const html = convertMarkdownFormatting(cell, config);
        lines.push(`<td style="${HEADER_CELL_STYLE}">${html}</td>`);
      }
      lines.push("</tr>");
    } else {
      const cellHtml = convertMarkdownFormatting(cells[0] || "", config);
      const isDayHeader = cellHtml.includes("<strong>");
      const style = isDayHeader ? DAY_HEADER_STYLE : CELL_STYLE;
      lines.push("<tr>");
      for (const cell of cells) {
        const html = convertMarkdownFormatting(cell, config);
        lines.push(`<td style="${style}">${html}</td>`);
      }
      lines.push("</tr>");
    }
  }

  lines.push("</table>");
  return lines.join("\n");
}

export function markdownToOutlookHtml(
  markdown: string,
  config?: T5TConfig,
): string {
  const lines = markdown.split("\n");
  const htmlLines: string[] = [];
  let inList = false;
  let inTable = false;
  let tableRows: string[] = [];
  let listIndent = 0;
  let skipNextBlank = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const lineEscaped = escapeHtml(line);

    // Table detection
    const isTableLine = /^\|.+\|$/.test(line.trim());
    if (isTableLine) {
      if (inList) {
        htmlLines.push("</ul>");
        inList = false;
      }
      if (!inTable) {
        inTable = true;
        tableRows = [];
      }
      tableRows.push(line.trim());
      continue;
    } else if (inTable) {
      htmlLines.push(renderTableHtml(tableRows, config));
      inTable = false;
      tableRows = [];
    }

    // Section headers [Projects], [Automation], etc.
    if (/^\[(.+?)\]$/.test(lineEscaped.trim())) {
      if (inList) {
        htmlLines.push("</ul>");
        inList = false;
      }
      const sectionText = convertMarkdownFormatting(lineEscaped, config);
      htmlLines.push(
        `<p style="color: #2b579a; font-family: Calibri, Arial, sans-serif; ` +
          `font-size: 12pt; font-weight: bold; margin-top: 14px; margin-bottom: 8px; ` +
          `margin-left: 0;">${sectionText}</p>`,
      );
      skipNextBlank = true;
      continue;
    }

    // Bug entries [B]
    if (lineEscaped.trim().startsWith("[B]")) {
      if (inList) {
        htmlLines.push("</ul>");
        inList = false;
      }
      let bugText = convertMarkdownFormatting(lineEscaped.trim(), config);
      htmlLines.push(
        `<p style="font-family: Calibri, Arial, sans-serif; font-size: 11pt; ` +
          `font-weight: bold; margin-top: 12px; margin-bottom: 4px; margin-left: 0; ` +
          `color: #c7254e;">${bugText}</p>`,
      );
      continue;
    }

    // Bullet points
    const bulletMatch = lineEscaped.match(/^(\s*)[*\-]\s+(.+)$/);
    if (bulletMatch) {
      const indent = bulletMatch[1].length;
      let text = bulletMatch[2];

      // Bold Impact:/Status: labels
      if (/^(Impact|Status):/.test(text)) {
        text = `<strong>${text}</strong>`;
      }
      text = convertMarkdownFormatting(text, config);

      if (!inList) {
        htmlLines.push(
          `<ul style="font-family: Calibri, Arial, sans-serif; font-size: 11pt; ` +
            `line-height: 1.5; margin-top: 4px; margin-bottom: 8px; padding-left: 20px;">`,
        );
        inList = true;
        listIndent = indent;
      } else if (indent > listIndent) {
        htmlLines.push(
          `<ul style="font-family: Calibri, Arial, sans-serif; font-size: 11pt; ` +
            `line-height: 1.5; margin-top: 4px; margin-bottom: 4px; padding-left: 20px;">`,
        );
        listIndent = indent;
      } else if (indent < listIndent) {
        htmlLines.push("</ul>");
        listIndent = indent;
      }

      htmlLines.push(
        `<li style="margin-bottom: 6px; color: #000000;">${text}</li>`,
      );
      continue;
    }

    // Non-bullet content
    if (inList) {
      htmlLines.push("</ul>");
      inList = false;
    }

    if (!line.trim()) {
      if (!skipNextBlank && i > 0 && i < lines.length - 1) {
        const nextLine = lines[i + 1]?.trim() || "";
        if (
          nextLine &&
          !nextLine.startsWith("#") &&
          !/^\[.+\]$/.test(nextLine)
        ) {
          htmlLines.push(
            '<p style="margin: 6px 0; font-size: 1pt;">&nbsp;</p>',
          );
        }
      }
      skipNextBlank = false;
    } else if (lineEscaped.trim()) {
      const text = convertMarkdownFormatting(lineEscaped, config);
      htmlLines.push(
        `<p style="font-family: Calibri, Arial, sans-serif; font-size: 11pt; ` +
          `margin-top: 4px; margin-bottom: 4px; margin-left: 0; ` +
          `color: #000000;">${text}</p>`,
      );
      skipNextBlank = false;
    }
  }

  if (inList) htmlLines.push("</ul>");
  if (inTable) htmlLines.push(renderTableHtml(tableRows, config));

  return htmlLines.join("\n");
}

export function createOutlookHtmlDocument(
  markdown: string,
  config?: T5TConfig,
): string {
  const htmlContent = markdownToOutlookHtml(markdown, config);

  return `<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <!--[if mso]>
    <noscript>
        <xml>
            <o:OfficeDocumentSettings>
                <o:PixelsPerInch>96</o:PixelsPerInch>
            </o:OfficeDocumentSettings>
        </xml>
    </noscript>
    <![endif]-->
</head>
<body style="font-family: Calibri, Arial, sans-serif; font-size: 11pt; color: #000000; background-color: #ffffff; margin: 0; padding: 20px;">
    <div style="max-width: 800px;">
        ${htmlContent}
    </div>
</body>
</html>`;
}
