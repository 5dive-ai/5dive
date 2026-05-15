import { useState, useEffect, useRef } from "react";
import { Button, Spinner, Tabs } from "@heroui/react";
import { ArrowLeft, Play, Square, RotateCw, Terminal, Send, BarChart2 } from "lucide-react";
import type { Agent } from "../types";
import { TYPE_ICON } from "./icons";
import { StatusDot } from "./StatusDot";
import { TypeBadge } from "./TypeBadge";

interface Props {
  agent: Agent;
  onBack: () => void;
  onRefresh: () => void;
}

export function AgentDetail({ agent, onBack, onRefresh }: Props) {
  const [activeTab, setActiveTab] = useState("logs");
  const [logs, setLogs] = useState<string[]>([]);
  const [logsLoading, setLogsLoading] = useState(true);
  const [stats, setStats] = useState<Record<string, string> | null>(null);
  const [message, setMessage] = useState("");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const logsEndRef = useRef<HTMLDivElement>(null);
  const Icon = TYPE_ICON[agent.type] ?? TYPE_ICON.claude;

  useEffect(() => {
    if (activeTab !== "logs") return;
    setLogs([]);
    setLogsLoading(true);
    const es = new EventSource(`/api/agents/${encodeURIComponent(agent.name)}/logs?lines=300`);
    es.onmessage = (e) => {
      if (e.data === "[EOF]") { setLogsLoading(false); es.close(); return; }
      const line = JSON.parse(e.data) as string;
      setLogs((prev) => [...prev, line]);
    };
    es.onerror = () => { setLogsLoading(false); es.close(); };
    return () => es.close();
  }, [agent.name, activeTab]);

  useEffect(() => {
    if (logsEndRef.current) {
      logsEndRef.current.scrollIntoView({ behavior: "smooth" });
    }
  }, [logs]);

  useEffect(() => {
    if (activeTab !== "stats") return;
    fetch(`/api/agents/${encodeURIComponent(agent.name)}/stats`)
      .then((r) => r.json())
      .then((j) => { if (j.ok) setStats(j.data); });
  }, [agent.name, activeTab]);

  const act = async (action: string) => {
    if (busy) return;
    setBusy(action);
    try {
      await fetch(`/api/agents/${encodeURIComponent(agent.name)}/${action}`, { method: "POST" });
      await onRefresh();
    } finally {
      setBusy(null);
    }
  };

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
      setSendResult(j.ok ? "Sent." : (j.error?.message ?? j.error ?? "Failed"));
      if (j.ok) setMessage("");
    } finally {
      setSending(false);
    }
  };

  const isActive = agent.status === "active";

  return (
    <div className="flex flex-col gap-5">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2 text-[0.8125rem]">
        <Button
          variant="ghost"
          size="sm"
          className="h-7 gap-1.5 px-2 text-ink-secondary"
          onPress={onBack}
        >
          <ArrowLeft className="size-3.5" />
          Agents
        </Button>
        <span className="text-border-hard">/</span>
        <div className="flex items-center gap-2">
          <div className="flex size-6 items-center justify-center rounded-md bg-surface-raised text-ink-secondary">
            <Icon className="size-3.5" />
          </div>
          <span className="font-medium text-ink">{agent.name}</span>
          <StatusDot status={agent.status} />
          <TypeBadge type={agent.type} />
        </div>
      </div>

      {/* Quick actions */}
      <div className="flex items-center gap-2">
        <Button
          size="sm"
          variant="bordered"
          className="gap-1.5 border-border-subtle text-[0.8125rem]"
          isDisabled={!!busy}
          onPress={() => act(isActive ? "stop" : "start")}
        >
          {(busy === "stop" || busy === "start")
            ? <Spinner size="sm" />
            : isActive ? <Square className="size-3.5" /> : <Play className="size-3.5" />}
          {isActive ? "Stop" : "Start"}
        </Button>
        <Button
          size="sm"
          variant="bordered"
          className="gap-1.5 border-border-subtle text-[0.8125rem]"
          isDisabled={!!busy}
          onPress={() => act("restart")}
        >
          {busy === "restart" ? <Spinner size="sm" /> : <RotateCw className="size-3.5" />}
          Restart
        </Button>
      </div>

      {/* Tabs */}
      <Tabs
        defaultSelectedKey="logs"
        onSelectionChange={(key) => setActiveTab(key as string)}
        variant="underline"
      >
        <Tabs.ListContainer>
          <Tabs.List aria-label="Agent details">
            <Tabs.Tab id="logs">
              <span className="flex items-center gap-1.5"><Terminal className="size-3.5" /> Logs</span>
            </Tabs.Tab>
            <Tabs.Tab id="ask">
              <span className="flex items-center gap-1.5"><Send className="size-3.5" /> Send</span>
            </Tabs.Tab>
            <Tabs.Tab id="stats">
              <span className="flex items-center gap-1.5"><BarChart2 className="size-3.5" /> Stats</span>
            </Tabs.Tab>
          </Tabs.List>
        </Tabs.ListContainer>

        <Tabs.Panel id="logs">
          <div className="terminal-block mt-3 h-96">
            <div className="terminal-header">
              <div className="terminal-dot" />
              <div className="terminal-dot" />
              <div className="terminal-dot" />
              <span className="ml-2 text-[0.75rem] text-zinc-500">{agent.name}</span>
            </div>
            <div className="terminal-body h-[calc(100%-2.625rem)] overflow-y-auto">
              {logsLoading && logs.length === 0 ? (
                <span className="text-zinc-600">Loading…</span>
              ) : logs.length === 0 ? (
                <span className="text-zinc-600">No output yet.</span>
              ) : (
                logs.map((line, i) => (
                  <div key={i} className="whitespace-pre-wrap leading-5">{line}</div>
                ))
              )}
              <div ref={logsEndRef} />
            </div>
          </div>
        </Tabs.Panel>

        <Tabs.Panel id="ask">
          <div className="mt-3 flex flex-col gap-3">
            <p className="text-[0.8125rem] text-ink-secondary">
              Inject a message into the agent's terminal session.
            </p>
            <textarea
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="Type a message…"
              rows={4}
              className="w-full resize-none rounded-xl border border-border-subtle bg-surface-card px-3.5 py-2.5 text-[0.875rem] text-ink outline-none focus:border-signal"
              onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) void send(); }}
            />
            <div className="flex items-center gap-2">
              <Button
                size="sm"
                className="gap-1.5 bg-signal text-white"
                isDisabled={sending || !message.trim()}
                onPress={() => void send()}
              >
                {sending ? <Spinner size="sm" /> : <Send className="size-3.5" />}
                Send
              </Button>
              <span className="text-[0.75rem] text-ink-muted">⌘↵ to send</span>
            </div>
            {sendResult && (
              <p className={`text-[0.8125rem] ${sendResult === "Sent." ? "text-green-status" : "text-red-500"}`}>
                {sendResult}
              </p>
            )}
          </div>
        </Tabs.Panel>

        <Tabs.Panel id="stats">
          <div className="mt-3 rounded-xl border border-border-subtle bg-surface-card p-5">
            {!stats ? (
              <div className="flex justify-center py-6"><Spinner size="sm" /></div>
            ) : (
              <dl className="grid grid-cols-2 gap-x-8 gap-y-4 text-[0.8125rem] sm:grid-cols-3">
                {Object.entries(stats).map(([k, v]) => (
                  <div key={k} className="flex flex-col gap-0.5">
                    <dt className="text-[0.75rem] text-ink-muted">{k}</dt>
                    <dd className="font-medium text-ink">{String(v) || "—"}</dd>
                  </div>
                ))}
              </dl>
            )}
          </div>
        </Tabs.Panel>
      </Tabs>
    </div>
  );
}
