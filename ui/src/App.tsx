import { useState, useEffect, useCallback } from "react";
import { Sidebar } from "./components/Sidebar";
import { NewAgentFlow } from "./components/NewAgentFlow";
import { AgentsPage } from "./pages/AgentsPage";
import { AccountsPage } from "./pages/AccountsPage";
import { HealthPage } from "./pages/HealthPage";
import { ToastProvider } from "./context/ToastContext";
import type { Agent, Page } from "./types";

export default function App() {
  const [agents, setAgents] = useState<Agent[] | null>(null);
  const [creating, setCreating] = useState(false);
  const [selected, setSelected] = useState<Agent | null>(null);
  const [page, setPage] = useState<Page>("agents");

  const refresh = useCallback(async () => {
    try {
      const res = await fetch("/api/agents");
      const json = await res.json();
      if (json.ok) setAgents(json.data ?? []);
    } catch {
      setAgents([]);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const id = setInterval(refresh, 5000);
    return () => clearInterval(id);
  }, [refresh]);

  const handleNavigate = (p: Page) => {
    setPage(p);
    if (p !== "agents") setSelected(null);
  };

  return (
    <ToastProvider>
      <div className="flex h-screen overflow-hidden bg-surface-page">
        <Sidebar
          page={page}
          onNavigate={handleNavigate}
          onNewAgent={() => setCreating(true)}
        />

        <main className="flex-1 overflow-y-auto pt-14 pb-16 md:pt-0 md:pb-0">
          <div className="mx-auto max-w-3xl px-4 py-6 md:px-8 md:py-8">
            {page === "agents" && (
              <AgentsPage
                agents={agents}
                selected={selected}
                onSelect={(agent) => { setSelected(agent); setPage("agents"); }}
                onBack={() => setSelected(null)}
                onRefresh={refresh}
              />
            )}
            {page === "accounts" && <AccountsPage />}
            {page === "health" && <HealthPage />}
          </div>
        </main>

        {creating && (
          <NewAgentFlow
            onExit={() => setCreating(false)}
            onCreated={() => {
              setCreating(false);
              void refresh();
            }}
          />
        )}
      </div>
    </ToastProvider>
  );
}
