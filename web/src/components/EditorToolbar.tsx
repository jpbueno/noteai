"use client";

import type { Editor } from "@tiptap/react";
import {
  Bold,
  Italic,
  Underline,
  Code,
  Heading1,
  Heading2,
  List,
  ListOrdered,
  Link2,
  ImagePlus,
} from "lucide-react";

interface Props {
  editor: Editor | null;
  onInsertImage: () => void;
  onInsertLink: () => void;
}

function ToolbarButton({
  active,
  onClick,
  icon: Icon,
  title,
}: {
  active: boolean;
  onClick: () => void;
  icon: React.ComponentType<{ className?: string }>;
  title: string;
}) {
  return (
    <button
      onMouseDown={(e) => e.preventDefault()}
      onClick={onClick}
      className={`p-1.5 rounded-md transition-colors ${
        active
          ? "bg-selected text-accent"
          : "text-text-secondary hover:bg-hover hover:text-text-primary"
      }`}
      title={title}
    >
      <Icon className="w-4 h-4" />
    </button>
  );
}

function ToolbarSeparator() {
  return <div className="w-px h-5 bg-border mx-0.5" />;
}

export default function EditorToolbar({ editor, onInsertImage, onInsertLink }: Props) {
  if (!editor) return null;

  return (
    <div className="flex items-center gap-0.5">
      <ToolbarButton
        active={editor.isActive("bold")}
        onClick={() => editor.chain().focus().toggleBold().run()}
        icon={Bold}
        title="Bold (⌘B)"
      />
      <ToolbarButton
        active={editor.isActive("italic")}
        onClick={() => editor.chain().focus().toggleItalic().run()}
        icon={Italic}
        title="Italic (⌘I)"
      />
      <ToolbarButton
        active={editor.isActive("underline")}
        onClick={() => editor.chain().focus().toggleUnderline().run()}
        icon={Underline}
        title="Underline (⌘U)"
      />
      <ToolbarButton
        active={editor.isActive("code")}
        onClick={() => editor.chain().focus().toggleCode().run()}
        icon={Code}
        title="Inline code"
      />

      <ToolbarSeparator />

      <ToolbarButton
        active={editor.isActive("heading", { level: 1 })}
        onClick={() => editor.chain().focus().toggleHeading({ level: 1 }).run()}
        icon={Heading1}
        title="Heading 1"
      />
      <ToolbarButton
        active={editor.isActive("heading", { level: 2 })}
        onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()}
        icon={Heading2}
        title="Heading 2"
      />

      <ToolbarSeparator />

      <ToolbarButton
        active={editor.isActive("bulletList")}
        onClick={() => editor.chain().focus().toggleBulletList().run()}
        icon={List}
        title="Bullet list"
      />
      <ToolbarButton
        active={editor.isActive("orderedList")}
        onClick={() => editor.chain().focus().toggleOrderedList().run()}
        icon={ListOrdered}
        title="Ordered list"
      />

      <ToolbarSeparator />

      <ToolbarButton
        active={editor.isActive("link")}
        onClick={onInsertLink}
        icon={Link2}
        title="Insert link"
      />
      <ToolbarButton active={false} onClick={onInsertImage} icon={ImagePlus} title="Insert image" />
    </div>
  );
}
