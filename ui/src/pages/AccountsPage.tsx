import { useState, useEffect, useCallback } from "react";
import { Button, Spinner, Chip } from "@heroui/react";
import { Users, RefreshCw, Plus, Trash2, ChevronRight } from "lucide-react";
import type { Account, AccountDetail } from "../types";
import { useToast } from "../context/ToastContext";
import { TYPE_ICON } from "../components/icons";

function AccountRow({
  account,
  onSelect,
  onRemove,
}: {
  account: Account;
  onSelect: () => void;
  onRemove: () => void;
}) {
  const [busy, setBusy] = useState(false);

  const handleRemove = async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!confirm(`Remove account "${account.name}"?`)) return;
    setBusy(true);
    await onRemove();
    setBusy(false);
  };

  return (
    <div
      className="group flex items-center gap-4 rounded-xl border border-border-subtle bg-surface-card px-4 py-3.5 hover:shadow-sm cursor-pointer"
      onClick={onSelect}
    >
      <div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-surface-raised text-ink-secondary">
        <Users className="size-5" />
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-[0.9375rem] font-medium text-ink">{account.name}</span>
          {account.name === "default" && (
            <Chip
              size="sm"
              classNames={{
                base: "bg-signal-soft border-0 h-auto py-0.5",
                content: "text-signal text-[0.625rem] font-medium px-1.5 py-0",
              }}
            >
              default
            </Chip>
          )}
        </div>
        <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[0.75rem] text-ink-secondary">
          {account.types.length > 0 ? (
            account.types.map((t) => {
              const Icon = TYPE_ICON[t];
              return Icon ? (
                <span key={t} className="flex items-center gap-1">
                  <Icon className="size-3" />{t}
                </span>
              ) : <span key={t}>{t}</span>;
            })
          ) : (
            <span className="text-ink-muted">No types authenticated</span>
          )}
          <span className="text-border-hard">·</span>
          <span>{account.agentCount} agent{account.agentCount !== 1 ? "s" : ""}</span>
        </div>
      </div>
      <div className="flex items-center gap-1 sm:opacity-0 sm:group-hover:opacity-100">
        {account.name !== "default" && (
          <Button
            size="sm"
            variant="ghost"
            className="size-7 min-w-0 p-0 text-red-400 hover:text-red-600"
            onPress={handleRemove}
            isDisabled={busy}
          >
            {busy ? <Spinner size="sm" /> : <Trash2 className="size-3.5" />}
          </Button>
        )}
        <ChevronRight className="size-4 text-ink-muted" />
      </div>
    </div>
  );
}

function AccountDetailPanel({
  name,
  onBack,
}: {
  name: string;
  onBack: () => void;
}) {
  const [detail, setDetail] = useState<AccountDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const toast = useToast();

  useEffect(() => {
    fetch(`/api/accounts/${encodeURIComponent(name)}`)
      .then((r) => r.json())
      .then((j) => { if (j.ok) setDetail(j.data); else toast("error", j.error?.message ?? "Failed to load"); })
      .finally(() => setLoading(false));
  }, [name, toast]);

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-center gap-2 text-[0.8125rem]">
        <Button
          variant="ghost"
          size="sm"
          className="h-7 gap-1.5 px-2 text-ink-secondary"
          onPress={onBack}
        >
          ← Accounts
        </Button>
        <span className="text-border-hard">/</span>
        <span className="font-medium text-ink">{name}</span>
      </div>

      {loading ? (
        <div className="flex justify-center py-16"><Spinner /></div>
      ) : detail ? (
        <div className="flex flex-col gap-4">
          <div className="rounded-xl border border-border-subtle bg-surface-card p-5">
            <h3 className="mb-3 text-[0.875rem] font-semibold text-ink">Auth types</h3>
            {Object.keys(detail.types).length === 0 ? (
              <p className="text-[0.8125rem] text-ink-muted">No types authenticated yet.</p>
            ) : (
              <dl className="grid grid-cols-2 gap-x-8 gap-y-3 text-[0.8125rem]">
                {Object.entries(detail.types).map(([type, info]) => {
                  const Icon = TYPE_ICON[type];
                  return (
                    <div key={type} className="flex flex-col gap-0.5">
                      <dt className="flex items-center gap-1.5 text-[0.75rem] text-ink-muted">
                        {Icon && <Icon className="size-3" />}{type}
                      </dt>
                      <dd className="font-medium text-ink text-[0.8125rem]">
                        {info.keys.join(", ") || "Authenticated"}
                      </dd>
                    </div>
                  );
                })}
              </dl>
            )}
          </div>
          {detail.agents.length > 0 && (
            <div className="rounded-xl border border-border-subtle bg-surface-card p-5">
              <h3 className="mb-3 text-[0.875rem] font-semibold text-ink">Bound agents</h3>
              <div className="flex flex-wrap gap-2">
                {detail.agents.map((a) => (
                  <span key={a} className="rounded-lg bg-surface-raised px-2.5 py-1 text-[0.8125rem] text-ink">
                    {a}
                  </span>
                ))}
              </div>
            </div>
          )}
        </div>
      ) : null}
    </div>
  );
}

export function AccountsPage() {
  const [accounts, setAccounts] = useState<Account[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<string | null>(null);
  const [addName, setAddName] = useState("");
  const [adding, setAdding] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  const toast = useToast();

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await fetch("/api/accounts");
      const j = await res.json();
      if (j.ok) setAccounts(j.data ?? []);
      else toast("error", j.error?.message ?? "Failed to load accounts");
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => { void load(); }, [load]);

  const addAccount = async () => {
    if (!addName.trim()) return;
    setAdding(true);
    try {
      const res = await fetch("/api/accounts", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: addName.trim() }),
      });
      const j = await res.json();
      if (j.ok) {
        toast("success", `Account "${addName}" created`);
        setAddName("");
        setShowAdd(false);
        await load();
      } else {
        toast("error", j.error?.message ?? j.error ?? "Failed to create account");
      }
    } finally {
      setAdding(false);
    }
  };

  const removeAccount = async (name: string) => {
    const res = await fetch(`/api/accounts/${encodeURIComponent(name)}`, { method: "DELETE" });
    const j = await res.json();
    if (j.ok) { toast("success", `Account "${name}" removed`); await load(); }
    else toast("error", j.error?.message ?? j.error ?? "Failed to remove");
  };

  if (selected) {
    return <AccountDetailPanel name={selected} onBack={() => setSelected(null)} />;
  }

  return (
    <div className="flex flex-col gap-6 pb-10">
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-[1.25rem] font-semibold tracking-tight text-ink">Accounts</h1>
          <p className="text-[0.875rem] text-ink-secondary">
            Named auth profiles — group sign-ins so multiple agents share one login.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="bordered"
            className="gap-1.5 border-border-subtle text-[0.8125rem] text-ink-secondary"
            onPress={() => void load()}
            isDisabled={loading}
          >
            {loading ? <Spinner size="sm" /> : <RefreshCw className="size-3.5" />}
            Refresh
          </Button>
          <Button
            size="sm"
            className="gap-1.5 bg-signal text-white text-[0.8125rem]"
            onPress={() => setShowAdd(true)}
          >
            <Plus className="size-3.5" /> Add account
          </Button>
        </div>
      </div>

      {/* Add account inline form */}
      {showAdd && (
        <div className="flex items-center gap-2 rounded-xl border border-signal bg-signal-soft px-4 py-3">
          <input
            autoFocus
            value={addName}
            onChange={(e) => setAddName(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void addAccount(); if (e.key === "Escape") setShowAdd(false); }}
            placeholder="Account name (e.g. work, personal)"
            className="flex-1 bg-transparent text-[0.875rem] text-ink outline-none placeholder:text-ink-muted"
          />
          <Button
            size="sm"
            className="bg-signal text-white text-[0.8125rem]"
            onPress={() => void addAccount()}
            isDisabled={adding || !addName.trim()}
          >
            {adding ? <Spinner size="sm" /> : "Create"}
          </Button>
          <Button
            size="sm"
            variant="ghost"
            className="text-ink-secondary"
            onPress={() => { setShowAdd(false); setAddName(""); }}
          >
            Cancel
          </Button>
        </div>
      )}

      {/* Account list */}
      {loading && !accounts ? (
        <div className="flex justify-center py-16"><Spinner /></div>
      ) : accounts && accounts.length === 0 ? (
        <div className="flex flex-col items-center gap-3 py-24 text-center">
          <div className="flex size-16 items-center justify-center rounded-2xl bg-surface-raised text-ink-muted">
            <Users className="size-8" />
          </div>
          <p className="text-[0.9375rem] font-semibold text-ink">No accounts</p>
          <p className="max-w-xs text-[0.8125rem] text-ink-secondary">
            The default account is always present. Add named accounts to manage multiple sign-ins.
          </p>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          {(accounts ?? []).map((acc) => (
            <AccountRow
              key={acc.name}
              account={acc}
              onSelect={() => setSelected(acc.name)}
              onRemove={() => removeAccount(acc.name)}
            />
          ))}
        </div>
      )}
    </div>
  );
}
