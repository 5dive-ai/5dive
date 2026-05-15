import { useState } from "react";
import {
  Button,
  Modal,
  Spinner,
  useOverlayState,
} from "@heroui/react";

interface Props {
  onClose: () => void;
  onCreated: () => void;
}

const TYPES = ["claude", "codex", "gemini", "hermes", "openclaw", "opencode"] as const;
const ISOLATION_OPTIONS = [
  { value: "admin",     label: "Admin",     desc: "Full server access" },
  { value: "standard",  label: "Standard",  desc: "Limited access" },
  { value: "sandboxed", label: "Sandboxed", desc: "Isolated home dir" },
] as const;

export function CreateAgentModal({ onClose, onCreated }: Props) {
  const [name, setName] = useState("");
  const [type, setType] = useState("claude");
  const [isolation, setIsolation] = useState("admin");
  const [channels, setChannels] = useState("none");
  const [telegramToken, setTelegramToken] = useState("");
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const modalState = useOverlayState({ isOpen: true, onOpenChange: (open) => { if (!open) onClose(); } });

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
    <Modal state={modalState}>
      <Modal.Backdrop>
        <Modal.Container size="md" placement="center" className="sm:max-w-md">
          <Modal.Dialog className="p-0">
            <div className="border-b border-border-subtle px-6 py-4">
              <h2 className="text-[1rem] font-semibold tracking-tight text-ink">New agent</h2>
            </div>

            <div className="flex flex-col gap-5 px-6 py-5">
              {/* Name */}
              <div className="flex flex-col gap-1.5">
                <label className="text-[0.8125rem] font-medium text-ink">Name</label>
                <input
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder="my-agent"
                  className="rounded-xl border border-border-subtle bg-surface-card px-3.5 py-2.5 text-[0.875rem] text-ink outline-none focus:border-signal"
                />
              </div>

              {/* Type */}
              <div className="flex flex-col gap-1.5">
                <span className="text-[0.8125rem] font-medium text-ink">Type</span>
                <div className="grid grid-cols-3 gap-2">
                  {TYPES.map((t) => (
                    <button
                      key={t}
                      onClick={() => setType(t)}
                      className={`rounded-xl border px-3 py-2 text-[0.8125rem] font-medium transition-colors ${
                        type === t
                          ? "border-signal bg-signal-soft text-signal"
                          : "border-border-subtle text-ink-secondary hover:bg-surface-raised"
                      }`}
                    >
                      {t}
                    </button>
                  ))}
                </div>
              </div>

              {/* Isolation */}
              <div className="flex flex-col gap-1.5">
                <span className="text-[0.8125rem] font-medium text-ink">Isolation</span>
                <div className="grid grid-cols-3 gap-2">
                  {ISOLATION_OPTIONS.map((opt) => (
                    <button
                      key={opt.value}
                      onClick={() => setIsolation(opt.value)}
                      className={`flex flex-col items-start rounded-xl border px-3 py-2.5 text-left transition-colors ${
                        isolation === opt.value
                          ? "border-signal bg-signal-soft"
                          : "border-border-subtle hover:bg-surface-raised"
                      }`}
                    >
                      <span className={`text-[0.8125rem] font-medium ${isolation === opt.value ? "text-signal" : "text-ink"}`}>
                        {opt.label}
                      </span>
                      <span className="text-[0.6875rem] text-ink-muted">{opt.desc}</span>
                    </button>
                  ))}
                </div>
              </div>

              {/* Channel */}
              <div className="flex flex-col gap-1.5">
                <label className="text-[0.8125rem] font-medium text-ink">Channel</label>
                <select
                  value={channels}
                  onChange={(e) => setChannels(e.target.value)}
                  className="rounded-xl border border-border-subtle bg-surface-card px-3.5 py-2.5 text-[0.875rem] text-ink outline-none focus:border-signal"
                >
                  <option value="none">None (terminal only)</option>
                  <option value="telegram">Telegram</option>
                  <option value="discord">Discord</option>
                </select>
              </div>

              {channels === "telegram" && (
                <div className="flex flex-col gap-1.5">
                  <label className="text-[0.8125rem] font-medium text-ink">Telegram bot token</label>
                  <input
                    value={telegramToken}
                    onChange={(e) => setTelegramToken(e.target.value)}
                    placeholder="1234567890:ABC…"
                    className="rounded-xl border border-border-subtle bg-surface-card px-3.5 py-2.5 font-mono text-[0.8125rem] text-ink outline-none focus:border-signal"
                  />
                </div>
              )}

              {error && <p className="text-[0.8125rem] text-red-500">{error}</p>}
            </div>

            <div className="flex justify-end gap-2 border-t border-border-subtle px-6 py-4">
              <Button
                variant="ghost"
                className="text-ink-secondary"
                onPress={onClose}
              >
                Cancel
              </Button>
              <Button
                className="bg-signal text-white"
                isDisabled={creating}
                onPress={() => void create()}
              >
                {creating ? <Spinner size="sm" /> : null}
                Create agent
              </Button>
            </div>
          </Modal.Dialog>
        </Modal.Container>
      </Modal.Backdrop>
    </Modal>
  );
}
