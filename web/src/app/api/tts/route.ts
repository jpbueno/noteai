import { NextRequest, NextResponse } from "next/server";
import { requireApiAuth } from "@/lib/api-auth";
import { getSettingValue } from "@/lib/server-db";

const TTS_ENDPOINTS: Record<string, { url: string; model: string }> = {
  nvidia: {
    url: "https://inference-api.nvidia.com/v1/audio/speech",
    model: "openai/openai/gpt-4o-mini-tts",
  },
  openai: {
    url: "https://api.openai.com/v1/audio/speech",
    model: "gpt-4o-mini-tts",
  },
};

const MAX_TTS_CHARS = 4096;

export async function POST(request: NextRequest) {
  const authError = await requireApiAuth(request);
  if (authError) return authError;

  try {
    const { text, voice = "nova" } = await request.json();

    if (!text) {
      return NextResponse.json(
        { error: "Missing required field: text" },
        { status: 400 },
      );
    }
    if (typeof text !== "string" || text.length > MAX_TTS_CHARS) {
      return NextResponse.json({ error: "Text is too large" }, { status: 413 });
    }

    // Determine TTS provider and read API key server-side
    const llmProvider = (await getSettingValue("llm_provider")) || "openrouter";
    const ttsProvider = llmProvider === "nvidia" ? "nvidia" : "openai";
    let apiKey = await getSettingValue(`api_key_${ttsProvider}`);
    if (!apiKey) {
      apiKey = await getSettingValue(`api_key_${llmProvider}`);
    }

    if (!apiKey) {
      return NextResponse.json(
        { error: "No NVIDIA or OpenAI API key configured for TTS. Go to Settings to add one." },
        { status: 400 },
      );
    }

    const config = TTS_ENDPOINTS[ttsProvider] ?? TTS_ENDPOINTS.openai;

    const response = await fetch(config.url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: config.model,
        input: text,
        voice,
        response_format: "mp3",
      }),
    });

    if (!response.ok) {
      return NextResponse.json(
        { error: `TTS failed (${response.status})` },
        { status: response.status },
      );
    }

    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("json") || contentType.includes("text")) {
      return NextResponse.json(
        { error: "TTS returned unexpected response format" },
        { status: 502 },
      );
    }

    const audioBuffer = await response.arrayBuffer();

    return new NextResponse(audioBuffer, {
      headers: {
        "Content-Type": "audio/mpeg",
        "Content-Length": String(audioBuffer.byteLength),
      },
    });
  } catch {
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 },
    );
  }
}
