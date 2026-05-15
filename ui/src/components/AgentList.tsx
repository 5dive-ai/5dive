import { Button } from "@heroui/react";
import { Bot, RefreshCw } from "lucide-react";
import type { Agent } from "../types";
import { AgentCard } from "./AgentCard";

interface Props {
  agents: Agent[];
  onSelect: (agent: Agent) => void;
  onRefresh: () => void;
}

export function AgentList({ agents, onSelect, onRefresh }: Props) {
  if (agents.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-24 text-center">
        <div className="flex size-16 items-center justify-center rounded-2xl bg-surface-raised text-ink-muted">
          <Bot className="size-8" />
        </div>
        <p className="text-[0.9375rem] font-semibold text-ink">No agents yet</p>
        <p className="max-w-xs text-[0.8125rem] text-ink-secondary">
          Create your first agent with the button above, or run{" "}
          <code className="rounded bg-surface-raised px-1 font-mono text-[0.75rem]">
            5dive agent create my-agent --type=claude
          </code>{" "}
          in the terminal.
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
