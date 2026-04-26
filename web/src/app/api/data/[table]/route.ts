import { NextRequest, NextResponse } from "next/server";
import { getAll, getById, upsert, remove, clearTable, bulkUpsert } from "@/lib/server-db";

const VALID = ["meetings", "notes", "tasks", "t5tReports", "dailyLogs", "chatMessages", "todos", "settings"];

type Params = { params: Promise<{ table: string }> };

export async function GET(request: NextRequest, { params }: Params) {
  const { table } = await params;
  if (!VALID.includes(table)) {
    return NextResponse.json({ error: "Invalid table" }, { status: 400 });
  }
  try {
    const id = request.nextUrl.searchParams.get("id");
    if (id) {
      const row = await getById(table, id);
      return NextResponse.json(row || null);
    }
    const rows = await getAll(table);
    return NextResponse.json(rows);
  } catch {
    return NextResponse.json({ error: "Operation failed" }, { status: 500 });
  }
}

export async function POST(request: NextRequest, { params }: Params) {
  const { table } = await params;
  if (!VALID.includes(table)) {
    return NextResponse.json({ error: "Invalid table" }, { status: 400 });
  }
  try {
    const body = await request.json();
    if (Array.isArray(body)) {
      await bulkUpsert(table, body);
    } else {
      await upsert(table, body);
    }
    return NextResponse.json({ ok: true });
  } catch {
    return NextResponse.json({ error: "Operation failed" }, { status: 500 });
  }
}

export async function DELETE(request: NextRequest, { params }: Params) {
  const { table } = await params;
  if (!VALID.includes(table)) {
    return NextResponse.json({ error: "Invalid table" }, { status: 400 });
  }
  try {
    const id = request.nextUrl.searchParams.get("id");
    if (id) {
      await remove(table, id);
    } else {
      // Bulk delete requires explicit confirmation
      const confirm = request.nextUrl.searchParams.get("confirm");
      if (confirm !== "true") {
        return NextResponse.json(
          { error: "Bulk delete requires ?confirm=true" },
          { status: 400 }
        );
      }
      await clearTable(table);
    }
    return NextResponse.json({ ok: true });
  } catch {
    return NextResponse.json({ error: "Operation failed" }, { status: 500 });
  }
}
