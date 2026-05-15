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
        <div className="text-4xl">🤖</div>
        <p className="text-[0.9375rem] font-medium text-ink">No agents yet</p>
        <p className="text-[0.8125rem] text-ink-secondary">
          Create your first agent with the button above.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="mb-2 flex items-center justify-between">
        <p className="text-[0.8125rem] text-ink-secondary">
          {agents.length} agent{agents.length !== 1 ? "s" : ""}
        </p>
        <button
          onClick={onRefresh}
          className="text-[0.8125rem] text-ink-secondary hover:text-ink"
        >
          Refresh
        </button>
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
