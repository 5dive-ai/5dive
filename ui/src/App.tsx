import { useState, useEffect, useCallback } from "react";
import { Button } from "@heroui/react";
import { AgentList } from "./components/AgentList";
import { CreateAgentModal } from "./components/CreateAgentModal";
import { AgentDetail } from "./components/AgentDetail";
import { LogoMark } from "./components/Logo";
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
    <div className="min-h-screen bg-surface-page">
      {/* Header */}
      <header className="sticky top-0 z-20 border-b border-border-subtle bg-surface-card/80 backdrop-blur-lg">
        <div className="mx-auto flex h-14 max-w-5xl items-center justify-between px-6">
          <div className="flex items-center gap-2.5">
            <LogoMark className="size-7 shrink-0" />
            <span className="text-[0.9375rem] font-semibold tracking-tight text-ink">
              5dive
            </span>
            <span className="rounded-full bg-surface-raised px-2 py-0.5 text-[0.6875rem] font-medium text-ink-muted">
              local
            </span>
          </div>
          <Button
            size="sm"
            className="bg-signal text-white"
            onPress={() => setCreateOpen(true)}
          >
            + New agent
          </Button>
        </div>
      </header>

      {/* Main */}
      <main className="mx-auto max-w-5xl px-6 py-8">
        {loading ? (
          <div className="flex items-center justify-center py-24">
            <div className="size-5 animate-spin rounded-full border-2 border-border-subtle border-t-signal" />
          </div>
        ) : selected ? (
          <AgentDetail
            agent={selected}
            onBack={() => setSelected(null)}
            onRefresh={refresh}
          />
        ) : (
          <>
            <div className="mb-6 flex flex-col gap-1">
              <h1 className="text-[1.25rem] font-semibold tracking-tight text-ink">
                Agents
              </h1>
              <p className="text-[0.875rem] text-ink-secondary">
                Manage your AI agents running on this machine.
              </p>
            </div>
            <hr className="mb-6 border-border-subtle" />
            <AgentList
              agents={agents}
              onSelect={setSelected}
              onRefresh={refresh}
            />
          </>
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
