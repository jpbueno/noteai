import { NextRequest, NextResponse } from "next/server";
import { getSettingValue } from "@/lib/server-db";

const ENDPOINTS: Record<string, string> = {
  openrouter: "https://openrouter.ai/api/v1/chat/completions",
  anthropic: "https://api.anthropic.com/v1/messages",
  openai: "https://api.openai.com/v1/chat/completions",
  nvidia: "https://integrate.api.nvidia.com/v1/chat/completions",
};

const MAX_CHAT_MESSAGES = 40;
const MAX_MESSAGE_CHARS = 12_000;
const MAX_CHAT_TOKENS = 4096;

export async function POST(request: NextRequest) {
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
      body = JSON.stringify({
        model,
        messages,
        temperature,
        max_tokens: safeMaxTokens,
      });
    }

    const response = await fetch(endpoint, {
      method: "POST",
      headers,
      body,
    });

    if (!response.ok) {
      const upstreamText = await response.text();
      let upstreamDetail = "";
      try {
        const parsed = JSON.parse(upstreamText);
        upstreamDetail =
          typeof parsed?.detail === "string"
            ? parsed.detail
            : typeof parsed?.error === "string"
              ? parsed.error
              : "";
      } catch {
        upstreamDetail = "";
      }
      return NextResponse.json(
        {
          error: `LLM request failed (${response.status})${
            upstreamDetail ? `: ${upstreamDetail}` : ""
          }`,
        },
        { status: response.status }
      );
    }

    const data = await response.json();

    let content: string;
    if (provider === "anthropic") {
      content = data.content?.[0]?.text || "";
    } else {
      content = data.choices?.[0]?.message?.content || "";
    }

    return NextResponse.json({ content });
  } catch {
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}
