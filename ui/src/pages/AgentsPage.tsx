import { AgentList } from "../components/AgentList";
import { AgentDetail } from "../components/AgentDetail";
import { ErrorBoundary } from "../components/ErrorBoundary";
import type { Agent } from "../types";

interface Props {
  agents: Agent[] | null;
  selected: Agent | null;
  onSelect: (agent: Agent) => void;
  onBack: () => void;
  onRefresh: () => void;
  onNewAgent: () => void;
}

export function AgentsPage({ agents, selected, onSelect, onBack, onRefresh, onNewAgent }: Props) {
  return (
    <ErrorBoundary>
      {selected ? (
        <AgentDetail agent={selected} onBack={onBack} onRefresh={onRefresh} />
      ) : (
        <div className="flex flex-col gap-1 pb-10">
          <div className="mb-6">
            <h1 className="text-[1.25rem] font-semibold tracking-tight text-ink">Agents</h1>
            <p className="text-[0.875rem] text-ink-secondary">
              Manage your AI agents running on this machine.
            </p>
          </div>
          <AgentList agents={agents} onSelect={onSelect} onRefresh={onRefresh} onNewAgent={onNewAgent} />
        </div>
      )}
    </ErrorBoundary>
  );
}
