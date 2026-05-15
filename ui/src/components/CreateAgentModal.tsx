import { useState } from "react";

interface Props {
  onClose: () => void;
  onCreated: () => void;
}

const TYPES = ["claude", "codex", "gemini", "hermes", "openclaw", "opencode"];
const ISOLATION_OPTIONS = [
  { value: "admin", label: "Admin", desc: "Full server access" },
  { value: "standard", label: "Standard", desc: "Limited access" },
  { value: "sandboxed", label: "Sandboxed", desc: "Isolated space" },
];

export function CreateAgentModal({ onClose, onCreated }: Props) {
  const [name, setName] = useState("");
  const [type, setType] = useState("claude");
  const [isolation, setIsolation] = useState("admin");
  const [channels, setChannels] = useState("none");
  const [telegramToken, setTelegramToken] = useState("");
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const create = async () => {
    if (!name.trim()) { setError("Name is required"); return; }
    setCreating(true);
    setError(null);
    try {
      const res = await fetch("/api/agents", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim(), type, isolation, channels, telegramToken }),
      });
      const j = await res.json();
      if (j.ok) {
        onCreated();
      } else {
        setError(j.error ?? "Failed to create agent");
      }
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/20 p-4 backdrop-blur-sm">
      <div className="w-full max-w-md rounded-2xl bg-white p-6 shadow-2xl">
        <h2 className="mb-5 text-[1rem] font-semibold text-ink">New agent</h2>

        <div className="flex flex-col gap-4">
          {/* Name */}
          <label className="flex flex-col gap-1.5">
            <span className="text-[0.8125rem] font-medium text-ink">Name</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="my-agent"
              className="rounded-lg border border-zinc-200 px-3.5 py-2.5 text-[0.875rem] text-ink outline-none focus:border-signal"
            />
          </label>

          {/* Type */}
          <label className="flex flex-col gap-1.5">
            <span className="text-[0.8125rem] font-medium text-ink">Type</span>
            <div className="grid grid-cols-3 gap-2">
              {TYPES.map((t) => (
                <button
                  key={t}
                  onClick={() => setType(t)}
                  className={`rounded-lg border px-3 py-2 text-[0.8125rem] font-medium transition-colors ${
                    type === t
                      ? "border-signal bg-signal/5 text-signal"
                      : "border-zinc-200 text-ink-secondary hover:bg-zinc-50"
                  }`}
                >
                  {t}
                </button>
              ))}
            </div>
          </label>

          {/* Isolation */}
          <label className="flex flex-col gap-1.5">
            <span className="text-[0.8125rem] font-medium text-ink">Isolation</span>
            <div className="grid grid-cols-3 gap-2">
              {ISOLATION_OPTIONS.map((opt) => (
                <button
                  key={opt.value}
                  onClick={() => setIsolation(opt.value)}
                  className={`flex flex-col items-start rounded-lg border px-3 py-2.5 text-left transition-colors ${
                    isolation === opt.value
                      ? "border-signal bg-signal/5"
                      : "border-zinc-200 hover:bg-zinc-50"
                  }`}
                >
                  <span className={`text-[0.8125rem] font-medium ${isolation === opt.value ? "text-signal" : "text-ink"}`}>
                    {opt.label}
                  </span>
                  <span className="text-[0.6875rem] text-ink-muted">{opt.desc}</span>
                </button>
              ))}
            </div>
          </label>

          {/* Channels */}
          <label className="flex flex-col gap-1.5">
            <span className="text-[0.8125rem] font-medium text-ink">Channel</span>
            <select
              value={channels}
              onChange={(e) => setChannels(e.target.value)}
              className="rounded-lg border border-zinc-200 px-3.5 py-2.5 text-[0.875rem] text-ink outline-none focus:border-signal"
            >
              <option value="none">None (terminal only)</option>
              <option value="telegram">Telegram</option>
              <option value="discord">Discord</option>
            </select>
          </label>

          {channels === "telegram" && (
            <label className="flex flex-col gap-1.5">
              <span className="text-[0.8125rem] font-medium text-ink">Telegram bot token</span>
              <input
                value={telegramToken}
                onChange={(e) => setTelegramToken(e.target.value)}
                placeholder="1234567890:ABC..."
                className="rounded-lg border border-zinc-200 px-3.5 py-2.5 font-mono text-[0.8125rem] text-ink outline-none focus:border-signal"
              />
            </label>
          )}

          {error && <p className="text-[0.8125rem] text-red-500">{error}</p>}
        </div>

        <div className="mt-6 flex justify-end gap-2.5">
          <button
            onClick={onClose}
            className="rounded-lg border border-zinc-200 px-4 py-2 text-[0.875rem] font-medium text-ink-secondary hover:bg-zinc-50"
          >
            Cancel
          </button>
          <button
            onClick={() => void create()}
            disabled={creating}
            className="rounded-lg bg-signal px-4 py-2 text-[0.875rem] font-medium text-white disabled:opacity-50"
          >
            {creating ? "Creating…" : "Create agent"}
          </button>
        </div>
      </div>
    </div>
  );
}
