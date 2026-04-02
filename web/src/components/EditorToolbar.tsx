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

export default function EditorToolbar({ editor, onInsertImage, onInsertLink }: Props) {
  if (!editor) return null;

  const Btn = ({
    active,
    onClick,
    icon: Icon,
    title,
  }: {
    active: boolean;
    onClick: () => void;
    icon: React.ComponentType<{ className?: string }>;
    title: string;
  }) => (
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

  const Sep = () => <div className="w-px h-5 bg-border mx-0.5" />;

  return (
    <div className="flex items-center gap-0.5">
      <Btn
        active={editor.isActive("bold")}
        onClick={() => editor.chain().focus().toggleBold().run()}
        icon={Bold}
        title="Bold (⌘B)"
      />
      <Btn
        active={editor.isActive("italic")}
        onClick={() => editor.chain().focus().toggleItalic().run()}
        icon={Italic}
        title="Italic (⌘I)"
      />
      <Btn
        active={editor.isActive("underline")}
        onClick={() => editor.chain().focus().toggleUnderline().run()}
        icon={Underline}
        title="Underline (⌘U)"
      />
      <Btn
        active={editor.isActive("code")}
        onClick={() => editor.chain().focus().toggleCode().run()}
        icon={Code}
        title="Inline code"
      />

      <Sep />

      <Btn
        active={editor.isActive("heading", { level: 1 })}
        onClick={() => editor.chain().focus().toggleHeading({ level: 1 }).run()}
        icon={Heading1}
        title="Heading 1"
      />
      <Btn
        active={editor.isActive("heading", { level: 2 })}
        onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()}
        icon={Heading2}
        title="Heading 2"
      />

      <Sep />

      <Btn
        active={editor.isActive("bulletList")}
        onClick={() => editor.chain().focus().toggleBulletList().run()}
        icon={List}
        title="Bullet list"
      />
      <Btn
        active={editor.isActive("orderedList")}
        onClick={() => editor.chain().focus().toggleOrderedList().run()}
        icon={ListOrdered}
        title="Ordered list"
      />

      <Sep />

      <Btn
        active={editor.isActive("link")}
        onClick={onInsertLink}
        icon={Link2}
        title="Insert link"
      />
      <Btn active={false} onClick={onInsertImage} icon={ImagePlus} title="Insert image" />
    </div>
  );
}
