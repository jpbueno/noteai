"use client";

import { Node, mergeAttributes } from "@tiptap/core";
import { ReactNodeViewRenderer, NodeViewWrapper } from "@tiptap/react";
import React, { useCallback, useRef, useState } from "react";
import { AlignLeft, AlignCenter, AlignRight, Trash2 } from "lucide-react";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    resizableImage: {
      setImage: (options: {
        src: string;
        alt?: string;
        width?: number;
        align?: string;
      }) => ReturnType;
    };
  }
}

export const ResizableImage = Node.create({
  name: "resizableImage",
  group: "block",
  atom: true,
  draggable: true,

  addAttributes() {
    return {
      src: { default: null },
      alt: { default: "" },
      width: { default: null },
      align: { default: "center" },
    };
  },

  parseHTML() {
    return [
      {
        tag: "img[src]",
        getAttrs: (dom) => {
          const el = dom as HTMLElement;
          const w =
            el.getAttribute("data-width") ||
            el.style.width?.replace("px", "");
          return {
            src: el.getAttribute("src"),
            alt: el.getAttribute("alt") || "",
            width: w ? parseInt(w, 10) || null : null,
            align: el.getAttribute("data-align") || "center",
          };
        },
      },
    ];
  },

  renderHTML({ HTMLAttributes }) {
    const { width, align, ...rest } = HTMLAttributes;
    return [
      "img",
      mergeAttributes(rest, {
        "data-width": width,
        "data-align": align,
        style: width ? `width: ${width}px` : undefined,
      }),
    ];
  },

  addCommands() {
    return {
      setImage:
        (options) =>
        ({ commands }) => {
          return commands.insertContent({ type: this.name, attrs: options });
        },
    };
  },

  addNodeView() {
    return ReactNodeViewRenderer(ResizableImageView);
  },
});

/* ---------- NodeView Component ---------- */

interface ImageAttrs {
  src: string;
  alt: string;
  width: number | null;
  align: string;
}

function ResizableImageView(props: {
  node: { attrs: Record<string, unknown> };
  updateAttributes: (attrs: Record<string, unknown>) => void;
  selected: boolean;
  deleteNode: () => void;
}) {
  const node = { attrs: props.node.attrs as unknown as ImageAttrs };
  const { updateAttributes, selected, deleteNode } = props;
  const containerRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement>(null);
  const [resizing, setResizing] = useState(false);

  const startResize = useCallback(
    (e: React.MouseEvent, dir: "se" | "sw") => {
      e.preventDefault();
      e.stopPropagation();
      setResizing(true);
      const startX = e.clientX;
      const startW = imgRef.current?.offsetWidth || 300;
      const sign = dir === "se" ? 1 : -1;

      const onMove = (ev: MouseEvent) => {
        const maxW =
          containerRef.current?.parentElement?.offsetWidth || 800;
        const newW = Math.max(
          80,
          Math.min(startW + (ev.clientX - startX) * sign, maxW),
        );
        updateAttributes({ width: Math.round(newW) });
      };

      const onUp = () => {
        setResizing(false);
        document.removeEventListener("mousemove", onMove);
        document.removeEventListener("mouseup", onUp);
      };

      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
    },
    [updateAttributes],
  );

  const justify =
    { left: "justify-start", center: "justify-center", right: "justify-end" }[
      node.attrs.align
    ] || "justify-center";

  return (
    <NodeViewWrapper className="resizable-image-wrapper">
      <div ref={containerRef} className={`flex ${justify} my-3`}>
        <div
          className={`relative inline-block ${resizing ? "" : "group"}`}
          style={{ maxWidth: "100%" }}
        >
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            ref={imgRef}
            src={node.attrs.src}
            alt={node.attrs.alt || ""}
            style={{
              width: node.attrs.width ? `${node.attrs.width}px` : "100%",
              maxWidth: "100%",
              display: "block",
              borderRadius: "6px",
            }}
            draggable={false}
          />

          {/* Thin highlight border only — no ring/outline box */}
          {selected && (
            <div
              className="absolute inset-0 rounded-[6px] pointer-events-none"
              style={{
                boxShadow: "0 0 0 2px var(--color-accent)",
              }}
            />
          )}

          {/* Resize handles — always visible on hover or when selected */}
          {(selected || undefined) && (
            <>
              <div
                onMouseDown={(e) => startResize(e, "se")}
                className="absolute -bottom-1 -right-1 w-2.5 h-2.5 rounded-full bg-accent cursor-se-resize z-10 opacity-80 hover:opacity-100"
              />
              <div
                onMouseDown={(e) => startResize(e, "sw")}
                className="absolute -bottom-1 -left-1 w-2.5 h-2.5 rounded-full bg-accent cursor-sw-resize z-10 opacity-80 hover:opacity-100"
              />
              <div
                onMouseDown={(e) => startResize(e, "se")}
                className="absolute -top-1 -right-1 w-2.5 h-2.5 rounded-full bg-accent cursor-ne-resize z-10 opacity-80 hover:opacity-100"
              />
              <div
                onMouseDown={(e) => startResize(e, "sw")}
                className="absolute -top-1 -left-1 w-2.5 h-2.5 rounded-full bg-accent cursor-nw-resize z-10 opacity-80 hover:opacity-100"
              />
            </>
          )}

          {/* Alignment + delete toolbar */}
          {selected && !resizing && (
            <div className="absolute -top-9 left-1/2 -translate-x-1/2 flex items-center gap-0.5 bg-sidebar border border-border rounded-lg px-1.5 py-1 shadow-xl z-20 whitespace-nowrap">
              {(
                [
                  ["left", AlignLeft],
                  ["center", AlignCenter],
                  ["right", AlignRight],
                ] as const
              ).map(([a, Icon]) => (
                <button
                  key={a}
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => updateAttributes({ align: a })}
                  className={`p-1 rounded transition-colors ${
                    node.attrs.align === a
                      ? "bg-selected text-accent"
                      : "text-text-secondary hover:bg-hover"
                  }`}
                  title={`Align ${a}`}
                >
                  <Icon className="w-3.5 h-3.5" />
                </button>
              ))}
              <div className="w-px h-4 bg-border mx-0.5" />
              <button
                onMouseDown={(e) => e.preventDefault()}
                onClick={deleteNode}
                className="p-1 rounded text-text-secondary hover:bg-hover hover:text-danger transition-colors"
                title="Remove image"
              >
                <Trash2 className="w-3.5 h-3.5" />
              </button>
            </div>
          )}
        </div>
      </div>
    </NodeViewWrapper>
  );
}
