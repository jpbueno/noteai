"use client";

import { useState, useEffect } from "react";
import {
  User,
  Settings as SettingsIcon,
  FileText,
  Shield,
  ListChecks,
  Download,
  Loader2,
  Eye,
  EyeOff,
  Save,
} from "lucide-react";
import type { LLMProvider, MeetingTemplate, T5TConfig } from "@/lib/types";
import BrainHeadIcon from "@/components/BrainHeadIcon";
import { LLM_PROVIDERS, MEETING_TEMPLATES } from "@/lib/types";
import { db, getSetting, isSettingConfigured, setSetting, getT5TConfig, saveT5TConfig } from "@/lib/db";
import { triggerRefresh } from "@/lib/hooks";
import { TTS_VOICES, type TTSVoice } from "@/lib/tts";

type SettingsTab =
  | "general"
  | "ai"
  | "privacy"
  | "t5t"
  | "export"
  | "about";

const TABS: { id: SettingsTab; label: string; icon: React.ComponentType<{ className?: string }> }[] = [
  { id: "general", label: "General", icon: SettingsIcon },
  { id: "ai", label: "AI", icon: BrainHeadIcon },
  { id: "export", label: "Export", icon: FileText },
  { id: "privacy", label: "Privacy", icon: Shield },
  { id: "t5t", label: "T5T", icon: ListChecks },
  { id: "about", label: "About", icon: User },
];

const POPULAR_MODELS: Record<LLMProvider, { id: string; name: string }[]> = {
  openrouter: [
    { id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4" },
    { id: "anthropic/claude-opus-4", name: "Claude Opus 4" },
    { id: "openai/gpt-4o", name: "GPT-4o" },
    { id: "openai/o3-mini", name: "o3-mini" },
    { id: "google/gemini-2.5-pro-preview", name: "Gemini 2.5 Pro" },
    { id: "meta-llama/llama-4-maverick", name: "Llama 4 Maverick" },
    { id: "deepseek/deepseek-r1", name: "DeepSeek R1" },
  ],
  anthropic: [
    { id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4" },
    { id: "claude-opus-4-20250514", name: "Claude Opus 4" },
    { id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku" },
  ],
  openai: [
    { id: "gpt-4o", name: "GPT-4o" },
    { id: "gpt-4o-mini", name: "GPT-4o Mini" },
    { id: "o3-mini", name: "o3-mini" },
  ],
  nvidia: [
    { id: "azure/anthropic/claude-opus-4-6", name: "Claude Opus 4.6" },
    { id: "azure/anthropic/claude-sonnet-4-6", name: "Claude Sonnet 4.6" },
    { id: "azure/anthropic/claude-opus-4-5", name: "Claude Opus 4.5" },
    { id: "azure/anthropic/claude-sonnet-4-5", name: "Claude Sonnet 4.5" },
    { id: "azure/anthropic/claude-haiku-4-5", name: "Claude Haiku 4.5" },
    { id: "nvcf/nvidia/llama-3.3-nemotron-super-49b-v1.5", name: "Nemotron Super 49B v1.5" },
    { id: "nvcf/meta/llama-3.3-70b-instruct", name: "Llama 3.3 70B" },
    { id: "nvcf/openai/gpt-oss-120b", name: "GPT OSS 120B" },
    { id: "nvidia/qwen/qwen3-next-80b-a3b-instruct", name: "Qwen 3 Next 80B" },
  ],
};

export default function Settings() {
  const [tab, setTab] = useState<SettingsTab>("ai");
  const [provider, setProvider] = useState<LLMProvider>("openrouter");
  const [model, setModel] = useState("anthropic/claude-sonnet-4");
  const [customModel, setCustomModel] = useState("");
  const [template, setTemplate] = useState<MeetingTemplate>("auto");
  const [apiKeys, setApiKeys] = useState<Record<LLMProvider, string>>({
    openrouter: "",
    anthropic: "",
    openai: "",
    nvidia: "",
  });
  const [configuredKeys, setConfiguredKeys] = useState<Record<LLMProvider, boolean>>({
    openrouter: false,
    anthropic: false,
    openai: false,
    nvidia: false,
  });
  const [showKey, setShowKey] = useState(false);
  const [t5tConfig, setT5tConfig] = useState<T5TConfig>({
    vertical: "",
    region: "",
    jobFunction: "",
    subjectLine: "",
  });
  const [ttsVoice, setTtsVoice] = useState<TTSVoice>("nova");
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    (async () => {
      const p = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
      const m = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";
      const t = (await getSetting("meeting_template")) || "auto";
      setProvider(p);
      setTemplate(t as MeetingTemplate);

      const validModels = POPULAR_MODELS[p];
      const isValid = validModels.some((vm) => vm.id === m);
      if (isValid) {
        setModel(m);
      } else {
        setModel(validModels[0]?.id || m);
      }

      const configured = { ...configuredKeys };
      for (const k of Object.keys(configured) as LLMProvider[]) {
        configured[k] = await isSettingConfigured(`api_key_${k}`);
      }
      setConfiguredKeys(configured);

      const tc = await getT5TConfig();
      setT5tConfig(tc);

      const tv = (await getSetting("tts_voice")) || "nova";
      setTtsVoice(tv as TTSVoice);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const saveAll = async () => {
    await setSetting("llm_provider", provider);
    await setSetting("llm_model", customModel || model);
    await setSetting("meeting_template", template);
    for (const [k, v] of Object.entries(apiKeys)) {
      if (v) {
        await setSetting(`api_key_${k}`, v);
      }
    }
    setConfiguredKeys((prev) => {
      const next = { ...prev };
      for (const [k, v] of Object.entries(apiKeys) as [LLMProvider, string][]) {
        if (v) next[k] = true;
      }
      return next;
    });
    setApiKeys({ openrouter: "", anthropic: "", openai: "", nvidia: "" });
    await saveT5TConfig(t5tConfig);
    await setSetting("tts_voice", ttsVoice);
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  };

  return (
    <div className="h-full flex">
      {/* Left tabs */}
      <div className="w-[160px] bg-sidebar/50 border-r border-border flex flex-col pt-4">
        <h2 className="text-[11px] font-medium text-text-tertiary uppercase tracking-wide px-4 mb-2">
          Settings
        </h2>
        {TABS.map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            onClick={() => setTab(id)}
            className={`flex items-center gap-2 px-3 py-1.5 mx-2 rounded-md text-left text-[13px] transition-colors ${
              tab === id
                ? "bg-accent/80 text-white"
                : "text-text-secondary hover:bg-hover"
            }`}
          >
            <Icon className="w-[13px] h-[13px]" />
            {label}
          </button>
        ))}
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto p-8">
        <div className="max-w-xl">
          {tab === "ai" && (
            <div className="space-y-8">
              <Section title="Summarization Provider">
                <select
                  value={provider}
                  onChange={(e) => {
                    const p = e.target.value as LLMProvider;
                    setProvider(p);
                    const models = POPULAR_MODELS[p];
                    if (models.length > 0) setModel(models[0].id);
                  }}
                  className="w-full"
                >
                  {(Object.keys(LLM_PROVIDERS) as LLMProvider[]).map((p) => (
                    <option key={p} value={p}>
                      {LLM_PROVIDERS[p].displayName}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-text-tertiary mt-1.5">
                  {provider === "openrouter" &&
                    "Routes to 100+ models from Anthropic, OpenAI, Google, Meta, Mistral, DeepSeek, and more through a single API key."}
                  {provider === "anthropic" &&
                    "Direct connection to Anthropic's Claude models."}
                  {provider === "openai" &&
                    "Direct connection to OpenAI's GPT models."}
                  {provider === "nvidia" &&
                    "NVIDIA Enterprise Inference Hub — access Claude, Nemotron, Llama, and more via inference.nvidia.com."}
                </p>
              </Section>

              <Section title={`API Key — ${LLM_PROVIDERS[provider].displayName}`}>
                <div className="relative">
	                  <input
	                    type={showKey ? "text" : "password"}
	                    value={apiKeys[provider]}
                    onChange={(e) =>
                      setApiKeys({ ...apiKeys, [provider]: e.target.value })
                    }
	                    placeholder={
	                      configuredKeys[provider]
	                        ? "Configured - enter a new key to replace"
	                        : `Enter ${LLM_PROVIDERS[provider].displayName} API key`
	                    }
	                    className="w-full pr-10"
	                  />
                  <button
                    onClick={() => setShowKey(!showKey)}
                    className="absolute right-2 top-1/2 -translate-y-1/2 text-text-tertiary hover:text-text-secondary"
                  >
                    {showKey ? (
                      <EyeOff className="w-4 h-4" />
                    ) : (
                      <Eye className="w-4 h-4" />
                    )}
                  </button>
                </div>
                <p className="text-xs text-text-tertiary mt-1.5">
                  {LLM_PROVIDERS[provider].keyHint}
                </p>
                {!apiKeys[provider] && !configuredKeys[provider] && (
                  <p className="text-xs text-orange-400 mt-1 flex items-center gap-1">
                    ⚠ Required for AI features
                  </p>
                )}
              </Section>

              <Section title="Model">
                <select
                  value={model}
                  onChange={(e) => setModel(e.target.value)}
                  className="w-full"
                >
                  {POPULAR_MODELS[provider].map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.name}
                    </option>
                  ))}
                </select>
                {provider === "openrouter" && (
                  <div className="mt-2">
                    <input
                      type="text"
                      value={customModel}
                      onChange={(e) => setCustomModel(e.target.value)}
                      placeholder="Or enter model ID (e.g. anthropic/claude-opus-4)"
                      className="w-full font-mono text-xs"
                    />
                  </div>
                )}
              </Section>

              <Section title="Meeting Format">
                <select
                  value={template}
                  onChange={(e) =>
                    setTemplate(e.target.value as MeetingTemplate)
                  }
                  className="w-full"
                >
                  {(
                    Object.entries(MEETING_TEMPLATES) as [
                      MeetingTemplate,
                      (typeof MEETING_TEMPLATES)[MeetingTemplate],
                    ][]
                  ).map(([key, val]) => (
                    <option key={key} value={key}>
                      {val.displayName}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-text-tertiary mt-1.5">
                  {MEETING_TEMPLATES[template].promptInstruction}
                </p>
              </Section>

              <Section title="Read Aloud Voice">
                <select
                  value={ttsVoice}
                  onChange={(e) => setTtsVoice(e.target.value as TTSVoice)}
                  className="w-full capitalize"
                >
                  {TTS_VOICES.map((v) => (
                    <option key={v} value={v}>
                      {v.charAt(0).toUpperCase() + v.slice(1)}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-text-tertiary mt-1.5">
                  Voice used for Read Aloud (TTS). Uses gpt-4o-mini-tts via
                  your NVIDIA or OpenAI key.
                </p>
              </Section>
            </div>
          )}

          {tab === "general" && (
            <div className="space-y-8">
              <Section title="Application">
                <p className="text-sm text-text-secondary">
                  NoteAI Web stores all data in a secure cloud database
                  (Turso). AI features (transcription and summarization) call
                  the configured LLM provider. API keys are stored server-side
                  and never exposed to the browser during AI requests.
                </p>
              </Section>
              <Section title="Keyboard Shortcuts">
                <div className="space-y-2 text-sm text-text-secondary">
                  <div className="flex justify-between">
                    <span>Toggle recording</span>
                    <kbd className="px-2 py-0.5 rounded bg-hover text-xs font-mono text-text-tertiary">
                      Ctrl+Shift+R
                    </kbd>
                  </div>
                  <div className="flex justify-between">
                    <span>Toggle AI chat</span>
                    <kbd className="px-2 py-0.5 rounded bg-hover text-xs font-mono text-text-tertiary">
                      Ctrl+Shift+C
                    </kbd>
                  </div>
                  <div className="flex justify-between">
                    <span>Search</span>
                    <kbd className="px-2 py-0.5 rounded bg-hover text-xs font-mono text-text-tertiary">
                      Ctrl+K
                    </kbd>
                  </div>
                </div>
              </Section>
            </div>
          )}

          {tab === "privacy" && (
            <div className="space-y-8">
              <Section title="Data Storage">
                <p className="text-sm text-text-secondary">
                  All data is stored in a password-protected Turso database.
                  Audio recordings are sent to the configured transcription
                  provider for processing and are not permanently stored.
                  API keys are kept server-side and never sent to the browser
                  during AI requests.
                </p>
              </Section>
              <Section title="Data Management">
                <button
                  onClick={async () => {
                    if (
                      confirm(
                        "Delete ALL data? This cannot be undone."
                      )
                    ) {
                      await db.meetings.clear();
                      await db.notes.clear();
                      await db.tasks.clear();
                      await db.t5tReports.clear();
                      await db.chatMessages.clear();
                      triggerRefresh();
                      window.location.reload();
                    }
                  }}
                  className="px-4 py-2 rounded-md bg-danger/20 text-danger text-sm hover:bg-danger/30 transition-colors"
                >
                  Delete All Data
                </button>
              </Section>
            </div>
          )}

          {tab === "t5t" && (
            <div className="space-y-8">
              <Section title="T5T Report Defaults">
                <div className="space-y-3">
                  <div>
                    <label className="text-xs text-text-tertiary block mb-1">
                      Vertical
                    </label>
                    <input
                      type="text"
                      value={t5tConfig.vertical}
                      onChange={(e) =>
                        setT5tConfig({
                          ...t5tConfig,
                          vertical: e.target.value,
                        })
                      }
                      placeholder="e.g. Cloud & Enterprise"
                      className="w-full"
                    />
                  </div>
                  <div>
                    <label className="text-xs text-text-tertiary block mb-1">
                      Region
                    </label>
                    <input
                      type="text"
                      value={t5tConfig.region}
                      onChange={(e) =>
                        setT5tConfig({
                          ...t5tConfig,
                          region: e.target.value,
                        })
                      }
                      placeholder="e.g. Americas"
                      className="w-full"
                    />
                  </div>
                  <div>
                    <label className="text-xs text-text-tertiary block mb-1">
                      Job Function
                    </label>
                    <input
                      type="text"
                      value={t5tConfig.jobFunction}
                      onChange={(e) =>
                        setT5tConfig({
                          ...t5tConfig,
                          jobFunction: e.target.value,
                        })
                      }
                      placeholder="e.g. Solutions Architect"
                      className="w-full"
                    />
                  </div>
                  <div>
                    <label className="text-xs text-text-tertiary block mb-1">
                      Subject Line
                    </label>
                    <input
                      type="text"
                      value={t5tConfig.subjectLine}
                      onChange={(e) =>
                        setT5tConfig({
                          ...t5tConfig,
                          subjectLine: e.target.value,
                        })
                      }
                      placeholder="e.g. Weekly T5T Report"
                      className="w-full"
                    />
                  </div>
                </div>
              </Section>
            </div>
          )}

          {tab === "export" && (
            <div className="space-y-8">
              <Section title="Export Data">
                <div className="space-y-3">
                  <button
                    onClick={async () => {
                      const data = {
                        meetings: await db.meetings.toArray(),
                        notes: await db.notes.toArray(),
                        tasks: await db.tasks.toArray(),
                        t5tReports: await db.t5tReports.toArray(),
                      };
                      const blob = new Blob(
                        [JSON.stringify(data, null, 2)],
                        { type: "application/json" }
                      );
                      const url = URL.createObjectURL(blob);
                      const a = document.createElement("a");
                      a.href = url;
                      a.download = `noteai-export-${new Date().toISOString().slice(0, 10)}.json`;
                      a.click();
                      URL.revokeObjectURL(url);
                    }}
                    className="flex items-center gap-2 px-4 py-2 rounded-md bg-hover hover:bg-selected text-sm text-text-secondary transition-colors"
                  >
                    <Download className="w-4 h-4" />
                    Export All Data (JSON)
                  </button>
                  <p className="text-xs text-text-tertiary">
                    Downloads all meetings, notes, tasks, and T5T reports as a
                    JSON file.
                  </p>
                </div>
              </Section>
              <Section title="Import Data">
                <div className="space-y-3">
                  <input
                    type="file"
                    accept=".json"
                    onChange={async (e) => {
                      const file = e.target.files?.[0];
                      if (!file) return;
                      try {
                        const text = await file.text();
                        const data = JSON.parse(text);
                        if (data.meetings)
                          await db.meetings.bulkPut(data.meetings);
                        if (data.notes) await db.notes.bulkPut(data.notes);
                        if (data.tasks) await db.tasks.bulkPut(data.tasks);
                        if (data.t5tReports)
                          await db.t5tReports.bulkPut(data.t5tReports);
                        triggerRefresh();
                        alert(
                          `Imported: ${data.meetings?.length || 0} meetings, ${data.notes?.length || 0} notes, ${data.tasks?.length || 0} tasks, ${data.t5tReports?.length || 0} reports`
                        );
                      } catch {
                        alert("Invalid JSON file");
                      }
                    }}
                    className="text-sm text-text-secondary"
                  />
                  <p className="text-xs text-text-tertiary">
                    Import a previously exported NoteAI JSON file.
                  </p>
                </div>
              </Section>
            </div>
          )}

          {tab === "about" && (
            <div className="space-y-8">
              <Section title="NoteAI Web">
                <div className="space-y-2 text-sm text-text-secondary">
                  <p>
                    <strong className="text-text-primary">Version:</strong>{" "}
                    2.0
                  </p>
                  <p>
                    NoteAI is a meeting intelligence tool that records, transcribes,
                    and summarizes your meetings with AI. This web version stores
                    data in a secure cloud database with password-protected access.
                  </p>
                  <p className="text-text-tertiary text-xs mt-4">
                    Built with Next.js, Tailwind CSS, Turso, and Tiptap.
                  </p>
                </div>
              </Section>
            </div>
          )}

          {/* Save button (global) */}
          <div className="mt-8 pt-6 border-t border-border">
            <button
              onClick={saveAll}
              className="flex items-center gap-2 px-4 py-2 rounded-md bg-accent text-white text-sm font-medium hover:bg-accent/80 transition-colors"
            >
              {saved ? (
                <>
                  <Loader2 className="w-4 h-4" />
                  Saved!
                </>
              ) : (
                <>
                  <Save className="w-4 h-4" />
                  Save Settings
                </>
              )}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <h3 className="text-sm font-medium text-text-primary mb-3">{title}</h3>
      {children}
    </div>
  );
}
