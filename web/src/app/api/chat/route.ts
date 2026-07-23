import { NextRequest, NextResponse } from "next/server";
import { requireApiAuth } from "@/lib/api-auth";
import { getSettingValue } from "@/lib/server-db";
import {
  consumeUpstreamResponse,
  UpstreamAbortError,
} from "@/lib/upstream-abort";
import type { ConsumedUpstreamResponse } from "@/lib/upstream-abort";

const ENDPOINTS: Record<string, string> = {
  openrouter: "https://openrouter.ai/api/v1/chat/completions",
  anthropic: "https://api.anthropic.com/v1/messages",
  openai: "https://api.openai.com/v1/chat/completions",
  nvidia: "https://inference-api.nvidia.com/v1/chat/completions",
};

const MAX_CHAT_MESSAGES = 40;
const MAX_MESSAGE_CHARS = 12_000;
const MAX_CHAT_TOKENS = 4096;
const CHAT_UPSTREAM_TIMEOUT_MS = 60_000;

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? value as Record<string, unknown> : null;
}

function extractUpstreamError(upstreamText: string): string {
  try {
    const parsed = JSON.parse(upstreamText);
    const rawError = parsed?.error;
    if (typeof parsed?.detail === "string") return parsed.detail;
    if (typeof parsed?.message === "string") return parsed.message;
    if (typeof rawError === "string") return rawError;
    if (typeof rawError?.message === "string") return rawError.message;
    if (typeof rawError?.detail === "string") return rawError.detail;
  } catch {
    // Fall through to a bounded text snippet below.
  }
  return upstreamText.slice(0, 300);
}

function extractChatContent(provider: string, data: unknown): string {
  const root = asRecord(data);
  if (!root) return "";

  if (provider === "anthropic") {
    const content = Array.isArray(root.content) ? root.content : [];
    const first = asRecord(content[0]);
    return typeof first?.text === "string" ? first.text : "";
  }

  const choices = Array.isArray(root.choices) ? root.choices : [];
  const firstChoice = asRecord(choices[0]);
  const message = asRecord(firstChoice?.message);
  const content = message?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((item) => {
        if (typeof item === "string") return item;
        const contentPart = asRecord(item);
        if (typeof contentPart?.text === "string") return contentPart.text;
        if (typeof contentPart?.content === "string") return contentPart.content;
        return "";
      })
      .join("")
      .trim();
  }

  if (typeof root.content === "string") return root.content;
  if (typeof root.output_text === "string") return root.output_text;
  return "";
}

function supportsTemperature(provider: string, model: string): boolean {
  return !(provider === "nvidia" && model.startsWith("aws/anthropic/"));
}

export async function POST(request: NextRequest) {
  const authError = await requireApiAuth(request);
  if (authError) return authError;

  try {
    const { provider, model, messages, temperature = 0.3, maxTokens = 4096 } =
      await request.json();

    if (!provider || !Array.isArray(messages)) {
      return NextResponse.json(
        { error: "Missing required fields: provider, messages" },
        { status: 400 }
      );
    }
    if (messages.length > MAX_CHAT_MESSAGES) {
      return NextResponse.json({ error: "Too many messages" }, { status: 413 });
    }
    if (messages.some((m) => typeof m?.content !== "string" || m.content.length > MAX_MESSAGE_CHARS)) {
      return NextResponse.json({ error: "Message content is too large" }, { status: 413 });
    }
    const safeMaxTokens = Math.min(Math.max(Number(maxTokens) || 1024, 1), MAX_CHAT_TOKENS);

    const endpoint = ENDPOINTS[provider];
    if (!endpoint) {
      return NextResponse.json(
        { error: `Unknown provider: ${provider}` },
        { status: 400 }
      );
    }

    // Read API key server-side — never trust keys from the client
    const apiKey = await getSettingValue(`api_key_${provider}`);
    if (!apiKey) {
      return NextResponse.json(
        { error: `No API key configured for ${provider}. Go to Settings to add one.` },
        { status: 400 }
      );
    }

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };

    if (provider === "anthropic") {
      headers["x-api-key"] = apiKey;
      headers["anthropic-version"] = "2023-06-01";
    } else {
      headers["Authorization"] = `Bearer ${apiKey}`;
    }

    if (provider === "openrouter") {
      headers["HTTP-Referer"] = request.nextUrl.origin;
      headers["X-Title"] = "NoteAI Web";
    }

    let body: string;
    if (provider === "anthropic") {
      const systemMsg = messages.find(
        (m: { role: string }) => m.role === "system"
      );
      const otherMsgs = messages.filter(
        (m: { role: string }) => m.role !== "system"
      );
      body = JSON.stringify({
        model,
        max_tokens: safeMaxTokens,
        temperature,
        system: systemMsg?.content || "",
        messages: otherMsgs,
      });
    } else {
      const payload: Record<string, unknown> = {
        model,
        messages,
        max_tokens: safeMaxTokens,
      };
      if (supportsTemperature(provider, model)) {
        payload.temperature = temperature;
      }
      body = JSON.stringify(payload);
    }

    let upstream: ConsumedUpstreamResponse;
    try {
      upstream = await consumeUpstreamResponse(
        request.signal,
        CHAT_UPSTREAM_TIMEOUT_MS,
        async (signal) =>
          fetch(endpoint, {
            method: "POST",
            headers,
            body,
            signal,
          }),
      );
    } catch (error) {
      if (error instanceof UpstreamAbortError && error.abortCause === "timeout") {
        return NextResponse.json(
          { error: "LLM request timed out. Try again or choose a faster model." },
          { status: 504 },
        );
      }
      if (error instanceof UpstreamAbortError && error.abortCause === "request") {
        return NextResponse.json({ error: "Request cancelled" }, { status: 499 });
      }
      if (error instanceof Error && error.name === "AbortError") {
        return NextResponse.json(
          { error: "LLM request timed out. Try again or choose a faster model." },
          { status: 504 },
        );
      }
      throw error;
    }

    if (!upstream.ok) {
      const upstreamDetail = extractUpstreamError(upstream.text);
      return NextResponse.json(
        {
          error: `LLM request failed (${upstream.status})${
            upstreamDetail ? `: ${upstreamDetail}` : ""
          }`,
        },
        { status: upstream.status }
      );
    }

    const content = extractChatContent(provider, upstream.data);
    if (!content) {
      return NextResponse.json(
        { error: "LLM request returned an empty response." },
        { status: 502 },
      );
    }

    return NextResponse.json({ content });
  } catch {
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}
