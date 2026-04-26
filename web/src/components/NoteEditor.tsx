"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { useEditor, EditorContent } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import Placeholder from "@tiptap/extension-placeholder";
import { Tag, X, Loader2, Code2 } from "lucide-react";
import type { Note } from "@/lib/types";
import { db } from "@/lib/db";
import { formatDateTime, triggerRefresh } from "@/lib/hooks";
import { useTTS } from "@/lib/tts";
import { TTSPlayer, ReadAloudButton } from "@/components/TTSPlayer";
import { ResizableImage } from "@/components/extensions/ResizableImage";
import { mdToHtml, htmlToMd, htmlToPlainText } from "@/lib/content-utils";
import EditorToolbar from "@/components/EditorToolbar";

interface NoteEditorProps {
  note: Note;
}

export default function NoteEditor({ note }: NoteEditorProps) {
  const tts = useTTS();
  const [title, setTitle] = useState(note.title);
  const [tags, setTags] = useState(note.tags);
  const [tagInput, setTagInput] = useState("");
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [showSource, setShowSource] = useState(false);
  const [sourceMd, setSourceMd] = useState("");

  const prevIdRef = useRef(note.id);
  const saveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const titleRef = useRef(title);
  const tagsRef = useRef(tags);
  const insertImageRef = useRef<(file: File) => void>(() => {});

  useEffect(() => {
    titleRef.current = title;
  }, [title]);
  useEffect(() => {
    tagsRef.current = tags;
  }, [tags]);

  // Convert editor HTML → markdown, then persist
  const performSave = useCallback(async (editorHtml: string) => {
    setSaving(true);
    try {
      const markdown = await htmlToMd(editorHtml);
      await db.notes.update(prevIdRef.current, {
        title: titleRef.current,
        content: markdown,
        tags: tagsRef.current,
        modifiedDate: new Date().toISOString(),
      });
      triggerRefresh();
      setDirty(false);
    } finally {
      setSaving(false);
    }
  }, []);

  const performSaveRef = useRef(performSave);
  performSaveRef.current = performSave;

  const scheduleSave = useCallback((html: string) => {
    if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
    saveTimerRef.current = setTimeout(
      () => performSaveRef.current(html),
      1200,
    );
  }, []);

  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        heading: { levels: [1, 2] },
        link: {
          openOnClick: false,
          HTMLAttributes: { class: "editor-link" },
        },
      }),
      Placeholder.configure({ placeholder: "Start writing..." }),
      ResizableImage,
    ],
    content: mdToHtml(note.content),
    immediatelyRender: false,
    editorProps: {
      attributes: { class: "tiptap-editor outline-none min-h-[400px]" },
      handleDrop: (_view, event) => {
        const files = event.dataTransfer?.files;
        if (files?.length) {
          for (const file of Array.from(files)) {
            if (file.type.startsWith("image/")) {
              event.preventDefault();
              insertImageRef.current(file);
              return true;
            }
          }
        }
        return false;
      },
      handlePaste: (_view, event) => {
        const items = event.clipboardData?.items;
        if (items) {
          for (const item of Array.from(items)) {
            if (item.type.startsWith("image/")) {
              event.preventDefault();
              const file = item.getAsFile();
              if (file) insertImageRef.current(file);
              return true;
            }
          }
        }
        return false;
      },
    },
  });

  // Keep source markdown up-to-date when panel is open
  const showSourceRef = useRef(showSource);
  showSourceRef.current = showSource;

  useEffect(() => {
    if (!editor) return;
    const handler = () => {
      setDirty(true);
      const html = editor.getHTML();
      scheduleSave(html);
      if (showSourceRef.current) {
        htmlToMd(html).then(setSourceMd);
      }
    };
    editor.on("update", handler);
    return () => {
      editor.off("update", handler);
    };
  }, [editor, scheduleSave]);

  useEffect(() => {
    if (!editor) return;
    insertImageRef.current = async (file: File) => {
      const dataUrl = await compressImage(file);
      editor.chain().focus().setImage({ src: dataUrl }).run();
    };
  }, [editor]);

  // Note switching
  useEffect(() => {
    if (!editor) return;
    if (prevIdRef.current !== note.id) {
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
      editor.commands.setContent(mdToHtml(note.content), {
        emitUpdate: false,
      });
      setTitle(note.title);
      setTags(note.tags);
      setDirty(false);
      setSaving(false);
      setShowSource(false);
      prevIdRef.current = note.id;
    }
  }, [editor, note.id, note.title, note.content, note.tags]);

  useEffect(() => {
    return () => {
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
    };
  }, []);

  const handleTitleChange = (val: string) => {
    setTitle(val);
    setDirty(true);
    if (editor) scheduleSave(editor.getHTML());
  };

  const addTag = () => {
    const t = tagInput.trim();
    if (t && !tags.includes(t)) {
      const next = [...tags, t];
      setTags(next);
      tagsRef.current = next;
      setTagInput("");
      setDirty(true);
      if (editor) scheduleSave(editor.getHTML());
    }
  };

  const removeTag = (tag: string) => {
    const next = tags.filter((t) => t !== tag);
    setTags(next);
    tagsRef.current = next;
    setDirty(true);
    if (editor) scheduleSave(editor.getHTML());
  };

  const handleInsertImage = () => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "image/*";
    input.multiple = true;
    input.onchange = async () => {
      if (!input.files || !editor) return;
      for (const file of Array.from(input.files)) {
        const dataUrl = await compressImage(file);
        editor.chain().focus().setImage({ src: dataUrl }).run();
      }
    };
    input.click();
  };

  const handleInsertLink = () => {
    if (!editor) return;
    const existing = editor.getAttributes("link").href;
    const url = prompt("URL:", existing || "https://");
    if (url === null) return;
    if (url === "") {
      editor.chain().focus().unsetLink().run();
    } else {
      editor.chain().focus().setLink({ href: url }).run();
    }
  };

  const handleManualSave = useCallback(async () => {
    if (!editor) return;
    if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
    await performSave(editor.getHTML());
  }, [editor, performSave]);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "s") {
        e.preventDefault();
        handleManualSave();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [handleManualSave]);

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-3xl mx-auto px-12 py-10">
        <span className="text-[11px] font-semibold text-text-tertiary uppercase tracking-wider">
          Note
        </span>

        <input
          type="text"
          value={title}
          onChange={(e) => handleTitleChange(e.target.value)}
          placeholder="Untitled"
          className="w-full text-[40px] font-bold text-text-primary bg-transparent border-none outline-none placeholder:text-text-tertiary mb-2 mt-1"
        />

        <div className="flex items-center gap-4 text-xs text-text-tertiary mb-4">
          <span>Created {formatDateTime(note.createdDate)}</span>
          <span>Modified {formatDateTime(note.modifiedDate)}</span>
        </div>

        <div className="flex items-center gap-2 flex-wrap mb-4">
          <Tag className="w-3 h-3 text-text-tertiary" />
          {tags.map((tag) => (
            <span
              key={tag}
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded bg-hover text-xs text-text-secondary"
            >
              {tag}
              <button
                onClick={() => removeTag(tag)}
                className="text-text-tertiary hover:text-danger"
              >
                <X className="w-2.5 h-2.5" />
              </button>
            </span>
          ))}
          <input
            type="text"
            value={tagInput}
            onChange={(e) => setTagInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") addTag();
            }}
            placeholder="Add tag..."
            className="bg-transparent border-none text-xs text-text-secondary outline-none w-20 p-0"
          />
        </div>

        <div className="flex items-center gap-2 mb-2">
          <EditorToolbar
            editor={editor}
            onInsertImage={handleInsertImage}
            onInsertLink={handleInsertLink}
          />
          <div className="flex-1" />
          <ReadAloudButton
            state={tts.state}
            onSpeak={() => {
              const text = editor ? htmlToPlainText(editor.getHTML()) : "";
              tts.speak(text);
            }}
            onStop={tts.stop}
          />
          <div className="flex items-center gap-1 text-xs text-text-tertiary ml-1">
            {saving ? (
              <>
                <Loader2 className="w-3 h-3 animate-spin" />
                <span>Saving</span>
              </>
            ) : dirty ? (
              <span className="text-orange-400">Unsaved</span>
            ) : (
              <span>Saved</span>
            )}
          </div>
        </div>

        <TTSPlayer
          state={tts.state}
          progress={tts.progress}
          error={tts.error}
          voice={tts.voice}
          onTogglePlayPause={tts.togglePlayPause}
          onStop={tts.stop}
          onDismissError={tts.dismissError}
        />

        <div className="border-t border-border mb-4" />

        <EditorContent editor={editor} />

        {/* Markdown source toggle */}
        <div className="mt-6 pt-4 border-t border-border">
          <button
            onClick={async () => {
              const next = !showSource;
              setShowSource(next);
              if (next && editor) {
                const md = await htmlToMd(editor.getHTML());
                setSourceMd(md);
              }
            }}
            className={`flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs transition-colors ${
              showSource
                ? "bg-selected text-accent"
                : "text-text-tertiary hover:bg-hover hover:text-text-secondary"
            }`}
          >
            <Code2 className="w-3.5 h-3.5" />
            {showSource ? "Hide Markdown" : "View Markdown"}
          </button>

          {showSource && (
            <pre className="mt-3 p-4 bg-sidebar border border-border rounded-lg text-xs text-text-secondary font-mono leading-relaxed overflow-x-auto max-h-[300px] overflow-y-auto whitespace-pre-wrap break-words select-all">
              {sourceMd}
            </pre>
          )}
        </div>

      </div>
    </div>
  );
}

function compressImage(
  file: File,
  maxDim = 1400,
  quality = 0.85,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = reject;
    reader.onload = () => {
      const dataUrl = reader.result as string;
      const img = document.createElement("img");
      img.onerror = () => reject(new Error("Failed to load image"));
      img.onload = () => {
        if (img.width <= maxDim && img.height <= maxDim) {
          resolve(dataUrl);
          return;
        }
        const canvas = document.createElement("canvas");
        const ratio = Math.min(maxDim / img.width, maxDim / img.height);
        canvas.width = Math.round(img.width * ratio);
        canvas.height = Math.round(img.height * ratio);
        const ctx = canvas.getContext("2d")!;
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        const mime = file.type === "image/png" ? "image/png" : "image/jpeg";
        resolve(canvas.toDataURL(mime, quality));
      };
      img.src = dataUrl;
    };
    reader.readAsDataURL(file);
  });
}
