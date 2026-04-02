"use client";

import { useState, useRef, useEffect } from "react";
import { X, Send, Loader2, Trash2 } from "lucide-react";
import BrainHeadIcon from "@/components/BrainHeadIcon";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { ChatMessage } from "@/lib/types";
import { db } from "@/lib/db";
import { chatWithAI } from "@/lib/ai";
import { triggerRefresh } from "@/lib/hooks";
import { v4 as uuid } from "uuid";

interface ChatPanelProps {
  messages: ChatMessage[];
  onClose: () => void;
}

export default function ChatPanel({ messages, onClose }: ChatPanelProps) {
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages, isLoading]);

  const sendMessage = async () => {
    const text = input.trim();
    if (!text || isLoading) return;

    const userMsg: ChatMessage = {
      id: uuid(),
      role: "user",
      content: text,
      timestamp: new Date().toISOString(),
    };
    await db.chatMessages.add(userMsg);
    triggerRefresh();
    setInput("");
    setIsLoading(true);

    try {
      const history = [...messages, userMsg]
        .filter((m) => m.role !== "system")
        .slice(-20)
        .map((m) => ({ role: m.role, content: m.content }));

      const reply = await chatWithAI(history);

      const assistantMsg: ChatMessage = {
        id: uuid(),
        role: "assistant",
        content: reply,
        timestamp: new Date().toISOString(),
      };
      await db.chatMessages.add(assistantMsg);
      triggerRefresh();
    } catch (err) {
      const errorMsg: ChatMessage = {
        id: uuid(),
        role: "assistant",
        content: `Error: ${err instanceof Error ? err.message : "Something went wrong"}`,
        timestamp: new Date().toISOString(),
      };
      await db.chatMessages.add(errorMsg);
      triggerRefresh();
    } finally {
      setIsLoading(false);
    }
  };

  const clearChat = async () => {
    if (confirm("Clear all chat messages?")) {
      await db.chatMessages.clear();
      triggerRefresh();
    }
  };

  return (
    <div className="flex flex-col h-full bg-sidebar">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-border">
        <div className="flex items-center gap-2">
          <BrainHeadIcon className="w-4 h-4 text-accent" />
          <span className="text-sm font-medium text-text-primary">
            AI Assistant
          </span>
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={clearChat}
            className="p-1 rounded text-text-tertiary hover:text-text-secondary hover:bg-hover transition-colors"
            title="Clear chat"
          >
            <Trash2 className="w-3.5 h-3.5" />
          </button>
          <button
            onClick={onClose}
            className="p-1 rounded text-text-tertiary hover:text-text-secondary hover:bg-hover transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Messages */}
      <div ref={scrollRef} className="flex-1 overflow-y-auto p-4 space-y-4">
        {messages.length === 0 && !isLoading && (
          <div className="text-center py-12">
            <BrainHeadIcon className="w-8 h-8 text-text-tertiary mx-auto mb-3" />
            <p className="text-sm text-text-tertiary">
              Ask me anything about your meetings, notes, or tasks.
            </p>
          </div>
        )}

        {messages
          .filter((m) => m.role !== "system")
          .map((msg) => (
            <div
              key={msg.id}
              className={`flex ${msg.role === "user" ? "justify-end" : "justify-start"}`}
            >
              <div
                className={`max-w-[85%] rounded-lg px-3 py-2 text-sm ${
                  msg.role === "user"
                    ? "bg-accent text-white"
                    : "bg-hover text-text-primary"
                }`}
              >
                {msg.role === "assistant" ? (
                  <div className="markdown-body text-sm [&_p]:mb-1.5 [&_h1]:text-base [&_h2]:text-sm [&_h3]:text-sm">
                    <ReactMarkdown remarkPlugins={[remarkGfm]}>
                      {msg.content}
                    </ReactMarkdown>
                  </div>
                ) : (
                  <p className="whitespace-pre-wrap">{msg.content}</p>
                )}
              </div>
            </div>
          ))}

        {isLoading && (
          <div className="flex justify-start">
            <div className="bg-hover rounded-lg px-3 py-2">
              <Loader2 className="w-4 h-4 animate-spin text-accent" />
            </div>
          </div>
        )}
      </div>

      {/* Input */}
      <div className="border-t border-border p-3">
        <div className="flex items-end gap-2">
          <textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                sendMessage();
              }
            }}
            placeholder="Ask NoteAI..."
            rows={1}
            className="flex-1 bg-hover border border-border rounded-md text-sm text-text-primary p-2.5 outline-none resize-none max-h-32 placeholder:text-text-tertiary focus:border-accent"
          />
          <button
            onClick={sendMessage}
            disabled={!input.trim() || isLoading}
            className="flex items-center justify-center w-9 h-9 rounded-md bg-accent text-white hover:bg-accent/80 transition-colors disabled:opacity-50"
          >
            <Send className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  );
}
