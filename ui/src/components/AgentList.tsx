import { Button } from "@heroui/react";
import { Bot, RefreshCw, Plus } from "lucide-react";
import type { Agent } from "../types";
import { AgentCard } from "./AgentCard";

function SkeletonRow() {
  return (
    <div className="flex items-center gap-4 rounded-xl border border-border-subtle bg-surface-card px-4 py-3.5">
      <div className="size-11 shrink-0 rounded-xl bg-surface-raised animate-pulse" />
      <div className="flex flex-1 flex-col gap-2">
        <div className="h-4 w-32 rounded-md bg-surface-raised animate-pulse" />
        <div className="h-3 w-20 rounded-md bg-surface-raised animate-pulse" />
      </div>
    </div>
  );
}

interface Props {
  agents: Agent[] | null;
  onSelect: (agent: Agent) => void;
  onRefresh: () => void;
  onNewAgent: () => void;
}

export function AgentList({ agents, onSelect, onRefresh, onNewAgent }: Props) {
  if (agents === null) {
    return (
      <div className="flex flex-col gap-2">
        <SkeletonRow />
        <SkeletonRow />
        <SkeletonRow />
      </div>
    );
  }

  if (agents.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center gap-4 py-20 text-center">
        <div className="flex size-16 items-center justify-center rounded-2xl bg-surface-raised text-ink-muted">
          <Bot className="size-8" />
        </div>
        <div className="space-y-1">
          <p className="text-[1rem] font-semibold text-ink">Spawn your first agent</p>
          <p className="mx-auto max-w-xs text-[0.8125rem] text-ink-secondary">
            Pick a model, sign in once, give it a name. You'll be chatting with it in under a minute.
          </p>
        </div>
        <button
          onClick={onNewAgent}
          className="flex items-center gap-1.5 rounded-xl bg-signal px-4 py-2.5 text-[0.875rem] font-medium text-white transition-opacity hover:opacity-90"
        >
          <Plus className="size-4" /> Create your first agent
        </button>
        <p className="mt-2 max-w-xs text-[0.75rem] text-ink-muted">
          Prefer the terminal? Try{" "}
          <code className="rounded bg-surface-raised px-1 font-mono text-[0.6875rem]">
            5dive agent create my-agent --type=claude
          </code>
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="mb-1 flex items-center justify-between">
        <p className="text-[0.8125rem] text-ink-muted">
          {agents.length} agent{agents.length !== 1 ? "s" : ""}
        </p>
        <Button
          size="sm"
          variant="light"
          className="h-7 gap-1.5 px-2 text-[0.8125rem] text-ink-secondary"
          onPress={onRefresh}
        >
          <RefreshCw className="size-3.5" />
          Refresh
        </Button>
      </div>
      {agents.map((agent) => (
        <AgentCard
          key={agent.name}
          agent={agent}
          onSelect={() => onSelect(agent)}
          onRefresh={onRefresh}
        />
      ))}
    </div>
  );
}
