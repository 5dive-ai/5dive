import { useState } from "react";
import { Button, Chip, Dropdown, Spinner } from "@heroui/react";
import { MoreVertical, RotateCw, Square, Play, Trash2, Copy } from "lucide-react";
import type { Agent } from "../types";
import { TYPE_ICON, CHANNEL_ICON } from "./icons";
import { StatusDot } from "./StatusDot";
import { TypeBadge } from "./TypeBadge";
import { useToast } from "../context/ToastContext";
import { CloneAgentModal } from "./CloneAgentModal";

const DEFAULT_WORKDIR = "/home/claude/projects";

interface Props {
  agent: Agent;
  onSelect: () => void;
  onRefresh: () => void;
}

export function AgentCard({ agent, onSelect, onRefresh }: Props) {
  const [busy, setBusy] = useState<string | null>(null);
  const [cloneOpen, setCloneOpen] = useState(false);
  const Icon = TYPE_ICON[agent.type] ?? TYPE_ICON.claude;
  const toast = useToast();
  const isActive = agent.status === "active";

  const act = async (action: string, label: string) => {
    if (busy) return;
    setBusy(action);
    try {
      const res = await fetch(`/api/agents/${encodeURIComponent(agent.name)}/${action}`, { method: "POST" });
      const j = await res.json();
      if (j.ok) toast("success", `${agent.name} ${label}`);
      else toast("error", j.error?.message ?? j.error ?? `Failed to ${action}`);
      await onRefresh();
    } catch {
      toast("error", `Failed to ${action} ${agent.name}`);
    } finally {
      setBusy(null);
    }
  };

  const del = async () => {
    if (!confirm(`Delete agent "${agent.name}"?`)) return;
    setBusy("rm");
    try {
      const res = await fetch(`/api/agents/${encodeURIComponent(agent.name)}`, { method: "DELETE" });
      const j = await res.json();
      if (j.ok) toast("success", `${agent.name} deleted`);
      else toast("error", j.error?.message ?? j.error ?? "Failed to delete");
      await onRefresh();
    } catch {
      toast("error", `Failed to delete ${agent.name}`);
    } finally {
      setBusy(null);
    }
  };

  const handleAction = (id: string | number) => {
    if (id === "start")   void act("start", "started");
    if (id === "stop")    void act("stop", "stopped");
    if (id === "restart") void act("restart", "restarted");
    if (id === "delete")  void del();
    if (id === "view")    onSelect();
    if (id === "clone")   setCloneOpen(true);
  };

  const showWorkdir = agent.workdir && agent.workdir !== DEFAULT_WORKDIR;
  const showProfile = agent.authProfile && agent.authProfile !== "default";

  return (
    <>
    <div
      className={`group flex items-center gap-4 rounded-xl border bg-surface-card px-4 py-3.5 transition-shadow hover:shadow-sm ${
        isActive
          ? "border-l-[3px] border-l-signal border-y-border-subtle border-r-border-subtle"
          : "border-border-subtle"
      }`}
    >
      {/* Type icon */}
      <div className="flex size-11 shrink-0 items-center justify-center rounded-xl bg-surface-raised text-ink-secondary">
        <Icon className="size-5" />
      </div>

      {/* Name + meta */}
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <div className="flex items-center gap-2">
          <button
            onClick={onSelect}
            className="truncate text-[0.9375rem] font-medium text-ink hover:text-signal"
          >
            {agent.name}
          </button>
          <StatusDot status={agent.status} />
          {agent.isolation === "sandboxed" && (
            <Chip
              size="sm"
              classNames={{
                base: "bg-green-100 border-0 h-auto py-0.5",
                content: "text-green-700 text-[0.625rem] font-medium px-1.5 py-0",
              }}
            >
              sandboxed
            </Chip>
          )}
        </div>
        <div className="flex items-center gap-2 text-[0.75rem] text-ink-secondary flex-wrap">
          <TypeBadge type={agent.type} />
          {agent.channels && agent.channels !== "none" && (() => {
            const CIcon = CHANNEL_ICON[agent.channels];
            return (
              <>
                <span className="text-border-hard">·</span>
                {CIcon && <CIcon className="size-3 shrink-0" />}
                <span className="capitalize">{agent.channels}</span>
              </>
            );
          })()}
          {showWorkdir && (
            <>
              <span className="text-border-hard">·</span>
              <span className="font-mono text-[0.6875rem] text-ink-muted truncate max-w-[140px]">{agent.workdir}</span>
            </>
          )}
          {showProfile && (
            <>
              <span className="text-border-hard">·</span>
              <span className="text-ink-muted">profile: {agent.authProfile}</span>
            </>
          )}
        </div>
      </div>

      {/* Actions — always visible on touch; reveal on hover at sm+ */}
      <div className="flex shrink-0 items-center gap-1.5 transition-opacity sm:opacity-0 sm:group-hover:opacity-100">
        {busy ? (
          <Spinner size="sm" />
        ) : (
          <>
            <Button
              size="sm"
              variant="bordered"
              className="h-7 min-w-0 gap-1 border-border-subtle px-2.5 text-[0.75rem] text-ink-secondary"
              onPress={() => act(isActive ? "stop" : "start", isActive ? "stopped" : "started")}
            >
              {isActive
                ? <><Square className="size-3" /> Stop</>
                : <><Play className="size-3" /> Start</>}
            </Button>
            <Dropdown>
              <Dropdown.Trigger
                className="inline-flex size-7 items-center justify-center rounded-lg text-ink-muted outline-none hover:bg-surface-raised hover:text-ink"
                aria-label={`Actions for ${agent.name}`}
              >
                <MoreVertical className="size-4" />
              </Dropdown.Trigger>
              <Dropdown.Popover placement="bottom end" className="min-w-36">
                <Dropdown.Menu onAction={handleAction}>
                  <Dropdown.Item id="view">View details</Dropdown.Item>
                  <Dropdown.Item id="restart">
                    <span className="flex items-center gap-2"><RotateCw className="size-3.5" /> Restart</span>
                  </Dropdown.Item>
                  <Dropdown.Item id="clone">
                    <span className="flex items-center gap-2"><Copy className="size-3.5" /> Clone</span>
                  </Dropdown.Item>
                  <Dropdown.Item id="delete" className="text-red-500">
                    <span className="flex items-center gap-2"><Trash2 className="size-3.5" /> Delete</span>
                  </Dropdown.Item>
                </Dropdown.Menu>
              </Dropdown.Popover>
            </Dropdown>
          </>
        )}
      </div>
    </div>
    {cloneOpen && (
      <CloneAgentModal
        sourceName={agent.name}
        onClose={() => setCloneOpen(false)}
        onCloned={() => { setCloneOpen(false); void onRefresh(); }}
      />
    )}
    </>
  );
}
