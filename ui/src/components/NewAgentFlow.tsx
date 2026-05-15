import { useEffect, useRef, useState } from "react";
import type { ComponentType, SVGProps } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Button, Spinner } from "@heroui/react";
import { ChevronLeft, Check } from "lucide-react";
import { TYPE_ICON, CHANNEL_ICON } from "./icons";

type IconComponent = ComponentType<{ className?: string } & SVGProps<SVGSVGElement>>;

interface Props {
  onExit: () => void;
  onCreated: () => void;
}

const TYPES = ["claude", "codex", "gemini", "hermes", "openclaw", "opencode"] as const;
type AgentType = typeof TYPES[number];

const TYPE_BLURB: Record<AgentType, string> = {
  claude:   "Anthropic's coding agent — recommended.",
  codex:    "OpenAI's coding agent.",
  gemini:   "Google's coding agent.",
  hermes:   "Open-source agent — bring your own provider.",
  openclaw: "Open-source agent — bring your own provider.",
  opencode: "Open-source agent backed by your OpenAI key.",
};

const RECOMMENDED: AgentType = "claude";

const ISOLATION_OPTIONS = [
  { value: "admin",     label: "Admin",     desc: "Full server access. Use for trusted local work." },
  { value: "standard",  label: "Standard",  desc: "Read-only /home/claude. Safe default for most agents." },
  { value: "sandboxed", label: "Sandboxed", desc: "Own home dir only. Best for untrusted prompts." },
] as const;
type IsolationLevel = typeof ISOLATION_OPTIONS[number]["value"];

const OAUTH_TYPES = new Set<AgentType>(["claude"]);
const CHANNEL_SUPPORTED = new Set<AgentType>(["claude", "hermes", "openclaw"]);
const PROVIDER_TYPES = new Set<AgentType>(["hermes", "openclaw"]);

const PROVIDERS = [
  "openrouter", "anthropic", "openai", "google", "deepseek",
  "qwen", "nous", "minimax", "moonshot", "huggingface", "zai",
] as const;

const PROVIDER_KEY_LABELS: Record<string, string> = {
  openrouter:  "OpenRouter API key",
  anthropic:   "Anthropic API key",
  openai:      "OpenAI API key",
  google:      "Google AI API key",
  deepseek:    "DeepSeek API key",
  qwen:        "Qwen API key",
  nous:        "Nous API key",
  minimax:     "Minimax API key",
  moonshot:    "Moonshot API key",
  huggingface: "HuggingFace API key",
  zai:         "Zai API key",
};

const PROVIDER_KEY_PLACEHOLDERS: Record<string, string> = {
  openrouter:  "sk-or-v1-…",
  anthropic:   "sk-ant-…",
  openai:      "sk-…",
  google:      "AIza…",
  deepseek:    "sk-…",
  qwen:        "sk-…",
  nous:        "sk-…",
  minimax:     "sk-…",
  moonshot:    "sk-…",
  huggingface: "hf_…",
  zai:         "sk-…",
};

const PROVIDER_DOCS: Record<string, string> = {
  openrouter:  "https://openrouter.ai/keys",
  anthropic:   "https://console.anthropic.com/settings/keys",
  openai:      "https://platform.openai.com/api-keys",
  google:      "https://aistudio.google.com/apikey",
  deepseek:    "https://platform.deepseek.com",
  qwen:        "https://dashscope.aliyuncs.com",
  nous:        "https://dashboard.nous.research.ai",
  minimax:     "https://www.minimax.io",
  moonshot:    "https://platform.moonshot.cn",
  huggingface: "https://huggingface.co/settings/tokens",
  zai:         "https://platform.zhipuai.cn",
};

const AUTH_HELP: Record<AgentType, { label: string; placeholder: string; docsUrl: string }> = {
  claude:   { label: "Anthropic API key (optional)", placeholder: "sk-ant-api03-…", docsUrl: "https://console.anthropic.com/settings/keys" },
  codex:    { label: "OpenAI API key",   placeholder: "sk-…",      docsUrl: "https://platform.openai.com/api-keys" },
  gemini:   { label: "Gemini API key",   placeholder: "AIza…",     docsUrl: "https://aistudio.google.com/apikey" },
  hermes:   { label: "API key",          placeholder: "sk-…",      docsUrl: "https://openrouter.ai/keys" },
  openclaw: { label: "API key",          placeholder: "sk-…",      docsUrl: "https://openrouter.ai/keys" },
  opencode: { label: "OpenAI API key",   placeholder: "sk-…",      docsUrl: "https://platform.openai.com/api-keys" },
};

const NAME_RE = /^[a-z][a-z0-9-]{0,15}$/;
const NAME_HINT = "Lowercase letters, digits and hyphens. Starts with a letter. Max 16 chars.";

type Step =
  | "agent"
  | "name"
  | "isolation"
  | "provider"
  | "auth"
  | "channel"
  | "token"
  | "creating";

type ChannelId = "none" | "telegram" | "discord";

function stepsFor(type: AgentType | null, authNeeded: boolean): Step[] {
  const steps: Step[] = ["agent", "name", "isolation"];
  if (type && PROVIDER_TYPES.has(type)) steps.push("provider");
  if (authNeeded) steps.push("auth");
  if (type && CHANNEL_SUPPORTED.has(type)) steps.push("channel");
  return steps;
}

export function NewAgentFlow({ onExit, onCreated }: Props) {
  const [step, setStep] = useState<Step>("agent");

  const [type, setType] = useState<AgentType | null>(null);
  const [name, setName] = useState("");
  const [isolation, setIsolation] = useState<IsolationLevel>("admin");
  const [channel, setChannel] = useState<ChannelId>("none");
  const [channelToken, setChannelToken] = useState("");

  // Auth state
  const [authNeeded, setAuthNeeded] = useState(false);
  const [apiKey, setApiKey] = useState("");
  const [provider, setProvider] = useState<string>("openrouter");
  const [oauthUrl, setOauthUrl] = useState<string | null>(null);
  const [oauthPolling, setOauthPolling] = useState(false);

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const autoAdvanceTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => {
    if (autoAdvanceTimer.current) clearTimeout(autoAdvanceTimer.current);
  }, []);

  useEffect(() => {
    if (!type) return;
    let cancelled = false;
    fetch(`/api/auth/${type}`)
      .then(r => r.json())
      .then((j: { ok: boolean; data?: Record<string, string> }) => {
        if (cancelled) return;
        const status = j.ok ? (j.data?.[type] ?? "needs_login") : "needs_login";
        setAuthNeeded(status !== "ok");
      })
      .catch(() => {});
    if (!CHANNEL_SUPPORTED.has(type)) setChannel("none");
    return () => { cancelled = true; };
  }, [type]);

  /* ------------------------- step navigation ------------------------- */

  const stepAfterIsolation = (t: AgentType): Step => {
    if (PROVIDER_TYPES.has(t)) return "provider";
    if (authNeeded) return "auth";
    if (CHANNEL_SUPPORTED.has(t)) return "channel";
    return "creating";
  };

  const stepAfterProvider = (t: AgentType): Step => {
    if (authNeeded) return "auth";
    if (CHANNEL_SUPPORTED.has(t)) return "channel";
    return "creating";
  };

  const stepAfterAuth = (t: AgentType): Step => {
    if (CHANNEL_SUPPORTED.has(t)) return "channel";
    return "creating";
  };

  const stepBefore = (s: Step): Step | "exit" => {
    if (s === "agent") return "exit";
    if (s === "name") return "agent";
    if (s === "isolation") return "name";
    if (s === "provider") return "isolation";
    if (s === "auth") {
      if (type && PROVIDER_TYPES.has(type)) return "provider";
      return "isolation";
    }
    if (s === "channel") {
      if (authNeeded) return "auth";
      if (type && PROVIDER_TYPES.has(type)) return "provider";
      return "isolation";
    }
    if (s === "token") return "channel";
    return "exit";
  };

  const backLabel = (() => {
    switch (step) {
      case "name":      return "Change agent";
      case "isolation": return "Rename agent";
      case "provider":  return "Change isolation";
      case "auth":      return type && PROVIDER_TYPES.has(type) ? "Change provider" : "Change isolation";
      case "channel":   return authNeeded ? "Change sign-in"
                                : type && PROVIDER_TYPES.has(type) ? "Change provider"
                                : "Change isolation";
      case "token":     return "Change channel";
      default:          return "My Agents";
    }
  })();

  const handleBack = () => {
    if (step === "creating") return;
    setError(null);
    const prev = stepBefore(step);
    if (prev === "exit") onExit();
    else setStep(prev);
  };

  /* ---------------------------- handlers ----------------------------- */

  const handleAgentSelect = (t: AgentType) => {
    setType(t);
    if (autoAdvanceTimer.current) clearTimeout(autoAdvanceTimer.current);
    autoAdvanceTimer.current = setTimeout(() => setStep("name"), 320);
  };

  const handleNameContinue = () => {
    setError(null);
    if (!NAME_RE.test(name)) {
      setError(NAME_HINT);
      return;
    }
    setStep("isolation");
  };

  const handleIsolationContinue = () => {
    if (!type) return;
    setStep(stepAfterIsolation(type));
  };

  const handleProviderContinue = () => {
    if (!type) return;
    setStep(stepAfterProvider(type));
  };

  const handleChannelContinue = () => {
    if (channel === "telegram") setStep("token");
    else setStep("creating");
  };

  const handleTokenContinue = () => {
    if (!channelToken.trim()) {
      setError("Telegram bot token is required");
      return;
    }
    setStep("creating");
  };

  // OAuth flow for claude
  const startOAuth = async () => {
    if (!type) return;
    setError(null);
    setBusy(true);
    try {
      const res = await fetch(`/api/auth/${type}/start`, { method: "POST" });
      const j = await res.json();
      if (!j.ok) {
        setError(typeof j.error === "string" ? j.error : (j.error?.message ?? "Failed to start login"));
        return;
      }
      setOauthPolling(true);
      pollOAuth(j.data.sessionId);
    } finally {
      setBusy(false);
    }
  };

  const pollOAuth = (sessionId: string) => {
    if (!type) return;
    const interval = setInterval(async () => {
      try {
        const res = await fetch(`/api/auth/${type}/poll/${sessionId}`);
        const j = await res.json();
        if (!j.ok) return;
        const { state, url } = j.data as { state: string; url: string | null };
        if (url) setOauthUrl(url);
        if (state === "complete") {
          clearInterval(interval);
          setOauthPolling(false);
          setStep(stepAfterAuth(type));
        }
        if (state === "error") {
          clearInterval(interval);
          setOauthPolling(false);
          setError("Authentication failed");
        }
      } catch { /* keep polling */ }
    }, 2000);
  };

  const submitApiKey = async () => {
    if (!type) return;
    setError(null);
    if (!apiKey.trim()) { setError("API key is required"); return; }
    setBusy(true);
    try {
      const res = await fetch(`/api/auth/${type}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          apiKey: apiKey.trim(),
          ...(PROVIDER_TYPES.has(type) ? { provider } : {}),
        }),
      });
      const j = await res.json();
      if (!j.ok) {
        const e = j.error;
        setError(typeof e === "string" ? e : (e?.message ?? "Authentication failed"));
        return;
      }
      setStep(stepAfterAuth(type));
    } catch {
      setError("Network error");
    } finally {
      setBusy(false);
    }
  };

  // Final create — runs once when "creating" is reached.
  useEffect(() => {
    if (step !== "creating" || !type) return;
    let cancelled = false;
    (async () => {
      setBusy(true);
      try {
        const res = await fetch("/api/agents", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            name: name.trim(),
            type,
            isolation,
            channels: channel,
            telegramToken: channel === "telegram" ? channelToken : "",
          }),
        });
        const j = await res.json();
        if (cancelled) return;
        if (j.ok) {
          onCreated();
        } else {
          const e = j.error;
          setError(typeof e === "string" ? e : (e?.message ?? "Failed to create agent"));
          // Drop the user back into the channel step if a channel was set,
          // otherwise back to isolation. Avoid landing on auth because the
          // auth call already succeeded.
          setStep(CHANNEL_SUPPORTED.has(type) ? "channel" : "isolation");
        }
      } catch {
        if (cancelled) return;
        setError("Network error");
        setStep(CHANNEL_SUPPORTED.has(type) ? "channel" : "isolation");
      } finally {
        if (!cancelled) setBusy(false);
      }
    })();
    return () => { cancelled = true; };
  }, [step, type, name, isolation, channel, channelToken, onCreated]);

  /* ----------------------------- render ------------------------------ */

  const steps = stepsFor(type, authNeeded);

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-surface-page">
      {/* Soft signal glow */}
      <div className="pointer-events-none absolute inset-x-0 top-0 h-80 bg-[radial-gradient(ellipse_at_top,var(--color-signal-soft)_0%,transparent_70%)]" />

      <header className="relative z-10 flex items-center justify-between px-6 py-5 lg:px-10">
        <button
          type="button"
          onClick={handleBack}
          disabled={step === "creating"}
          className="flex items-center gap-1.5 text-[0.8125rem] text-ink-muted transition-colors hover:text-ink disabled:opacity-40"
        >
          <ChevronLeft className="size-4" />
          {backLabel}
        </button>
        {step !== "creating" && (
          <StepDots current={step} steps={steps} />
        )}
      </header>

      <main className="relative z-10 flex flex-1 items-start justify-center overflow-y-auto px-6 pb-16 pt-4 lg:px-10">
        <AnimatePresence mode="wait">
          {step === "agent" && (
            <AgentStep
              key="agent"
              selected={type}
              onSelect={handleAgentSelect}
            />
          )}
          {step === "name" && type && (
            <NameStep
              key="name"
              type={type}
              value={name}
              onChange={setName}
              error={error}
              onContinue={handleNameContinue}
            />
          )}
          {step === "isolation" && type && (
            <IsolationStep
              key="isolation"
              type={type}
              name={name}
              selected={isolation}
              onSelect={setIsolation}
              onContinue={handleIsolationContinue}
            />
          )}
          {step === "provider" && type && (
            <ProviderStep
              key="provider"
              type={type}
              selected={provider}
              onSelect={setProvider}
              onContinue={handleProviderContinue}
            />
          )}
          {step === "auth" && type && (
            <AuthStep
              key="auth"
              type={type}
              provider={provider}
              isOauth={OAUTH_TYPES.has(type)}
              apiKey={apiKey}
              onApiKeyChange={setApiKey}
              oauthUrl={oauthUrl}
              oauthPolling={oauthPolling}
              busy={busy}
              error={error}
              onStartOAuth={startOAuth}
              onSubmitKey={submitApiKey}
            />
          )}
          {step === "channel" && type && (
            <ChannelStep
              key="channel"
              type={type}
              selected={channel}
              onSelect={setChannel}
              onContinue={handleChannelContinue}
            />
          )}
          {step === "token" && (
            <TokenStep
              key="token"
              value={channelToken}
              onChange={setChannelToken}
              error={error}
              onContinue={handleTokenContinue}
            />
          )}
          {step === "creating" && (
            <CreatingStep key="creating" name={name} error={error} />
          )}
        </AnimatePresence>
      </main>
    </div>
  );
}

/* -------------------------------------------------------------------- */
/*  Reusable bits                                                       */
/* -------------------------------------------------------------------- */

function StepDots({ current, steps }: { current: Step; steps: Step[] }) {
  const idx = steps.indexOf(current);
  return (
    <div className="flex items-center gap-1.5">
      {steps.map((s, i) => (
        <div
          key={s}
          className={`h-1.5 rounded-full transition-all duration-300 ${
            i === idx ? "w-6 bg-signal" : i < idx ? "w-1.5 bg-signal/60" : "w-1.5 bg-border-hard"
          }`}
        />
      ))}
    </div>
  );
}

function StepShell({
  eyebrow,
  title,
  subtitle,
  children,
  maxWidth = "max-w-3xl",
}: {
  eyebrow?: string;
  title: string;
  subtitle?: string;
  children: React.ReactNode;
  maxWidth?: string;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.25 }}
      className={`flex w-full ${maxWidth} flex-col items-center text-center`}
    >
      {eyebrow && (
        <p className="mb-2 text-[0.75rem] font-semibold uppercase tracking-[0.15em] text-signal">
          {eyebrow}
        </p>
      )}
      <h1 className="mb-3 text-3xl font-semibold tracking-[-0.025em] text-ink sm:text-4xl">
        {title}
      </h1>
      {subtitle && (
        <p className="mb-10 max-w-md text-[0.9375rem] text-ink-secondary">
          {subtitle}
        </p>
      )}
      {children}
    </motion.div>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 1 — Pick agent                                                 */
/* -------------------------------------------------------------------- */

function AgentStep({
  selected,
  onSelect,
}: {
  selected: AgentType | null;
  onSelect: (t: AgentType) => void;
}) {
  return (
    <StepShell
      eyebrow="Add agent"
      title="Pick your agent"
      subtitle="Each one runs on this machine, signed into your account."
    >
      <div className="mb-8 grid w-full grid-cols-2 gap-3 sm:grid-cols-3">
        {TYPES.map((t, i) => {
          const Icon = TYPE_ICON[t] ?? TYPE_ICON.claude;
          const isSelected = selected === t;
          const isDimmed = selected !== null && selected !== t;
          const isRecommended = t === RECOMMENDED;
          return (
            <motion.button
              key={t}
              type="button"
              onClick={() => onSelect(t)}
              disabled={isDimmed}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: isDimmed ? 0.4 : 1, y: 0 }}
              transition={{ delay: i * 0.04, duration: 0.25 }}
              whileHover={isDimmed ? undefined : { y: -2 }}
              className={`relative flex flex-col items-center gap-3 rounded-2xl p-5 text-center transition-colors ${
                isSelected
                  ? "bg-signal-soft ring-1 ring-inset ring-signal/40"
                  : "bg-surface-card/60 hover:bg-surface-card"
              }`}
            >
              {isRecommended && !isSelected && (
                <span className="absolute left-1/2 top-3 -translate-x-1/2 text-[0.5625rem] font-semibold uppercase tracking-[0.15em] text-signal">
                  Recommended
                </span>
              )}
              {isSelected && (
                <motion.div
                  initial={{ scale: 0 }}
                  animate={{ scale: 1 }}
                  transition={{ type: "spring", stiffness: 500, damping: 22 }}
                  className="absolute right-3 top-3 flex size-5 items-center justify-center rounded-full bg-signal text-white"
                >
                  <Check className="size-3" />
                </motion.div>
              )}
              <div
                className={`mt-3 flex size-14 items-center justify-center rounded-2xl bg-white text-zinc-900 ring-1 ring-black/5 transition-shadow ${
                  isSelected
                    ? "shadow-[0_16px_40px_-16px_rgba(0,74,255,0.35)]"
                    : "shadow-[0_10px_30px_-15px_rgba(0,0,0,0.2)]"
                }`}
              >
                <Icon className="size-7" />
              </div>
              <div className="flex flex-col gap-1">
                <span className="text-[0.875rem] font-semibold tracking-[-0.005em] text-ink">
                  {t}
                </span>
                <span className="text-[0.75rem] text-ink-secondary">
                  {TYPE_BLURB[t]}
                </span>
              </div>
            </motion.button>
          );
        })}
      </div>
    </StepShell>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 2 — Name                                                       */
/* -------------------------------------------------------------------- */

function NameStep({
  type,
  value,
  onChange,
  error,
  onContinue,
}: {
  type: AgentType;
  value: string;
  onChange: (v: string) => void;
  error: string | null;
  onContinue: () => void;
}) {
  const Icon = TYPE_ICON[type] ?? TYPE_ICON.claude;
  const touched = value.length > 0;
  const valid = NAME_RE.test(value);
  const showError = (touched && !valid) || Boolean(error);

  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.25 }}
      className="flex w-full max-w-md flex-col items-center text-center"
    >
      <motion.div
        initial={{ scale: 0.9, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ duration: 0.3, ease: "easeOut" }}
        className="relative mb-6"
      >
        <div className="pointer-events-none absolute inset-0 -z-10 scale-150 rounded-full bg-signal/10 blur-3xl" />
        <div className="flex size-16 items-center justify-center rounded-2xl bg-white shadow-[0_20px_60px_-20px_rgba(0,0,0,0.25)] ring-1 ring-black/5">
          <Icon className="size-8 text-zinc-900" />
        </div>
      </motion.div>

      <p className="mb-2 text-[0.75rem] font-semibold uppercase tracking-[0.15em] text-signal">
        Name this {type}
      </p>
      <h1 className="mb-3 text-3xl font-semibold tracking-[-0.025em] text-ink sm:text-4xl">
        Give it a handle
      </h1>
      <p className="mb-8 max-w-sm text-[0.9375rem] text-ink-secondary">
        Short, lowercase, no spaces — you'll use it to address the agent.
      </p>

      <div className="mb-6 flex w-full flex-col gap-2 text-left">
        <label
          htmlFor="agent-name"
          className="text-[0.75rem] font-medium uppercase tracking-[0.08em] text-ink-muted"
        >
          Agent name
        </label>
        <input
          id="agent-name"
          type="text"
          autoFocus
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
          value={value}
          onChange={(e) => onChange(e.target.value.toLowerCase())}
          onKeyDown={(e) => {
            if (e.key === "Enter" && valid) {
              e.preventDefault();
              onContinue();
            }
          }}
          placeholder="my-agent"
          className={`rounded-xl border bg-surface-card px-4 py-3 text-[1rem] text-ink outline-none transition-colors ${
            showError ? "border-red-500/60" : "border-border-subtle focus:border-signal"
          }`}
        />
        <p className={`text-[0.75rem] ${showError ? "text-red-500" : "text-ink-muted"}`}>
          {error ?? NAME_HINT}
        </p>
      </div>

      <Button
        className="bg-signal text-white"
        isDisabled={!valid}
        onPress={onContinue}
      >
        Continue
      </Button>
    </motion.div>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 3 — Isolation                                                  */
/* -------------------------------------------------------------------- */

function IsolationStep({
  type,
  name,
  selected,
  onSelect,
  onContinue,
}: {
  type: AgentType;
  name: string;
  selected: IsolationLevel;
  onSelect: (v: IsolationLevel) => void;
  onContinue: () => void;
}) {
  return (
    <StepShell
      eyebrow={`${type} · ${name}`}
      title="How locked-down?"
      subtitle="Pick how much access this agent has to the host. You can keep it loose for trusted local work, or tighten it for untrusted prompts."
      maxWidth="max-w-2xl"
    >
      <div className="mb-8 flex w-full flex-col gap-3">
        {ISOLATION_OPTIONS.map((opt, i) => {
          const isSelected = selected === opt.value;
          return (
            <motion.button
              key={opt.value}
              type="button"
              onClick={() => onSelect(opt.value)}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: i * 0.04, duration: 0.25 }}
              whileHover={{ y: -1 }}
              className={`flex w-full items-start gap-4 rounded-2xl p-5 text-left transition-colors ${
                isSelected
                  ? "bg-signal-soft ring-1 ring-inset ring-signal/40"
                  : "bg-surface-card/60 hover:bg-surface-card"
              }`}
            >
              <div className={`flex size-5 shrink-0 items-center justify-center rounded-full border-2 transition-colors ${
                isSelected ? "border-signal bg-signal" : "border-border-hard"
              }`}>
                {isSelected && <Check className="size-3 text-white" />}
              </div>
              <div className="flex flex-1 flex-col gap-1">
                <span className={`text-[0.9375rem] font-semibold ${isSelected ? "text-signal" : "text-ink"}`}>
                  {opt.label}
                </span>
                <span className="text-[0.8125rem] text-ink-secondary">{opt.desc}</span>
              </div>
            </motion.button>
          );
        })}
      </div>

      <Button className="bg-signal text-white" onPress={onContinue}>
        Continue
      </Button>
    </StepShell>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 4 — Provider (hermes / openclaw)                               */
/* -------------------------------------------------------------------- */

function ProviderStep({
  type,
  selected,
  onSelect,
  onContinue,
}: {
  type: AgentType;
  selected: string;
  onSelect: (p: string) => void;
  onContinue: () => void;
}) {
  return (
    <StepShell
      eyebrow={`${type} · provider`}
      title="Bring your own provider"
      subtitle="This agent type runs on any major model API. Pick the one you have a key for."
      maxWidth="max-w-2xl"
    >
      <div className="mb-8 grid w-full grid-cols-2 gap-2 sm:grid-cols-3">
        {PROVIDERS.map((p) => {
          const isSelected = selected === p;
          return (
            <button
              key={p}
              type="button"
              onClick={() => onSelect(p)}
              className={`flex items-center justify-center rounded-xl px-3 py-3 text-[0.875rem] font-medium transition-colors ${
                isSelected
                  ? "bg-signal-soft text-signal ring-1 ring-inset ring-signal/40"
                  : "bg-surface-card/60 text-ink-secondary hover:bg-surface-card hover:text-ink"
              }`}
            >
              {p}
            </button>
          );
        })}
      </div>

      <Button className="bg-signal text-white" onPress={onContinue}>
        Continue
      </Button>
    </StepShell>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 5 — Auth (OAuth or API key)                                    */
/* -------------------------------------------------------------------- */

function AuthStep({
  type,
  provider,
  isOauth,
  apiKey,
  onApiKeyChange,
  oauthUrl,
  oauthPolling,
  busy,
  error,
  onStartOAuth,
  onSubmitKey,
}: {
  type: AgentType;
  provider: string;
  isOauth: boolean;
  apiKey: string;
  onApiKeyChange: (v: string) => void;
  oauthUrl: string | null;
  oauthPolling: boolean;
  busy: boolean;
  error: string | null;
  onStartOAuth: () => void;
  onSubmitKey: () => void;
}) {
  const Icon = TYPE_ICON[type] ?? TYPE_ICON.claude;
  const isProvider = PROVIDER_TYPES.has(type);
  const label = isProvider ? (PROVIDER_KEY_LABELS[provider] ?? "API key") : AUTH_HELP[type].label;
  const placeholder = isProvider ? (PROVIDER_KEY_PLACEHOLDERS[provider] ?? "sk-…") : AUTH_HELP[type].placeholder;
  const docsUrl = isProvider ? (PROVIDER_DOCS[provider] ?? "#") : AUTH_HELP[type].docsUrl;

  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.25 }}
      className="flex w-full max-w-md flex-col items-center text-center"
    >
      <motion.div
        initial={{ scale: 0.9, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ duration: 0.3, ease: "easeOut" }}
        className="relative mb-6"
      >
        <div className="pointer-events-none absolute inset-0 -z-10 scale-150 rounded-full bg-signal/10 blur-3xl" />
        <div className="flex size-16 items-center justify-center rounded-2xl bg-white shadow-[0_20px_60px_-20px_rgba(0,0,0,0.25)] ring-1 ring-black/5">
          <Icon className="size-8 text-zinc-900" />
        </div>
      </motion.div>

      <p className="mb-2 text-[0.75rem] font-semibold uppercase tracking-[0.15em] text-signal">
        Connect {type}
      </p>
      <h1 className="mb-3 text-3xl font-semibold tracking-[-0.025em] text-ink sm:text-4xl">
        Sign in
      </h1>
      <p className="mb-8 max-w-sm text-[0.9375rem] text-ink-secondary">
        Not yet authenticated on this machine. Connect once and every {type} agent reuses the same credentials.
      </p>

      {isOauth ? (
        <div className="flex w-full flex-col gap-3">
          {!oauthUrl ? (
            <Button
              className="bg-signal text-white"
              isDisabled={busy}
              onPress={onStartOAuth}
            >
              {busy && <Spinner size="sm" />}
              Sign in with Claude
            </Button>
          ) : (
            <>
              <a
                href={oauthUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center justify-center gap-2 rounded-xl bg-signal px-4 py-3 text-[0.9375rem] font-medium text-white hover:opacity-90 transition-opacity"
              >
                <Icon className="size-4" />
                Open Claude sign-in →
              </a>
              {oauthPolling && (
                <div className="flex items-center justify-center gap-2 text-[0.8125rem] text-ink-muted">
                  <div className="size-3.5 animate-spin rounded-full border-2 border-border-subtle border-t-signal" />
                  Waiting for sign-in — this page updates automatically.
                </div>
              )}
            </>
          )}
        </div>
      ) : (
        <div className="flex w-full flex-col gap-3">
          <div className="flex flex-col gap-2 text-left">
            <div className="flex items-center justify-between">
              <label className="text-[0.75rem] font-medium uppercase tracking-[0.08em] text-ink-muted">
                {label}
              </label>
              <a
                href={docsUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="text-[0.75rem] text-signal hover:underline"
              >
                Get a key →
              </a>
            </div>
            <input
              type="password"
              autoFocus
              autoComplete="off"
              spellCheck={false}
              value={apiKey}
              onChange={(e) => onApiKeyChange(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") onSubmitKey(); }}
              placeholder={placeholder}
              className="rounded-xl border border-border-subtle bg-surface-card px-4 py-3 font-mono text-[0.875rem] text-ink outline-none focus:border-signal"
            />
            {!isProvider && (
              <p className="text-[0.75rem] text-ink-muted">
                Stored in <code className="rounded bg-surface-raised px-1">/etc/5dive/connectors/{type}.env</code>.
              </p>
            )}
          </div>

          <Button
            className="mt-3 bg-signal text-white"
            isDisabled={busy || !apiKey.trim()}
            onPress={onSubmitKey}
          >
            {busy && <Spinner size="sm" />}
            Continue
          </Button>
        </div>
      )}

      {error && <p className="mt-4 text-[0.8125rem] text-red-500">{error}</p>}
    </motion.div>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 6 — Channel                                                    */
/* -------------------------------------------------------------------- */

function ChannelStep({
  type,
  selected,
  onSelect,
  onContinue,
}: {
  type: AgentType;
  selected: ChannelId;
  onSelect: (v: ChannelId) => void;
  onContinue: () => void;
}) {
  const options: Array<{
    id: ChannelId;
    name: string;
    description: string;
    Icon: IconComponent | null;
  }> = [
    { id: "none",     name: "No channel",  description: "Talk to the agent from the CLI or this dashboard.", Icon: null },
    { id: "telegram", name: "Telegram",    description: "Message the agent from your phone via a Telegram bot.", Icon: CHANNEL_ICON.telegram },
    { id: "discord",  name: "Discord",     description: "Wire the agent into a Discord channel.", Icon: CHANNEL_ICON.discord },
  ];

  return (
    <StepShell
      eyebrow={`${type} · channel`}
      title="How do you want to reach it?"
      subtitle="Pick a chat channel — or skip and just use the dashboard."
      maxWidth="max-w-2xl"
    >
      <div className="mb-8 flex w-full flex-col gap-3">
        {options.map((opt, i) => {
          const isSelected = selected === opt.id;
          return (
            <motion.button
              key={opt.id}
              type="button"
              onClick={() => onSelect(opt.id)}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: i * 0.04, duration: 0.25 }}
              whileHover={{ y: -1 }}
              className={`flex w-full items-center gap-4 rounded-2xl p-5 text-left transition-colors ${
                isSelected
                  ? "bg-signal-soft ring-1 ring-inset ring-signal/40"
                  : "bg-surface-card/60 hover:bg-surface-card"
              }`}
            >
              <div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-white text-zinc-900 ring-1 ring-black/5">
                {opt.Icon ? <opt.Icon className="size-5" /> : <div className="size-2 rounded-full bg-zinc-300" />}
              </div>
              <div className="flex flex-1 flex-col gap-1">
                <span className={`text-[0.9375rem] font-semibold ${isSelected ? "text-signal" : "text-ink"}`}>
                  {opt.name}
                </span>
                <span className="text-[0.8125rem] text-ink-secondary">{opt.description}</span>
              </div>
              <div className={`flex size-5 shrink-0 items-center justify-center rounded-full border-2 transition-colors ${
                isSelected ? "border-signal bg-signal" : "border-border-hard"
              }`}>
                {isSelected && <Check className="size-3 text-white" />}
              </div>
            </motion.button>
          );
        })}
      </div>

      <Button className="bg-signal text-white" onPress={onContinue}>
        {selected === "telegram" ? "Next" : "Create agent"}
      </Button>
    </StepShell>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 7 — Telegram token                                             */
/* -------------------------------------------------------------------- */

function TokenStep({
  value,
  onChange,
  error,
  onContinue,
}: {
  value: string;
  onChange: (v: string) => void;
  error: string | null;
  onContinue: () => void;
}) {
  const TgIcon = CHANNEL_ICON.telegram;
  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.25 }}
      className="flex w-full max-w-md flex-col items-center text-center"
    >
      <motion.div
        initial={{ scale: 0.9, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ duration: 0.3, ease: "easeOut" }}
        className="relative mb-6"
      >
        <div className="pointer-events-none absolute inset-0 -z-10 scale-150 rounded-full bg-signal/10 blur-3xl" />
        <div className="flex size-16 items-center justify-center rounded-2xl bg-white shadow-[0_20px_60px_-20px_rgba(0,0,0,0.25)] ring-1 ring-black/5">
          {TgIcon ? <TgIcon className="size-8" /> : null}
        </div>
      </motion.div>

      <p className="mb-2 text-[0.75rem] font-semibold uppercase tracking-[0.15em] text-signal">
        Telegram
      </p>
      <h1 className="mb-3 text-3xl font-semibold tracking-[-0.025em] text-ink sm:text-4xl">
        Paste your bot token
      </h1>
      <p className="mb-8 max-w-sm text-[0.9375rem] text-ink-secondary">
        Create a bot with{" "}
        <a
          href="https://t.me/BotFather"
          target="_blank"
          rel="noopener noreferrer"
          className="text-signal underline-offset-2 hover:underline"
        >
          @BotFather
        </a>
        , then paste the token it gives you.
      </p>

      <div className="mb-6 flex w-full flex-col gap-2 text-left">
        <label
          htmlFor="tg-token"
          className="text-[0.75rem] font-medium uppercase tracking-[0.08em] text-ink-muted"
        >
          Bot token
        </label>
        <input
          id="tg-token"
          type="password"
          autoFocus
          autoComplete="off"
          spellCheck={false}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && value.trim()) onContinue(); }}
          placeholder="1234567890:ABC…"
          className="rounded-xl border border-border-subtle bg-surface-card px-4 py-3 font-mono text-[0.8125rem] text-ink outline-none focus:border-signal"
        />
        {error && <p className="text-[0.75rem] text-red-500">{error}</p>}
      </div>

      <Button
        className="bg-signal text-white"
        isDisabled={!value.trim()}
        onPress={onContinue}
      >
        Create agent
      </Button>
    </motion.div>
  );
}

/* -------------------------------------------------------------------- */
/*  Step 8 — Creating                                                   */
/* -------------------------------------------------------------------- */

function CreatingStep({ name, error }: { name: string; error: string | null }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.25 }}
      className="flex w-full max-w-md flex-col items-center pt-24 text-center"
    >
      <Spinner size="lg" />
      <p className="mt-6 text-[1rem] text-ink">Creating {name}…</p>
      <p className="mt-1 text-[0.8125rem] text-ink-muted">This usually takes a few seconds.</p>
      {error && <p className="mt-6 text-[0.8125rem] text-red-500">{error}</p>}
    </motion.div>
  );
}
