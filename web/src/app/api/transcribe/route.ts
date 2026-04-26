import { NextRequest, NextResponse } from "next/server";
import { getSettingValue } from "@/lib/server-db";

// Whisper-compatible endpoints, tried in order
const WHISPER_CONFIGS = [
  {
    keyName: "api_key_groq",
    endpoint: "https://api.groq.com/openai/v1/audio/transcriptions",
    model: "whisper-large-v3-turbo",
  },
  {
    keyName: "api_key_openai",
    endpoint: "https://api.openai.com/v1/audio/transcriptions",
    model: "whisper-1",
  },
];

const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
const MAX_PROMPT_CHARS = 1_000;

export async function POST(request: NextRequest) {
  try {
    const formData = await request.formData();
    const file = formData.get("file") as Blob | null;
    const promptValue = formData.get("prompt");
    const prompt = typeof promptValue === "string" ? promptValue : null;

    if (!file) {
      return NextResponse.json(
        { error: "Missing required field: file" },
        { status: 400 }
      );
    }
    if (file.size > MAX_AUDIO_BYTES) {
      return NextResponse.json({ error: "Audio file is too large" }, { status: 413 });
    }
    const safePrompt = prompt?.slice(0, MAX_PROMPT_CHARS);

    // Read the file bytes once — re-appending the original File object to a new
    // FormData in Node.js can silently send an empty/corrupt body to upstream APIs.
    const fileBytes = await file.arrayBuffer();
    if (fileBytes.byteLength === 0) {
      return NextResponse.json(
        { error: "Audio file is empty" },
        { status: 400 }
      );
    }
    const fileBlob = new Blob([fileBytes], { type: file.type || "audio/webm" });

    const errors: string[] = [];

    for (const config of WHISPER_CONFIGS) {
      const apiKey = await getSettingValue(config.keyName);
      if (!apiKey) continue;

      const upstreamForm = new FormData();
      upstreamForm.append("file", fileBlob, "recording.webm");
      upstreamForm.append("model", config.model);
      upstreamForm.append("response_format", "json");
      upstreamForm.append("language", "en");
      if (safePrompt) upstreamForm.append("prompt", safePrompt);

      try {
        const response = await fetch(config.endpoint, {
          method: "POST",
          headers: { Authorization: `Bearer ${apiKey}` },
          body: upstreamForm,
        });

        if (response.ok) {
          const data = await response.json();
          return NextResponse.json({ text: data.text || "" });
        }

        const errBody = await response.text().catch(() => "");
        errors.push(`${config.model} (${response.status}): ${errBody.slice(0, 150)}`);
      } catch (err) {
        errors.push(`${config.model}: ${err instanceof Error ? err.message : "fetch failed"}`);
      }
    }

    if (errors.length === 0) {
      return NextResponse.json(
        { error: "No transcription API key configured. Add a Groq or OpenAI key in Settings." },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { error: `Transcription failed: ${errors.join(" | ")}` },
      { status: 502 }
    );
  } catch (err) {
    return NextResponse.json(
      { error: `Server error: ${err instanceof Error ? err.message : "unknown"}` },
      { status: 500 }
    );
  }
}
