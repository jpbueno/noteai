import assert from "node:assert/strict";
import test from "node:test";

import {
  normalizeReadableSelection,
  readSelectedTextFromTiptap,
  readSelectedTextWithin,
} from "./src/lib/read-aloud-selection.ts";

test("normalizes selected readable text", () => {
  assert.equal(normalizeReadableSelection("  Selected\n\n text  "), "Selected\n\n text");
  assert.equal(normalizeReadableSelection("   \n\t  "), null);
});

test("reads the selected Tiptap range before falling back to the full document", () => {
  const editor = {
    state: {
      selection: { empty: false, from: 6, to: 19 },
      doc: {
        textBetween(from, to, blockSeparator) {
          assert.equal(from, 6);
          assert.equal(to, 19);
          assert.equal(blockSeparator, "\n");
          return "selected words";
        },
      },
    },
  };

  assert.equal(readSelectedTextFromTiptap(editor), "selected words");
});

test("ignores empty Tiptap selections", () => {
  const editor = {
    state: {
      selection: { empty: true, from: 4, to: 4 },
      doc: {
        textBetween() {
          throw new Error("textBetween should not be called for an empty selection");
        },
      },
    },
  };

  assert.equal(readSelectedTextFromTiptap(editor), null);
});

test("reads DOM selections only when they belong to the active readable surface", () => {
  const insideNode = {};
  const outsideNode = {};
  const root = {
    contains(node) {
      return node === insideNode;
    },
  };

  const insideSelection = {
    rangeCount: 1,
    anchorNode: insideNode,
    focusNode: insideNode,
    toString() {
      return "only this sentence";
    },
  };

  const outsideSelection = {
    rangeCount: 1,
    anchorNode: outsideNode,
    focusNode: outsideNode,
    toString() {
      return "browser chrome text";
    },
  };

  assert.equal(readSelectedTextWithin(root, insideSelection), "only this sentence");
  assert.equal(readSelectedTextWithin(root, outsideSelection), null);
  assert.equal(readSelectedTextWithin(null, insideSelection), null);
});
