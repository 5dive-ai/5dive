import { useState } from "react";
import { Button, Modal, Spinner, useOverlayState } from "@heroui/react";
import { useToast } from "../context/ToastContext";
import { CHANNEL_ICON } from "./icons";

interface Props {
  sourceName: string;
  onClose: () => void;
  onCloned: () => void;
}

export function CloneAgentModal({ sourceName, onClose, onCloned }: Props) {
  const [newName, setNewName] = useState(`${sourceName}-copy`);
  const [channels, setChannels] = useState("same");
  const [telegramToken, setTelegramToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const toast = useToast();

  const modalState = useOverlayState({ isOpen: true, onOpenChange: (open) => { if (!open) onClose(); } });

  const submit = async () => {
    setError(null);
    if (!newName.trim()) { setError("Name is required"); return; }
    if (!/^[a-z][a-z0-9-]{0,15}$/.test(newName.trim())) {
      setError("Name must be lowercase letters/digits/hyphens, start with a letter, max 16 chars");
      return;
    }
    setBusy(true);
    try {
      const body: Record<string, string> = { newName: newName.trim() };
      if (channels !== "same") body.channels = channels;
      if (channels === "telegram" && telegramToken) body.telegramToken = telegramToken;
      const res = await fetch(`/api/agents/${encodeURIComponent(sourceName)}/clone`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const j = await res.json();
      if (j.ok) {
        toast("success", `Cloned ${sourceName} → ${newName}`);
        onCloned();
      } else {
        const e = j.error;
        setError(typeof e === "string" ? e : (e?.message ?? "Failed to clone"));
      }
    } catch {
      setError("Network error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal state={modalState}>
      <Modal.Backdrop>
        <Modal.Container size="sm" placement="center" className="max-sm:p-0 sm:max-w-sm">
          <Modal.Dialog className="p-0 max-sm:h-full max-sm:max-w-full max-sm:rounded-none max-sm:shadow-none">
            <div className="flex items-center gap-3 border-b border-border-subtle px-6 py-4">
              <div>
                <h2 className="text-[1rem] font-semibold tracking-tight text-ink">Clone agent</h2>
                <p className="text-[0.75rem] text-ink-muted">Source: {sourceName}</p>
              </div>
            </div>

            <div className="flex flex-col gap-4 px-6 py-5">
              <div className="flex flex-col gap-1.5">
                <label className="text-[0.8125rem] font-medium text-ink">New name</label>
                <input
                  value={newName}
                  onChange={(e) => setNewName(e.target.value)}
                  autoFocus
                  className="rounded-xl border border-border-subtle bg-surface-card px-3.5 py-2.5 text-[0.875rem] text-ink outline-none focus:border-signal"
                  onKeyDown={(e) => { if (e.key === "Enter") void submit(); }}
                />
              </div>

              <div className="flex flex-col gap-1.5">
                <span className="text-[0.8125rem] font-medium text-ink">Channel override</span>
                <div className="grid grid-cols-2 gap-2">
                  {([
                    { value: "same",     label: "Keep same" },
                    { value: "none",     label: "None" },
                    { value: "telegram", label: "Telegram", Icon: CHANNEL_ICON.telegram },
                    { value: "discord",  label: "Discord",  Icon: CHANNEL_ICON.discord },
                  ] as const).map(({ value, label, Icon }) => (
                    <button
                      key={value}
                      onClick={() => setChannels(value)}
                      className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-[0.8125rem] font-medium transition-colors ${
                        channels === value
                          ? "border-signal bg-signal-soft text-signal"
                          : "border-border-subtle text-ink-secondary hover:bg-surface-raised"
                      }`}
                    >
                      {Icon ? <Icon className="size-3.5" /> : null}
                      {label}
                    </button>
                  ))}
                </div>
              </div>

              {channels === "telegram" && (
                <div className="flex flex-col gap-1.5">
                  <label className="text-[0.8125rem] font-medium text-ink">New Telegram bot token</label>
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
              <Button variant="ghost" className="text-ink-secondary" onPress={onClose}>
                Cancel
              </Button>
              <Button
                className="bg-signal text-white"
                isDisabled={busy || !newName.trim()}
                onPress={() => void submit()}
              >
                {busy ? <Spinner size="sm" /> : null}
                Clone agent
              </Button>
            </div>
          </Modal.Dialog>
        </Modal.Container>
      </Modal.Backdrop>
    </Modal>
  );
}
