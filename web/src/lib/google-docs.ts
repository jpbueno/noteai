// Google Docs append-to-manager-log integration.
//
// Auth: service account (JSON credentials via GOOGLE_SERVICE_ACCOUNT_KEY env var).
// The service account email must be granted Editor access to the target doc.
// See web/GOOGLE_DOCS_SETUP.md for the one-time GCP setup.
//
// All network calls use fetch + Web Crypto (no googleapis package), so this
// runs on Node, Vercel Functions, and Cloudflare Workers (opennextjs-cloudflare).

const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const DOCS_API = "https://docs.googleapis.com/v1/documents";
const DOCS_SCOPE = "https://www.googleapis.com/auth/documents";

const MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export class GoogleDocsConfigError extends Error {}
export class GoogleDocsApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  token_uri?: string;
}

interface DocsParagraphElement {
  textRun?: { content?: string };
}

interface DocsParagraph {
  elements?: DocsParagraphElement[];
}

interface DocsStructuralElement {
  startIndex?: number;
  endIndex?: number;
  paragraph?: DocsParagraph;
}

interface DocsDocument {
  body?: { content?: DocsStructuralElement[] };
  title?: string;
}

export interface GoogleDocsConfig {
  serviceAccount: ServiceAccountKey;
  documentId: string;
}

export function loadConfig(): GoogleDocsConfig {
  const docId = process.env.GOOGLE_DOCS_MANAGER_DOC_ID;
  const saRaw = process.env.GOOGLE_SERVICE_ACCOUNT_KEY;
  if (!docId) {
    throw new GoogleDocsConfigError("GOOGLE_DOCS_MANAGER_DOC_ID is not set");
  }
  if (!saRaw) {
    throw new GoogleDocsConfigError("GOOGLE_SERVICE_ACCOUNT_KEY is not set");
  }
  let sa: ServiceAccountKey;
  try {
    sa = JSON.parse(saRaw);
  } catch {
    throw new GoogleDocsConfigError("GOOGLE_SERVICE_ACCOUNT_KEY is not valid JSON");
  }
  if (!sa.client_email || !sa.private_key) {
    throw new GoogleDocsConfigError("Service account JSON is missing client_email or private_key");
  }
  return { serviceAccount: sa, documentId: docId };
}

// ---------- Service-account JWT → access token ----------

function base64UrlEncode(bytes: Uint8Array | string): string {
  const bin = typeof bytes === "string"
    ? bytes
    : String.fromCharCode(...bytes);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importServiceAccountKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
}

async function getAccessToken(sa: ServiceAccountKey): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: sa.client_email,
    scope: DOCS_SCOPE,
    aud: sa.token_uri || TOKEN_ENDPOINT,
    exp: now + 3600,
    iat: now,
  };
  const signingInput = `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(JSON.stringify(claim))}`;
  const key = await importServiceAccountKey(sa.private_key);
  const sig = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    new TextEncoder().encode(signingInput)
  );
  const jwt = `${signingInput}.${base64UrlEncode(new Uint8Array(sig))}`;

  const res = await fetch(sa.token_uri || TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new GoogleDocsApiError(`Token exchange failed: ${body}`, res.status);
  }
  const data = (await res.json()) as { access_token?: string };
  if (!data.access_token) {
    throw new GoogleDocsApiError("Token exchange returned no access_token", 500);
  }
  return data.access_token;
}

// ---------- Doc fetch + parse ----------

async function getDocument(docId: string, accessToken: string): Promise<DocsDocument> {
  const res = await fetch(`${DOCS_API}/${encodeURIComponent(docId)}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new GoogleDocsApiError(`documents.get failed: ${body}`, res.status);
  }
  return (await res.json()) as DocsDocument;
}

function paragraphText(p: DocsParagraph | undefined): string {
  if (!p?.elements) return "";
  let out = "";
  for (const el of p.elements) {
    if (el.textRun?.content) out += el.textRun.content;
  }
  return out;
}

// The doc uses headers like "Apr 20, 2026" — plain paragraph text.
const DATE_HDR_RE = /^\s*([A-Z][a-z]{2})\s+(\d{1,2}),\s+(\d{4})\s*$/;

export function formatTodayHeader(d: Date = new Date()): string {
  return `${MONTHS_SHORT[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
}

function parseHeaderDate(text: string): Date | null {
  const m = text.match(DATE_HDR_RE);
  if (!m) return null;
  const monthIdx = MONTHS_SHORT.indexOf(m[1]);
  if (monthIdx < 0) return null;
  return new Date(parseInt(m[3], 10), monthIdx, parseInt(m[2], 10));
}

function dayKey(d: Date): number {
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
}

interface InsertPlan {
  // Index at which the new content should be inserted.
  insertIndex: number;
  // Whether an existing date header already matches the target date.
  sectionHeaderExists: boolean;
}

// Finds the chronologically correct insertion slot for a target date.
// The doc keeps date-headers roughly newest-first. Rules:
//   - target day == an existing header  → append under that header
//   - target day > every existing header → insert before the newest
//   - target day falls between two headers → insert before the first header
//     whose date is older than the target
//   - target day is older than all existing headers → insert before the
//     oldest existing header (keeps newest-first ordering; the older items
//     below the oldest header are the pre-existing MM/DD bullets inside a
//     single long section, which we don't touch)
//   - no headers at all → insert after the title/first structural element
function planInsertion(doc: DocsDocument, target: Date): InsertPlan {
  const content = doc.body?.content || [];
  const targetHeaderText = formatTodayHeader(target);
  const targetKey = dayKey(target);

  interface HdrInfo {
    text: string;
    date: Date;
    start: number;
    end: number;
  }
  const headers: HdrInfo[] = [];
  for (const el of content) {
    if (!el.paragraph) continue;
    const txt = paragraphText(el.paragraph).replace(/\n+$/, "").trim();
    const d = parseHeaderDate(txt);
    if (d) {
      headers.push({
        text: txt,
        date: d,
        start: el.startIndex ?? 1,
        end: el.endIndex ?? 1,
      });
    }
  }

  // Exact match → append under it.
  for (const h of headers) {
    if (h.text === targetHeaderText) {
      return { insertIndex: h.end, sectionHeaderExists: true };
    }
  }

  // First older header → target slots in above it.
  for (const h of headers) {
    if (dayKey(h.date) < targetKey) {
      return { insertIndex: h.start, sectionHeaderExists: false };
    }
  }

  // No headers at all → insert after the first structural element.
  if (headers.length === 0) {
    const fallbackIdx = content[1]?.startIndex ?? 1;
    return { insertIndex: fallbackIdx, sectionHeaderExists: false };
  }

  // Target is older than every existing header → slot in above the oldest.
  const oldest = headers[headers.length - 1];
  return { insertIndex: oldest.start, sectionHeaderExists: false };
}

// ---------- Public API ----------

export interface AppendResult {
  documentId: string;
  insertedHeader: boolean;
  insertIndex: number;
}

function buildBulletText(title: string, description?: string): string {
  const t = title.trim();
  const d = (description || "").replace(/\s+/g, " ").trim();
  if (!d) return t;
  // Collapse description to a single line, join with em-dash to match the
  // inline style used in the doc's older entries.
  return `${t} — ${d}`;
}

/**
 * Append a task to the manager's running Google Doc.
 *
 * Idempotency: callers must dedupe on their side (check a DB flag before
 * calling). This function does NOT inspect existing content for the same task
 * text, because the same text could legitimately repeat across days.
 *
 * Section header date: pass `opts.now` to use a specific date (for backfills
 * of older todos). Defaults to today.
 */
export async function appendTaskToManagerDoc(
  taskTitle: string,
  opts?: { now?: Date; description?: string }
): Promise<AppendResult> {
  const title = taskTitle.trim();
  if (!title) throw new GoogleDocsConfigError("Refusing to append empty task title");

  const cfg = loadConfig();
  const accessToken = await getAccessToken(cfg.serviceAccount);
  const doc = await getDocument(cfg.documentId, accessToken);

  const target = opts?.now ?? new Date();
  const sectionHeaderText = formatTodayHeader(target);
  const plan = planInsertion(doc, target);

  const requests: Record<string, unknown>[] = [];
  let cursor = plan.insertIndex;

  if (!plan.sectionHeaderExists) {
    const headerText = `${sectionHeaderText}\n`;
    requests.push({ insertText: { location: { index: cursor }, text: headerText } });
    cursor += headerText.length;
  }

  const taskText = `${buildBulletText(title, opts?.description)}\n`;
  const taskStart = cursor;
  const taskEnd = taskStart + taskText.length;
  requests.push({ insertText: { location: { index: taskStart }, text: taskText } });
  requests.push({
    createParagraphBullets: {
      range: { startIndex: taskStart, endIndex: taskEnd },
      bulletPreset: "BULLET_DISC_CIRCLE_SQUARE",
    },
  });

  const res = await fetch(`${DOCS_API}/${encodeURIComponent(cfg.documentId)}:batchUpdate`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ requests }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new GoogleDocsApiError(`documents.batchUpdate failed: ${body}`, res.status);
  }

  return {
    documentId: cfg.documentId,
    insertedHeader: !plan.sectionHeaderExists,
    insertIndex: plan.insertIndex,
  };
}

/** Lightweight connectivity check: fetch doc metadata without writing. */
export async function verifyAccess(): Promise<{ documentId: string; title: string }> {
  const cfg = loadConfig();
  const accessToken = await getAccessToken(cfg.serviceAccount);
  const doc = await getDocument(cfg.documentId, accessToken);
  return { documentId: cfg.documentId, title: doc.title || "(untitled)" };
}
