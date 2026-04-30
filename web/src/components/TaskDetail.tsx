"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import {
  CheckCircle,
  Circle,
  Tag,
  X,
  Sparkles,
  Loader2,
  Save,
  ChevronDown,
  ChevronRight,
} from "lucide-react";
import { useEditor, EditorContent } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import Placeholder from "@tiptap/extension-placeholder";
import type { TaskItem, SidebarSelection } from "@/lib/types";
import EditorToolbar from "@/components/EditorToolbar";
import { db } from "@/lib/db";
import { formatDateTime, triggerRefresh } from "@/lib/hooks";
import { chatWithAI } from "@/lib/ai";
import { useTTS } from "@/lib/tts";
import { TTSPlayer, ReadAloudButton } from "@/components/TTSPlayer";
import { mdToHtml, htmlToMd, htmlToPlainText } from "@/lib/content-utils";
import { readSelectedTextForReadAloud } from "@/lib/read-aloud-selection";

function parseTaskJSON(raw: string): { title: string; description: string } {
  const cleaned = raw
    .replace(/```json\s*/g, "")
    .replace(/```\s*/g, "")
    .trim();

  const blocks: string[] = [];
  let depth = 0;
  let start = -1;
  for (let i = 0; i < cleaned.length; i++) {
    if (cleaned[i] === "{") {
      if (depth === 0) start = i;
      depth++;
    } else if (cleaned[i] === "}") {
      depth--;
      if (depth === 0 && start !== -1) {
        blocks.push(cleaned.substring(start, i + 1));
        start = -1;
      }
    }
  }

  for (const block of blocks) {
    try {
      const parsed = JSON.parse(block);
      if (parsed.title && parsed.description) {
        return { title: String(parsed.title), description: String(parsed.description) };
      }
    } catch {
      // try next block
    }
  }

  const titleMatch = raw.match(/"title"\s*:\s*"([^"]+)"/);
  const descMatch = raw.match(/"description"\s*:\s*"([^"]+)"/);
  return {
    title: titleMatch?.[1] || raw.split("\n")[0].slice(0, 60),
    description: descMatch?.[1] || raw,
  };
}

interface TaskDetailProps {
  task: TaskItem;
  onNavigate?: (sel: SidebarSelection) => void;
}

export default function TaskDetail({ task }: TaskDetailProps) {
  const tts = useTTS();
  const [title, setTitle] = useState(task.title);
  const [description, setDescription] = useState(task.description);
  const [rawInput, setRawInput] = useState(task.rawInput);
  const [tags, setTags] = useState(task.tags);
  const [tagInput, setTagInput] = useState("");
  const [isGenerating, setIsGenerating] = useState(false);
  const [showRawInput, setShowRawInput] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const prevIdRef = useRef(task.id);
  const readAloudRootRef = useRef<HTMLDivElement>(null);

  const editor = useEditor({
    extensions: [
      StarterKit,
      Placeholder.configure({ placeholder: "Task description..." }),
    ],
    content: "",
    editorProps: {
      attributes: { class: "tiptap-editor outline-none min-h-[200px] px-1 py-2 text-[15px] text-text-primary leading-relaxed" },
    },
    onUpdate: ({ editor: e }) => {
      setDirty(true);
      htmlToMd(e.getHTML()).then((md) => setDescription(md));
    },
  });

  // Sync editor content when task changes
  useEffect(() => {
    if (!editor) return;
    if (prevIdRef.current !== task.id) {
      setTitle(task.title);
      setDescription(task.description);
      setRawInput(task.rawInput);
      setTags(task.tags);
      setDirty(false);
      setShowRawInput(false);
      prevIdRef.current = task.id;
      editor.commands.setContent(mdToHtml(task.description));
    } else if (!dirty) {
      setTitle(task.title);
      setDescription(task.description);
      setRawInput(task.rawInput);
      setTags(task.tags);
      // Only update editor if content actually changed (avoid cursor jump)
      htmlToMd(editor.getHTML()).then((currentMd) => {
        if (currentMd.trim() !== task.description.trim()) {
          editor.commands.setContent(mdToHtml(task.description));
        }
      });
    }
  }, [task.id, task.title, task.description, task.rawInput, task.tags, dirty, editor]);

  // Initial content load
  useEffect(() => {
    if (editor && task.description) {
      editor.commands.setContent(mdToHtml(task.description));
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editor]);

  const markDirty = useCallback(() => setDirty(true), []);

  const handleSave = useCallback(async () => {
    setSaving(true);
    await db.tasks.update(task.id, {
      title,
      description,
      rawInput,
      tags,
      modifiedDate: new Date().toISOString(),
    });
    triggerRefresh();
    setDirty(false);
    setSaving(false);
  }, [task.id, title, description, rawInput, tags]);

  const toggleStatus = async () => {
    const newStatus = task.status === "completed" ? "pending" : "completed";
    await db.tasks.update(task.id, {
      status: newStatus,
      modifiedDate: new Date().toISOString(),
    });
    triggerRefresh();
  };

  const handleTitleChange = (val: string) => { setTitle(val); markDirty(); };
  const handleRawInputChange = (val: string) => { setRawInput(val); markDirty(); };

  const addTag = () => {
    const t = tagInput.trim();
    if (t && !tags.includes(t)) {
      setTags((prev) => [...prev, t]);
      setTagInput("");
      markDirty();
    }
  };

  const removeTag = (tag: string) => {
    setTags((prev) => prev.filter((t) => t !== tag));
    markDirty();
  };

  const generateSummary = async () => {
    if (!rawInput.trim()) return;
    setIsGenerating(true);
    try {
      const truncated = rawInput.slice(0, 4000);
      const prompt = `Extract the key accomplishment from this email/message. Write everything in FIRST PERSON ("I configured...", "I resolved...", "I enabled...").

Return ONLY a single JSON object. No markdown fences, no extra text, no commentary. Just the JSON.

{"title": "...", "description": "..."}

TITLE: Very short label (3-6 words max). Just enough to identify the task at a glance. Like a filename or tag.
DESCRIPTION: A 2-3 sentence first-person explanation with full detail — what I accomplished, why it matters, the outcome, names, projects, tools. This is the main content.

INPUT:
${truncated}`;

      const result = await chatWithAI([{ role: "user", content: prompt }]);
      const { title: newTitle, description: newDescription } = parseTaskJSON(result);

      setTitle(newTitle);
      setDescription(newDescription);
      if (editor) {
        const html = mdToHtml(newDescription);
        editor.commands.setContent(html);
      }

      await db.tasks.update(task.id, {
        title: newTitle,
        description: newDescription,
        rawInput,
        modifiedDate: new Date().toISOString(),
      });
      triggerRefresh();
      setDirty(false);
    } catch (err) {
      alert(err instanceof Error ? err.message : "Failed to generate");
    } finally {
      setIsGenerating(false);
    }
  };

  return (
    <div ref={readAloudRootRef} className="h-full overflow-y-auto">
      <div className="max-w-3xl mx-auto px-12 py-10">
        {/* Status + Title */}
        <div className="flex items-start gap-3 mb-3">
          <button onClick={toggleStatus} className="mt-2.5 flex-shrink-0">
            {task.status === "completed" ? (
              <CheckCircle className="w-6 h-6 text-green-500" />
            ) : (
              <Circle className="w-6 h-6 text-text-tertiary hover:text-accent transition-colors" />
            )}
          </button>
          <input
            type="text"
            value={title}
            onChange={(e) => handleTitleChange(e.target.value)}
            placeholder="Task title"
            className={`flex-1 text-[40px] font-bold bg-transparent border-none outline-none placeholder:text-text-tertiary ${
              task.status === "completed"
                ? "text-text-tertiary line-through"
                : "text-text-primary"
            }`}
          />
        </div>

        {/* Meta */}
        <div className="flex items-center gap-4 text-xs text-text-tertiary mb-4 pl-9">
          <span>Created {formatDateTime(task.createdDate)}</span>
          <span
            className={`px-2 py-0.5 rounded text-xs font-medium ${
              task.status === "completed"
                ? "bg-green-500/20 text-green-400"
                : "bg-orange-500/20 text-orange-400"
            }`}
          >
            {task.status === "completed" ? "Completed" : "Pending"}
          </span>
        </div>

        {/* Tags */}
        <div className="flex items-center gap-2 flex-wrap mb-6 pl-9">
          <Tag className="w-3 h-3 text-text-tertiary" />
          {tags.map((tag) => (
            <span
              key={tag}
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded bg-hover text-xs text-text-secondary"
            >
              {tag}
              <button onClick={() => removeTag(tag)} className="text-text-tertiary hover:text-danger">
                <X className="w-2.5 h-2.5" />
              </button>
            </span>
          ))}
          <input
            type="text"
            value={tagInput}
            onChange={(e) => setTagInput(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") addTag(); }}
            placeholder="Add tag..."
            className="bg-transparent border-none text-xs text-text-secondary outline-none w-20 p-0"
          />
        </div>

        <div className="border-t border-border mb-6" />

        {/* Raw input — collapsible AI Summarize */}
        <div className="mb-6">
          <div className="flex items-center justify-between">
            <button
              onClick={() => setShowRawInput((v) => !v)}
              className="flex items-center gap-1.5 text-text-secondary hover:text-text-primary transition-colors"
            >
              {showRawInput ? <ChevronDown className="w-3.5 h-3.5" /> : <ChevronRight className="w-3.5 h-3.5" />}
              <Sparkles className="w-3 h-3" />
              <span className="text-sm font-medium">AI Summarize</span>
            </button>
            {showRawInput && (
              <button
                onClick={generateSummary}
                disabled={isGenerating || !rawInput.trim()}
                className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-accent/20 text-accent text-sm hover:bg-accent/30 transition-colors disabled:opacity-50"
              >
                {isGenerating ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Sparkles className="w-3.5 h-3.5" />}
                Summarize
              </button>
            )}
          </div>
          {showRawInput && (
            <div className="mt-3">
              <p className="text-xs text-text-tertiary mb-2">
                Paste text below. AI will extract a short title and description.
              </p>
              <textarea
                value={rawInput}
                onChange={(e) => handleRawInputChange(e.target.value)}
                placeholder="Paste raw meeting notes, emails, action items..."
                className="w-full min-h-[80px] bg-hover border border-border rounded-md text-[15px] text-text-primary p-3 outline-none resize-none placeholder:text-text-tertiary focus:border-accent"
              />
            </div>
          )}
        </div>

        {/* Description — Rich Editor */}
        <div>
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-sm font-medium text-text-secondary">Description</h3>
            <ReadAloudButton
              state={tts.state}
              onSpeak={() => {
                if (editor) {
                  const selectedText = readSelectedTextForReadAloud({
                    root: readAloudRootRef.current,
                    editor,
                  });
                  const plain = htmlToPlainText(editor.getHTML());
                  tts.speak(selectedText ?? `${title}. ${plain}`);
                }
              }}
              onStop={tts.stop}
            />
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

          {editor && (
            <EditorToolbar
              editor={editor}
              onInsertLink={() => {
                const url = prompt("Enter URL:");
                if (url) editor.chain().focus().setLink({ href: url }).run();
              }}
              onInsertImage={() => {
                const url = prompt("Enter image URL:");
                if (url) editor.chain().focus().setImage({ src: url }).run();
              }}
            />
          )}
          <div className="border border-border rounded-md bg-hover overflow-hidden">
            <EditorContent editor={editor} />
          </div>
        </div>

        {/* Save button */}
        <div className="mt-8 pt-6 border-t border-border">
          <button
            onClick={handleSave}
            disabled={!dirty || saving}
            className="flex items-center gap-2 px-4 py-2 rounded-md bg-accent text-white text-sm font-medium hover:bg-accent/80 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <Save className="w-4 h-4" />}
            {saving ? "Saving..." : dirty ? "Save" : "Saved"}
          </button>
        </div>

      </div>
    </div>
  );
}
