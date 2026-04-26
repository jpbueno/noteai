import { NextRequest, NextResponse } from "next/server";
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

export async function POST(request: NextRequest) {
  try {
    const { text, voice = "nova" } = await request.json();

    if (!text) {
      return NextResponse.json(
        { error: "Missing required field: text" },
        { status: 400 },
      );
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
        input: text.slice(0, 4096),
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
