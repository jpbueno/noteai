import { NextRequest, NextResponse } from "next/server";
import { getSettingValue, setSettingValue, isValidSettingKey } from "@/lib/server-db";

export async function GET(request: NextRequest) {
  const key = request.nextUrl.searchParams.get("key");
  if (!key) return NextResponse.json({ error: "key required" }, { status: 400 });
  if (!isValidSettingKey(key)) return NextResponse.json({ error: "Invalid setting key" }, { status: 400 });
  const value = await getSettingValue(key);
  return NextResponse.json({ value: value ?? null });
}

export async function POST(request: NextRequest) {
  const { key, value } = await request.json();
  if (!key) return NextResponse.json({ error: "key required" }, { status: 400 });
  if (!isValidSettingKey(key)) return NextResponse.json({ error: "Invalid setting key" }, { status: 400 });
  await setSettingValue(key, value ?? "");
  return NextResponse.json({ ok: true });
}
