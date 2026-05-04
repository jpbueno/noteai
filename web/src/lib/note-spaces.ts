import type { Note } from "./types";

export const UNASSIGNED_NOTE_SPACE = "Unassigned";

export interface NoteSpaceGroup {
  space: string;
  notes: Note[];
  isUnassigned: boolean;
}

export function normalizeNoteSpace(space: string | null | undefined): string | null {
  const trimmed = space?.trim();
  return trimmed ? trimmed : null;
}

export function noteSpaceDisplayName(space: string | null | undefined): string {
  return normalizeNoteSpace(space) ?? UNASSIGNED_NOTE_SPACE;
}

export function groupNotesBySpace(notes: readonly Note[]): NoteSpaceGroup[] {
  const groups = new Map<string, NoteSpaceGroup>();

  for (const note of notes) {
    const normalizedSpace = normalizeNoteSpace(note.space);
    const isUnassigned = normalizedSpace === null;
    const key = isUnassigned ? "__unassigned__" : `space:${normalizedSpace}`;
    const existing = groups.get(key);

    if (existing) {
      existing.notes.push(note);
    } else {
      groups.set(key, {
        space: normalizedSpace ?? UNASSIGNED_NOTE_SPACE,
        notes: [note],
        isUnassigned,
      });
    }
  }

  return Array.from(groups.values()).sort((a, b) => {
    if (a.isUnassigned && !b.isUnassigned) return 1;
    if (!a.isUnassigned && b.isUnassigned) return -1;
    return a.space.localeCompare(b.space, undefined, { sensitivity: "base" });
  });
}
