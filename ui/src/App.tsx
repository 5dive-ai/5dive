import { useState, useEffect, useCallback } from "react";
import { Sidebar } from "./components/Sidebar";
import { NewAgentFlow } from "./components/NewAgentFlow";
import { LoginScreen } from "./components/LoginScreen";
import { SetupScreen } from "./components/SetupScreen";
import { AgentsPage } from "./pages/AgentsPage";
import { AccountsPage } from "./pages/AccountsPage";
import { HealthPage } from "./pages/HealthPage";
import { ToastProvider } from "./context/ToastContext";
import { AuthProvider, useAuth } from "./context/AuthContext";
import type { Agent, Page } from "./types";

function Dashboard() {
  const [agents, setAgents] = useState<Agent[] | null>(null);
  const [creating, setCreating] = useState(false);
  const [selected, setSelected] = useState<Agent | null>(null);
  const [page, setPage] = useState<Page>("agents");

  const refresh = useCallback(async (): Promise<Agent[] | null> => {
    try {
      const res = await fetch("/api/agents");
      const json = await res.json();
      if (json.ok) {
        const next = (json.data ?? []) as Agent[];
        setAgents(next);
        return next;
      }
    } catch {
      setAgents([]);
    }
    return null;
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

  const handleCreated = useCallback(async (name?: string) => {
    setCreating(false);
    const next = await refresh();
    if (name && next) {
      const found = next.find((a) => a.name === name);
      if (found) {
        setSelected(found);
        setPage("agents");
      }
    }
  }, [refresh]);

  return (
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
              onRefresh={() => { void refresh(); }}
              onNewAgent={() => setCreating(true)}
            />
          )}
          {page === "accounts" && <AccountsPage />}
          {page === "health" && <HealthPage />}
        </div>
      </main>

      {creating && (
        <NewAgentFlow
          onExit={() => setCreating(false)}
          onCreated={handleCreated}
        />
      )}
    </div>
  );
}

function AuthGate() {
  const { loading, mode, configured, authenticated } = useAuth();
  if (loading) return <div className="flex h-screen items-center justify-center bg-surface-page" />;
  if (mode === "password" && !configured) return <SetupScreen />;
  if (mode === "password" && !authenticated) return <LoginScreen />;
  return <Dashboard />;
}

export default function App() {
  return (
    <AuthProvider>
      <ToastProvider>
        <AuthGate />
      </ToastProvider>
    </AuthProvider>
  );
}
