import { useState, useEffect, useCallback } from "react";
import { AgentList } from "./components/AgentList";
import { CreateAgentModal } from "./components/CreateAgentModal";
import { AgentDetail } from "./components/AgentDetail";
import type { Agent } from "./types";

export default function App() {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [loading, setLoading] = useState(true);
  const [createOpen, setCreateOpen] = useState(false);
  const [selected, setSelected] = useState<Agent | null>(null);

  const refresh = useCallback(async () => {
    try {
      const res = await fetch("/api/agents");
      const json = await res.json();
      if (json.ok) setAgents(json.data ?? []);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const id = setInterval(refresh, 5000);
    return () => clearInterval(id);
  }, [refresh]);

  return (
    <div className="min-h-screen bg-surface">
      {/* Header */}
      <header className="border-b border-zinc-100 bg-white">
        <div className="mx-auto flex h-14 max-w-5xl items-center justify-between px-6">
          <div className="flex items-center gap-2.5">
            <span className="text-[1.0625rem] font-semibold tracking-[-0.02em] text-ink">
              5dive
            </span>
            <span className="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.6875rem] font-medium text-zinc-500">
              local
            </span>
          </div>
          <button
            onClick={() => setCreateOpen(true)}
            className="inline-flex h-8 items-center gap-1.5 rounded-lg bg-signal px-3.5 text-[0.8125rem] font-medium text-white transition-opacity hover:opacity-90"
          >
            <span className="text-[1.1rem] leading-none">+</span>
            New agent
          </button>
        </div>
      </header>

      {/* Main */}
      <main className="mx-auto max-w-5xl px-6 py-8">
        {loading ? (
          <div className="flex items-center justify-center py-20">
            <div className="size-5 animate-spin rounded-full border-2 border-zinc-200 border-t-signal" />
          </div>
        ) : selected ? (
          <AgentDetail
            agent={selected}
            onBack={() => setSelected(null)}
            onRefresh={refresh}
          />
        ) : (
          <AgentList
            agents={agents}
            onSelect={setSelected}
            onRefresh={refresh}
          />
        )}
      </main>

      {createOpen && (
        <CreateAgentModal
          onClose={() => setCreateOpen(false)}
          onCreated={() => {
            setCreateOpen(false);
            void refresh();
          }}
        />
      )}
    </div>
  );
}
