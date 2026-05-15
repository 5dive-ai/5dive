import { useState, useEffect, useRef } from "react";
import type { Agent } from "../types";
import { StatusDot } from "./StatusDot";
import { TypeBadge } from "./TypeBadge";

interface Props {
  agent: Agent;
  onBack: () => void;
  onRefresh: () => void;
}

export function AgentDetail({ agent, onBack, onRefresh }: Props) {
  const [tab, setTab] = useState<"logs" | "send" | "stats">("logs");
  const [logs, setLogs] = useState<string[]>([]);
  const [stats, setStats] = useState<Record<string, string> | null>(null);
  const [message, setMessage] = useState("");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<string | null>(null);
  const logsEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (tab !== "logs") return;
    setLogs([]);
    const es = new EventSource(`/api/agents/${encodeURIComponent(agent.name)}/logs?lines=200`);
    es.onmessage = (e) => {
      if (e.data === "[EOF]") { es.close(); return; }
      const line = JSON.parse(e.data) as string;
      setLogs((prev) => [...prev, line]);
    };
    return () => es.close();
  }, [agent.name, tab]);

  useEffect(() => {
    if (logsEndRef.current) {
      logsEndRef.current.scrollIntoView({ behavior: "smooth" });
    }
  }, [logs]);

  useEffect(() => {
    if (tab !== "stats") return;
    fetch(`/api/agents/${encodeURIComponent(agent.name)}/stats`)
      .then((r) => r.json())
      .then((j) => { if (j.ok) setStats(j.data); });
  }, [agent.name, tab]);

  const send = async () => {
    if (!message.trim() || sending) return;
    setSending(true);
    setSendResult(null);
    try {
      const res = await fetch(`/api/agents/${encodeURIComponent(agent.name)}/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: message }),
      });
      const j = await res.json();
      setSendResult(j.ok ? "Sent!" : (j.error ?? "Failed"));
      if (j.ok) setMessage("");
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="flex flex-col gap-4">
      {/* Back + header */}
      <div className="flex items-center gap-3">
        <button
          onClick={onBack}
          className="flex items-center gap-1.5 text-[0.8125rem] text-ink-secondary hover:text-ink"
        >
          ← Agents
        </button>
        <span className="text-ink-muted">/</span>
        <div className="flex items-center gap-2">
          <span className="text-[0.9375rem] font-medium text-ink">{agent.name}</span>
          <StatusDot status={agent.status} />
          <TypeBadge type={agent.type} />
        </div>
      </div>

      {/* Quick actions */}
      <div className="flex gap-2">
        {agent.status === "active" ? (
          <QuickBtn label="Stop" onClick={() => agentAction("stop", agent.name, onRefresh)} danger />
        ) : (
          <QuickBtn label="Start" onClick={() => agentAction("start", agent.name, onRefresh)} />
        )}
        <QuickBtn label="Restart" onClick={() => agentAction("restart", agent.name, onRefresh)} />
      </div>

      {/* Tabs */}
      <div className="flex gap-0 border-b border-zinc-100">
        {(["logs", "send", "stats"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-4 pb-2.5 pt-0.5 text-[0.8125rem] font-medium transition-colors ${
              tab === t
                ? "border-b-2 border-signal text-signal"
                : "text-ink-secondary hover:text-ink"
            }`}
          >
            {t.charAt(0).toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>

      {/* Tab content */}
      {tab === "logs" && (
        <div className="h-96 overflow-y-auto rounded-xl bg-zinc-950 p-4 font-mono text-[0.75rem] text-zinc-300">
          {logs.length === 0 ? (
            <span className="text-zinc-600">Loading logs…</span>
          ) : (
            logs.map((line, i) => (
              <div key={i} className="whitespace-pre-wrap leading-5">
                {line}
              </div>
            ))
          )}
          <div ref={logsEndRef} />
        </div>
      )}

      {tab === "send" && (
        <div className="flex flex-col gap-3">
          <p className="text-[0.8125rem] text-ink-secondary">
            Send a message to this agent (injects into its terminal session).
          </p>
          <div className="flex gap-2">
            <input
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && !e.shiftKey && void send()}
              placeholder="Type a message…"
              className="min-w-0 flex-1 rounded-lg border border-zinc-200 px-3.5 py-2.5 text-[0.875rem] text-ink outline-none focus:border-signal"
            />
            <button
              onClick={() => void send()}
              disabled={sending || !message.trim()}
              className="rounded-lg bg-signal px-4 py-2.5 text-[0.875rem] font-medium text-white disabled:opacity-40"
            >
              {sending ? "…" : "Send"}
            </button>
          </div>
          {sendResult && (
            <p className={`text-[0.8125rem] ${sendResult === "Sent!" ? "text-green-600" : "text-red-500"}`}>
              {sendResult}
            </p>
          )}
        </div>
      )}

      {tab === "stats" && (
        <div className="rounded-xl border border-zinc-100 bg-white p-4">
          {!stats ? (
            <div className="text-[0.8125rem] text-ink-secondary">Loading…</div>
          ) : (
            <dl className="grid grid-cols-2 gap-x-8 gap-y-3 text-[0.8125rem]">
              {Object.entries(stats).map(([k, v]) => (
                <div key={k} className="flex flex-col gap-0.5">
                  <dt className="text-[0.75rem] text-ink-muted">{k}</dt>
                  <dd className="font-medium text-ink">{String(v) || "—"}</dd>
                </div>
              ))}
            </dl>
          )}
        </div>
      )}
    </div>
  );
}

async function agentAction(action: string, name: string, onRefresh: () => void) {
  await fetch(`/api/agents/${encodeURIComponent(name)}/${action}`, { method: "POST" });
  await onRefresh();
}

function QuickBtn({
  label,
  onClick,
  danger,
}: {
  label: string;
  onClick: () => void;
  danger?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      className={`rounded-lg border px-3.5 py-1.5 text-[0.8125rem] font-medium transition-colors ${
        danger
          ? "border-red-200 text-red-500 hover:bg-red-50"
          : "border-zinc-200 text-ink-secondary hover:bg-zinc-50 hover:text-ink"
      }`}
    >
      {label}
    </button>
  );
}
