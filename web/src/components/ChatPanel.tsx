"use client";

import { useCallback, useState, useRef, useEffect } from "react";
import { X, Send, Loader2, Trash2, TriangleAlert } from "lucide-react";
import BrainHeadIcon from "@/components/BrainHeadIcon";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Components } from "react-markdown";
import type { ChatMessage, Meeting, Note, SidebarSelection, T5TReport, TodoItem } from "@/lib/types";
import { db, getSetting, isSettingConfigured } from "@/lib/db";
import { chatWithAI } from "@/lib/ai";
import { loadCopilotSetupMessage } from "@/lib/ai-preflight";
import { triggerRefresh } from "@/lib/hooks";
import { buildChatSourceContext, sourceSelectionFromUrl } from "@/lib/chat-sources";

interface ChatPanelProps {
  messages: ChatMessage[];
  meetings: Meeting[];
  notes: Note[];
  todos: TodoItem[];
  t5tReports: T5TReport[];
  onClose: () => void;
  onOpenAISettings: () => void;
  onNavigate: (selection: NonNullable<SidebarSelection>) => void;
}

export default function ChatPanel({
  messages,
  meetings,
  notes,
  todos,
  t5tReports,
  onClose,
  onOpenAISettings,
  onNavigate,
}: ChatPanelProps) {
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [setupMessage, setSetupMessage] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages, isLoading]);

  const refreshSetupState = useCallback(async () => {
    setSetupMessage(await loadCopilotSetupMessage({ getSetting, isSettingConfigured }));
  }, []);

  useEffect(() => {
    void refreshSetupState();
  }, [refreshSetupState]);

  const sendMessage = async () => {
    const text = input.trim();
    if (!text || isLoading) return;

    const latestSetupMessage = await loadCopilotSetupMessage({ getSetting, isSettingConfigured });
    setSetupMessage(latestSetupMessage);
    if (latestSetupMessage) return;

    const userMsg: ChatMessage = {
      id: crypto.randomUUID(),
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
      const sourceContext = buildChatSourceContext({ meetings, notes, todos, t5tReports });

      const reply = await chatWithAI(history, sourceContext);

      const assistantMsg: ChatMessage = {
        id: crypto.randomUUID(),
        role: "assistant",
        content: reply,
        timestamp: new Date().toISOString(),
      };
      await db.chatMessages.add(assistantMsg);
      triggerRefresh();
    } catch (err) {
      const errorMsg: ChatMessage = {
        id: crypto.randomUUID(),
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

  const markdownComponents: Components = {
    a({ href, children }) {
      const selection = href ? sourceSelectionFromUrl(href) : null;
      if (selection) {
        return (
          <button
            type="button"
            onClick={() => onNavigate(selection)}
            className="rounded-md border border-accent/30 bg-accent/10 px-1.5 py-0.5 text-xs font-semibold text-accent transition-colors hover:bg-accent/18"
            title="Open source"
          >
            {children}
          </button>
        );
      }

      return (
        <a
          href={href}
          target="_blank"
          rel="noreferrer"
          className="text-accent underline decoration-accent/40 underline-offset-2"
        >
          {children}
        </a>
      );
    },
  };

  const clearChat = async () => {
    if (confirm("Clear all chat messages?")) {
      await db.chatMessages.clear();
      triggerRefresh();
    }
  };

  return (
    <div className="flex h-full flex-col bg-sidebar">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <div className="flex items-center gap-2">
          <BrainHeadIcon className="w-4 h-4 text-accent" />
          <div>
            <span className="block text-sm font-bold text-text-primary">
              AI copilot
            </span>
            <span className="block text-[11px] text-text-tertiary">Workspace-aware</span>
          </div>
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={clearChat}
            className="rounded-lg p-1.5 text-text-tertiary transition-colors hover:bg-hover hover:text-text-secondary"
            title="Clear chat"
          >
            <Trash2 className="w-3.5 h-3.5" />
          </button>
          <button
            onClick={onClose}
            className="rounded-lg p-1.5 text-text-tertiary transition-colors hover:bg-hover hover:text-text-secondary"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Messages */}
      <div ref={scrollRef} className="flex-1 overflow-y-auto space-y-4 p-4">
        {messages.length === 0 && !isLoading && (
          <div className="v4-panel px-4 py-8 text-center">
            <BrainHeadIcon className="w-8 h-8 text-text-tertiary mx-auto mb-3" />
            <p className="text-sm font-semibold text-text-secondary">
              Ask about meetings, notes, tasks, or T5T drafts.
            </p>
            <div className="mt-4 grid gap-2 text-left">
              <Suggestion text="Summarize today's meetings" />
              <Suggestion text="Find unassigned action items" />
              <Suggestion text="Draft a T5T update" />
            </div>
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
                className={`max-w-[88%] rounded-2xl px-3 py-2 text-sm ${
                  msg.role === "user"
                    ? "bg-accent text-black"
                    : "border border-border bg-hover text-text-primary"
                }`}
              >
                {msg.role === "assistant" ? (
                  <div className="markdown-body text-sm [&_p]:mb-1.5 [&_h1]:text-base [&_h2]:text-sm [&_h3]:text-sm">
                    <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>
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
            <div className="rounded-2xl border border-border bg-hover px-3 py-2">
              <Loader2 className="w-4 h-4 animate-spin text-accent" />
            </div>
          </div>
        )}
      </div>

      {/* Input */}
      <div className="border-t border-border p-3">
        {setupMessage && (
          <div className="mb-3 rounded-lg border border-orange-400/25 bg-orange-400/10 p-3">
            <div className="flex items-start gap-2">
              <TriangleAlert className="mt-0.5 h-4 w-4 flex-shrink-0 text-orange-300" />
              <div className="min-w-0 space-y-2">
                <p className="text-xs font-semibold text-orange-200">AI setup required</p>
                <p className="text-xs leading-5 text-text-secondary">{setupMessage}</p>
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={onOpenAISettings}
                    className="rounded-md border border-accent/35 bg-accent/12 px-2 py-1 text-xs font-semibold text-accent transition-colors hover:bg-accent/18"
                  >
                    Open AI settings
                  </button>
                  <button
                    type="button"
                    onClick={() => void refreshSetupState()}
                    className="rounded-md border border-border bg-hover px-2 py-1 text-xs font-semibold text-text-secondary transition-colors hover:bg-selected"
                  >
                    Check again
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}
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
            className="max-h-32 flex-1 resize-none rounded-xl border border-border bg-content/70 p-2.5 text-sm text-text-primary outline-none placeholder:text-text-tertiary focus:border-accent"
          />
          <button
            onClick={sendMessage}
            disabled={!input.trim() || isLoading || Boolean(setupMessage)}
            className="flex h-9 w-9 items-center justify-center rounded-xl bg-accent text-black transition-colors hover:bg-accent/85 disabled:opacity-50"
          >
            <Send className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  );
}

function Suggestion({ text }: { text: string }) {
  return (
    <div className="rounded-xl border border-border bg-content/55 px-3 py-2 text-xs font-semibold text-text-secondary">
      {text}
    </div>
  );
}
