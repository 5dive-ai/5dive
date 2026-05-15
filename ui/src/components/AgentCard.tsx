import { useState } from "react";
import type { Agent } from "../types";
import { StatusDot } from "./StatusDot";
import { TypeBadge } from "./TypeBadge";

interface Props {
  agent: Agent;
  onSelect: () => void;
  onRefresh: () => void;
}

const ACTION_LABELS: Record<string, string> = {
  start: "Starting…",
  stop: "Stopping…",
  restart: "Restarting…",
  rm: "Deleting…",
};

export function AgentCard({ agent, onSelect, onRefresh }: Props) {
  const [busy, setBusy] = useState<string | null>(null);

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

  const del = async () => {
    if (!confirm(`Delete agent "${agent.name}"?`)) return;
    setBusy("rm");
    try {
      await fetch(`/api/agents/${encodeURIComponent(agent.name)}`, { method: "DELETE" });
      await onRefresh();
    } finally {
      setBusy(null);
    }
  };

  const isActive = agent.status === "active";

  return (
    <div className="group flex items-center gap-4 rounded-xl border border-zinc-100 bg-white px-4 py-3.5 shadow-sm transition-shadow hover:shadow-md">
      {/* Icon */}
      <div className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-zinc-50 text-[1.25rem]">
        {typeEmoji(agent.type)}
      </div>

      {/* Name + subtitle */}
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <div className="flex items-center gap-2">
          <button
            onClick={onSelect}
            className="truncate text-[0.9375rem] font-medium text-ink hover:text-signal"
          >
            {agent.name}
          </button>
          <StatusDot status={agent.status} />
          {agent.isolation === "sandboxed" && (
            <span className="rounded-full bg-green-100 px-1.5 py-0.5 text-[0.625rem] font-medium text-green-700">
              sandboxed
            </span>
          )}
        </div>
        <div className="flex items-center gap-2 text-[0.75rem] text-ink-secondary">
          <TypeBadge type={agent.type} />
          {agent.channels && agent.channels !== "none" && (
            <>
              <span className="text-zinc-300">·</span>
              <span className="capitalize">{agent.channels}</span>
            </>
          )}
        </div>
      </div>

      {/* Actions */}
      <div className="flex shrink-0 items-center gap-1.5 opacity-0 transition-opacity group-hover:opacity-100">
        {busy ? (
          <span className="text-[0.75rem] text-ink-secondary">{ACTION_LABELS[busy]}</span>
        ) : (
          <>
            {isActive ? (
              <ActionBtn onClick={() => act("stop")} label="Stop" danger />
            ) : (
              <ActionBtn onClick={() => act("start")} label="Start" />
            )}
            <ActionBtn onClick={() => act("restart")} label="Restart" />
            <ActionBtn onClick={del} label="Delete" danger />
          </>
        )}
      </div>
    </div>
  );
}

function ActionBtn({
  onClick,
  label,
  danger,
}: {
  onClick: () => void;
  label: string;
  danger?: boolean;
}) {
  return (
    <button
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
      className={`rounded-md px-2.5 py-1 text-[0.75rem] font-medium transition-colors ${
        danger
          ? "text-red-500 hover:bg-red-50"
          : "text-ink-secondary hover:bg-zinc-100 hover:text-ink"
      }`}
    >
      {label}
    </button>
  );
}

function typeEmoji(type: string): string {
  const map: Record<string, string> = {
    claude: "🤖",
    codex: "💡",
    gemini: "✨",
    hermes: "⚡",
    openclaw: "🦅",
    opencode: "🔧",
  };
  return map[type] ?? "🤖";
}
