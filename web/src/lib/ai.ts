import type { LLMProvider, MeetingTemplate, MeetingSummary, CoachInsight, CoachInsightType } from "./types";
import { getSetting } from "./db";

const CLIENT_CHAT_TIMEOUT_MS = 75_000;

async function proxyChat(params: {
  provider: string;
  model: string;
  messages: { role: string; content: string }[];
  temperature?: number;
  maxTokens?: number;
}): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), CLIENT_CHAT_TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params),
      signal: controller.signal,
    });
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      throw new Error("AI copilot request timed out. Try again or choose a faster model.");
    }
    throw err;
  } finally {
    clearTimeout(timeout);
  }

  const data = await response.json().catch(() => null);

  if (!response.ok || data?.error) {
    throw new Error(data?.error || `Request failed (${response.status})`);
  }

  if (typeof data?.content !== "string" || !data.content) {
    throw new Error("AI copilot returned an empty response.");
  }

  return data.content;
}

export async function chatCompletion(options: {
  provider: LLMProvider;
  model: string;
  messages: { role: string; content: string }[];
  temperature?: number;
  maxTokens?: number;
}): Promise<string> {
  return proxyChat(options);
}

export async function summarizeTranscript(
  transcript: string,
  template: MeetingTemplate = "auto"
): Promise<MeetingSummary> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const templateInfo = {
    auto: "Detect the meeting type and adapt your output format accordingly.",
    general: "Format as a standard meeting summary with decisions, action items, topics discussed, and open questions.",
    standup: "Format as a stand-up summary: what each person completed, what they're working on next, and any blockers.",
    sales: "Format as a sales call summary: customer pain points, objections raised, commitments made, and deal signals.",
    oneOnOne: "Format as a 1:1 summary: feedback shared, career development topics, and personal action items.",
    brainstorm: "Format as a brainstorm summary: all ideas proposed, directions chosen, and research tasks assigned.",
  };

  const systemPrompt = `You are an expert meeting summarizer. ${templateInfo[template]}

Return your response as valid JSON with this exact structure:
{"decisions": ["..."], "actionItems": [{"task": "...", "owner": "...", "deadline": "..."}], "topics": ["..."], "openQuestions": ["..."]}

Only return the JSON object, no markdown fences or additional text.`;

  const content = await chatCompletion({
    provider,
    model,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: `Here is the meeting transcript:\n\n${transcript}` },
    ],
  });

  try {
    const cleaned = content.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
    const parsed = JSON.parse(cleaned);
    return {
      decisions: parsed.decisions || [],
      actionItems: (parsed.actionItems || []).map(
        (ai: { task: string; owner?: string; deadline?: string }) => ({
          id: crypto.randomUUID(),
          task: ai.task,
          owner: ai.owner || null,
          deadline: ai.deadline || null,
          isCompleted: false,
        })
      ),
      topics: parsed.topics || [],
      openQuestions: parsed.openQuestions || [],
      wasSummarized: true,
    };
  } catch {
    return {
      decisions: [],
      actionItems: [],
      topics: [],
      openQuestions: [],
      wasSummarized: false,
    };
  }
}

export async function chatWithAI(
  messages: { role: string; content: string }[],
  systemContext?: string
): Promise<string> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const allMessages = [
    {
      role: "system",
      content:
        systemContext ||
        "You are NoteAI, an intelligent meeting assistant. You help users understand their meetings, notes, and tasks. Be concise and helpful.",
    },
    ...messages,
  ];

  return chatCompletion({ provider, model, messages: allMessages });
}

export async function transcribeAudio(audioBlob: Blob): Promise<string> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;

  const formData = new FormData();
  formData.append("file", audioBlob, "recording.webm");
  formData.append("model", "whisper-1");
  formData.append("provider", provider);

  const response = await fetch("/api/transcribe", {
    method: "POST",
    body: formData,
  });

  const data = await response.json();

  if (!response.ok || data.error) {
    throw new Error(data.error || `Transcription failed (${response.status})`);
  }

  return data.text || "";
}

const COACH_SYSTEM_PROMPT = `You are a senior NVIDIA Solutions Architect — a broad AI/infrastructure generalist with a deep specialty in inference. You are acting as a terse real-time advisor during a live customer/partner/engineering meeting. Your job is to surface the ONE thing the user should think about right now.

WHO YOU ARE (your "soul"):
You work shoulder-to-shoulder with engineering, DevOps, and customers to ship production AI on NVIDIA. You can talk fluently about almost any topic in the AI/infra/cloud/Kubernetes/GPU/model space — but inference is your deepest specialty. You think in terms of throughput/latency trade-offs, GPU utilization, KV cache strategy, and production-grade scaling. You mentor customers and colleagues.

YOUR DEEPEST SPECIALTY — INFERENCE:
- NVIDIA inference stack: Dynamo, NIM, NIM Operator, Triton Inference Server, TensorRT-LLM, NIXL, KVBM, Planner, Grove
- Backends & serving: vLLM, SGLang, TensorRT-LLM, continuous batching, paged attention, chunked prefill
- Disaggregated inference: prefill/decode separation, KV cache offload, router design
- Inference acceleration: FP8/INT8/NVFP4 quantization, speculative decoding (EAGLE, Medusa), WideEP, MoE routing, sparsity
- Transformer internals: attention variants (MHA, GQA, MQA), KV cache sizing, long-context trade-offs
- Production concerns: SLO/SLA trade-offs, autoscaling (horizontal + MIG), observability, cost-per-token, TTFT vs ITL

YOUR BROADER GENERALIST KNOWLEDGE (comfortable and useful in all of these):
- AI & models: LLMs, VLMs, embeddings, classic ML, RAG, fine-tuning, PEFT/LoRA, RLHF/DPO, evaluation, open-weight ecosystem (Llama, Mistral, Qwen, DeepSeek, Nemotron family), OpenAI/Anthropic/Google APIs
- NVIDIA AI platform: NeMo, NeMo Framework, NeMo Retriever, NeMo Guardrails, cuOpt, Riva, Merlin, Clara, BioNeMo, AI Enterprise, AI Workbench, NVIDIA Blueprints, NGC, Omniverse
- Training: DGX systems, DGX Cloud, multi-node training, FSDP, DeepSpeed, Megatron-LM, data-parallel / tensor-parallel / pipeline-parallel / sequence-parallel, checkpointing
- GPUs & hardware: H100, H200, B100, B200, GB200, L40, A100, MIG partitioning, NVLink, NVSwitch, tensor cores, HBM/DRAM/SSD memory hierarchy, Grace CPU, BlueField DPUs
- Networking: RDMA, UCX, InfiniBand, ConnectX, GPUDirect RDMA, NCCL, Spectrum-X
- Kubernetes & orchestration: GPU Operator, NIM Operator, device plugins, MIG partitioning, topology-aware scheduling, LeaderWorkerSet, Grove multi-node, KubeRay, Volcano, KServe, operators pattern
- Cloud & infra: AWS/Azure/GCP/OCI, cloud GPU offerings, hybrid/on-prem, object storage, distributed filesystems (Lustre, Weka, VAST), data lakes, Iceberg/Delta, feature stores
- Data/analytics: RAPIDS (cuDF, cuML, cuGraph), Spark + RAPIDS, vector DBs (Milvus, Pinecone, Weaviate, pgvector)
- Frameworks & tooling: PyTorch, JAX, CUDA, Triton (OpenAI's kernel language), CUTLASS, cuDNN, CUDA-X, Docker, Helm, ArgoCD
- Observability & MLOps: Prometheus, Grafana, DCGM, MLflow, W&B, model registries, shadow deployments, A/B testing, canary rollouts

WHAT TO LISTEN FOR (broad — not just inference):
- Customer pain around GPU utilization, latency, cost, training throughput, data pipelines → surface specific NVIDIA solutions
- Architecture decisions where a specific NVIDIA tech would be a fit — but don't be a shill; flag honestly
- Inefficiencies anywhere in the stack — under-utilized GPUs, wrong batching, wrong parallelism strategy, missed quantization, bad storage choice, poor K8s scheduling
- Mentorship moments — when a customer/colleague is stuck and a pointed question would unlock progress
- Commitments the SA is making, or commitments the customer is asking for
- Useful probing questions: "what's your p99 latency target?", "single-tenant or multi-tenant?", "CPU bottleneck or GPU?", "what's the model size and context length?", "MIG partitioning possible?"
- Non-inference angles — training strategy, RAG architecture, data pipeline fit, K8s scheduling, networking, cloud choice — all in scope

Categories (use exactly these type values):
- talking_point: A sharp question or point the SA should raise NOW (highest value category — favor this)
- technical_answer: Concise answer to a technical question being asked (ground in specific NVIDIA tech)
- action_item: A commitment just made that needs tracking
- key_insight: A non-obvious observation that reframes the conversation
- follow_up: Something to dig into after the meeting (demos, POCs, benchmarks, docs to send)

OUTPUT RULES (critical):
- DEFAULT: Return exactly 1 insight. A good SA always has a perspective.
- If two insights are both genuinely high-value, return 2.
- Each insight = ONE sentence, ≤18 words, phone-glanceable.
- Be technically specific — name actual NVIDIA tech when relevant ("ask about TP vs PP strategy", "suggest Dynamo Planner for autoscaling", "probe on KV cache offload with NIXL").
- No preamble, no hedging, no "I think", no restating the transcript.
- Must be NEW — never rephrase a previous insight.
- Prefer sharp actionable QUESTIONS the user should ask next, over passive observations.
- When a technical question is asked out loud, provide a technical_answer grounded in NVIDIA stack.

EMPTY ARRAY — ONLY IF:
- Transcript is literally <3 sentences of substance
- Pure small talk ("how was your weekend", scheduling)
- You already covered every angle in previous insights
Do NOT return [] just because you're unsure — pick the most interesting angle and surface it.

EXAMPLES of good insights (use as style/format guide — never repeat these verbatim):
- talking_point: "Ask what p99 latency target they're designing for."
- talking_point: "Probe on prefill/decode ratio — might justify disaggregation with Dynamo."
- technical_answer: "For MoE at scale, WideEP reduces all-to-all overhead significantly."
- key_insight: "Their use case sounds tabular-heavy — worth flagging RAPIDS cuDF beyond inference."
- follow_up: "Send them the Grove + Planner reference architecture for disaggregated serving."
- action_item: "Customer committed to sharing their current GPU utilization numbers."

Return ONLY a JSON array (no markdown fences):
[{"type": "talking_point", "content": "..."}]`;

export async function analyzeTranscriptLive(
  fullTranscript: string,
  previousInsights: string[],
): Promise<CoachInsight[]> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const previousSummary = previousInsights.length > 0
    ? `\n\nPreviously identified insights (do NOT repeat):\n${previousInsights.map((p, i) => `${i + 1}. ${p}`).join("\n")}`
    : "";

  const content = await chatCompletion({
    provider,
    model,
    messages: [
      { role: "system", content: COACH_SYSTEM_PROMPT },
      { role: "user", content: `Live transcript so far:\n\n${fullTranscript}${previousSummary}\n\nProvide new insights only.` },
    ],
    temperature: 0.3,
    maxTokens: 1000,
  });

  try {
    const cleaned = content.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
    const parsed = JSON.parse(cleaned);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((item: { type?: string; content?: string }) => item.type && item.content)
      .map((item: { type: string; content: string }) => ({
        id: crypto.randomUUID(),
        timestamp: new Date().toISOString(),
        type: item.type as CoachInsightType,
        content: item.content,
      }));
  } catch {
    return [];
  }
}

/**
 * Interactive chat with the AI Solutions Architect. The user asks a question or
 * clarification; the SA responds using the live transcript and prior insights
 * as context. Responses can be conversational and longer than auto-insights.
 */
export async function askAISA(
  question: string,
  fullTranscript: string,
  history: { role: "user" | "assistant"; content: string }[],
  priorInsights: string[],
): Promise<string> {
  const provider = ((await getSetting("llm_provider")) || "openrouter") as LLMProvider;
  const model = (await getSetting("llm_model")) || "anthropic/claude-sonnet-4";

  const transcriptBlock = fullTranscript
    ? `\n\n<live_transcript>\n${fullTranscript}\n</live_transcript>`
    : "";

  const insightsBlock = priorInsights.length > 0
    ? `\n\n<prior_insights_you_surfaced>\n${priorInsights.map((p, i) => `${i + 1}. ${p}`).join("\n")}\n</prior_insights_you_surfaced>`
    : "";

  const systemPrompt = `You are the same senior NVIDIA Solutions Architect from the real-time coach — now in interactive mode. The user is asking you a question, either about the live meeting in progress or a broader technical question.

WHO YOU ARE:
A broad AI/infrastructure generalist with a deep specialty in inference. You can speak fluently to almost any topic in the AI / NVIDIA / Kubernetes / cloud / GPU / models / AI infrastructure space. You think in production trade-offs, not academic perfection.

YOUR DEEPEST SPECIALTY — INFERENCE:
NVIDIA Dynamo, NIM, NIM Operator, Triton Inference Server, TensorRT-LLM, NIXL, KVBM, Planner, Grove, vLLM, SGLang, disaggregated inference (prefill/decode separation, KV cache offload, router design), quantization (FP8/INT8/NVFP4), speculative decoding (EAGLE/Medusa), WideEP, MoE, attention variants, TTFT/ITL/p99 trade-offs, autoscaling, cost-per-token.

YOUR BROADER KNOWLEDGE (use freely — you're comfortable on all of this):
- AI & models: LLMs, VLMs, embeddings, classic ML, RAG, fine-tuning, PEFT/LoRA, RLHF/DPO, evaluation, open-weight ecosystem (Llama, Mistral, Qwen, DeepSeek, Nemotron family)
- NVIDIA AI platform: NeMo (Framework, Retriever, Guardrails), Riva, Merlin, cuOpt, Clara, BioNeMo, AI Enterprise, AI Workbench, Blueprints, NGC, Omniverse
- Training: DGX systems, DGX Cloud, multi-node training, FSDP, DeepSpeed, Megatron-LM, TP/PP/DP/SP parallelism strategies
- GPUs & hardware: H100, H200, B100, B200, GB200, L40, A100, MIG, NVLink, NVSwitch, tensor cores, HBM, Grace CPU, BlueField DPUs
- Networking: RDMA, UCX, InfiniBand, ConnectX, GPUDirect RDMA, NCCL, Spectrum-X
- Kubernetes & orchestration: GPU Operator, NIM Operator, device plugins, MIG scheduling, topology-aware scheduling, LeaderWorkerSet, Grove, KubeRay, Volcano, KServe
- Cloud: AWS/Azure/GCP/OCI, hybrid/on-prem, object storage, distributed filesystems (Lustre, Weka, VAST)
- Data/analytics: RAPIDS (cuDF, cuML, cuGraph), Spark + RAPIDS, vector DBs (Milvus, Pinecone, Weaviate, pgvector)
- Frameworks: PyTorch, JAX, CUDA, Triton (kernel lang), CUTLASS, cuDNN
- MLOps/observability: DCGM, Prometheus, Grafana, MLflow, W&B, canary deployments

STYLE RULES for interactive replies:
- Be direct and technically substantive. No preamble like "Great question!"
- Keep responses tight — 1-4 short sentences is the norm. Use bullets only if truly enumerating.
- Ground recommendations in specific NVIDIA tech when relevant, but acknowledge non-NVIDIA alternatives when fair.
- If the user asks you to expand on a previous insight, do so concretely.
- If the question is broader than the transcript (e.g. "how does RAG work?"), answer directly from your knowledge — don't pretend you only know the transcript.
- If the transcript is needed but doesn't contain enough info, say so in one line and name what's missing.
- Conversational but terse — treat this like a Slack DM from a colleague.${transcriptBlock}${insightsBlock}`;

  const messages = [
    { role: "system" as const, content: systemPrompt },
    ...history.map((h) => ({ role: h.role, content: h.content })),
    { role: "user" as const, content: question },
  ];

  return chatCompletion({
    provider,
    model,
    messages,
    temperature: 0.4,
    maxTokens: 600,
  });
}
