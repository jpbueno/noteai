import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  groupNotesBySpace,
  normalizeNoteSpace,
  UNASSIGNED_NOTE_SPACE,
} from "./src/lib/note-spaces.ts";

const makeNote = (id, title, space, createdDate = "2026-05-04T12:00:00.000Z") => ({
  id,
  title,
  content: "",
  tags: [],
  createdDate,
  modifiedDate: createdDate,
  sourceMeetingID: null,
  ...(space === undefined ? {} : { space }),
});

test("normalizes manual note space labels", () => {
  assert.equal(normalizeNoteSpace("  Roadmap  "), "Roadmap");
  assert.equal(normalizeNoteSpace(""), null);
  assert.equal(normalizeNoteSpace("   "), null);
  assert.equal(normalizeNoteSpace(null), null);
  assert.equal(normalizeNoteSpace(undefined), null);
});

test("groups notes by normalized space with unassigned notes still visible", () => {
  const notes = [
    makeNote("design-1", "Design spec", "Design"),
    makeNote("legacy-1", "Imported flat note", undefined),
    makeNote("roadmap-1", "Roadmap May", " Roadmap "),
    makeNote("blank-1", "Blank space note", " "),
    makeNote("design-2", "Design follow-up", "Design"),
  ];

  const groups = groupNotesBySpace(notes);

  assert.deepEqual(
    groups.map((group) => ({
      space: group.space,
      isUnassigned: group.isUnassigned,
      noteIds: group.notes.map((note) => note.id),
    })),
    [
      { space: "Design", isUnassigned: false, noteIds: ["design-1", "design-2"] },
      { space: "Roadmap", isUnassigned: false, noteIds: ["roadmap-1"] },
      { space: UNASSIGNED_NOTE_SPACE, isUnassigned: true, noteIds: ["legacy-1", "blank-1"] },
    ],
  );
});

test("notes persistence includes the optional space column", () => {
  const serverDb = readFileSync(new URL("./src/lib/server-db.ts", import.meta.url), "utf8");
  const schema = JSON.parse(readFileSync(new URL("./src/lib/turso-schema.json", import.meta.url), "utf8"));
  const notesCreateSql = schema.schema.find((sql) => sql.startsWith("CREATE TABLE IF NOT EXISTS notes "));
  const migrationIds = schema.migrations.map((migration) => migration.id);

  assert.match(serverDb, /notes:\s*\[[^\]]*"space"/s);
  assert.match(notesCreateSql, /space TEXT/);
  assert.ok(migrationIds.includes("notes-space"));
});
