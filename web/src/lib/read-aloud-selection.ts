type ReadableRoot = {
  contains(node: Node): boolean;
};

type SelectionLike = {
  rangeCount: number;
  anchorNode: Node | null;
  focusNode: Node | null;
  toString(): string;
};

type TiptapSelectionSource = {
  state?: {
    selection?: {
      empty?: boolean;
      from: number;
      to: number;
    };
    doc?: {
      textBetween(
        from: number,
        to: number,
        blockSeparator?: string,
        leafText?: string,
      ): string;
    };
  };
};

export function normalizeReadableSelection(
  text: string | null | undefined,
): string | null {
  const trimmed = text?.replace(/\u00a0/g, " ").replace(/\r\n?/g, "\n").trim();
  return trimmed ? trimmed : null;
}

export function readSelectedTextFromTiptap(
  editor: TiptapSelectionSource | null | undefined,
): string | null {
  const selection = editor?.state?.selection;
  const doc = editor?.state?.doc;
  if (!selection || !doc || selection.empty || selection.from === selection.to) {
    return null;
  }

  const from = Math.min(selection.from, selection.to);
  const to = Math.max(selection.from, selection.to);
  return normalizeReadableSelection(doc.textBetween(from, to, "\n", " "));
}

export function readSelectedTextWithin(
  root: ReadableRoot | null | undefined,
  selection: SelectionLike | null | undefined = getWindowSelection(),
): string | null {
  if (!root || !selection || selection.rangeCount === 0) return null;
  if (!nodeBelongsToRoot(root, selection.anchorNode)) return null;
  if (!nodeBelongsToRoot(root, selection.focusNode)) return null;
  return normalizeReadableSelection(selection.toString());
}

export function readSelectedTextFromActiveControl(
  root: ReadableRoot | null | undefined,
  activeElement: Element | null | undefined =
    typeof document === "undefined" ? null : document.activeElement,
): string | null {
  if (!root || !activeElement || !nodeBelongsToRoot(root, activeElement)) {
    return null;
  }

  const control = activeElement as Partial<HTMLInputElement & HTMLTextAreaElement>;
  if (
    typeof control.value !== "string" ||
    typeof control.selectionStart !== "number" ||
    typeof control.selectionEnd !== "number" ||
    control.selectionEnd <= control.selectionStart
  ) {
    return null;
  }

  return normalizeReadableSelection(
    control.value.slice(control.selectionStart, control.selectionEnd),
  );
}

export function readSelectedTextForReadAloud(options: {
  root?: ReadableRoot | null;
  editor?: TiptapSelectionSource | null;
}): string | null {
  return (
    readSelectedTextFromTiptap(options.editor) ??
    readSelectedTextFromActiveControl(options.root) ??
    readSelectedTextWithin(options.root)
  );
}

function getWindowSelection(): SelectionLike | null {
  if (typeof window === "undefined") return null;
  return window.getSelection();
}

function nodeBelongsToRoot(
  root: ReadableRoot,
  node: Node | null | undefined,
): boolean {
  if (!node) return false;
  return node === root || root.contains(node);
}
