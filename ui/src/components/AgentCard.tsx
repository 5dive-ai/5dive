import { useState } from "react";
import { Button, Chip, Dropdown, Spinner } from "@heroui/react";
import { MoreVertical, RotateCw, Square, Play, Trash2 } from "lucide-react";
import type { Agent } from "../types";
import { TYPE_ICON } from "./icons";
import { StatusDot } from "./StatusDot";
import { TypeBadge } from "./TypeBadge";

interface Props {
  agent: Agent;
  onSelect: () => void;
  onRefresh: () => void;
}

export function AgentCard({ agent, onSelect, onRefresh }: Props) {
  const [busy, setBusy] = useState<string | null>(null);
  const Icon = TYPE_ICON[agent.type] ?? TYPE_ICON.claude;

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

  const handleAction = (id: string) => {
    if (id === "start")   void act("start");
    if (id === "stop")    void act("stop");
    if (id === "restart") void act("restart");
    if (id === "delete")  void del();
    if (id === "view")    onSelect();
  };

  const isActive = agent.status === "active";

  return (
    <div className="group flex items-center gap-4 rounded-xl border border-border-subtle bg-surface-card px-4 py-3.5 transition-shadow hover:shadow-sm">
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
        <div className="flex items-center gap-2 text-[0.75rem] text-ink-secondary">
          <TypeBadge type={agent.type} />
          {agent.channels && agent.channels !== "none" && (
            <>
              <span className="text-border-hard">·</span>
              <span className="capitalize">{agent.channels}</span>
            </>
          )}
        </div>
      </div>

      {/* Actions */}
      <div className="flex shrink-0 items-center gap-1.5 opacity-0 transition-opacity group-hover:opacity-100">
        {busy ? (
          <Spinner size="sm" />
        ) : (
          <>
            <Button
              size="sm"
              variant="bordered"
              className="h-7 min-w-0 gap-1 border-border-subtle px-2.5 text-[0.75rem] text-ink-secondary"
              onPress={() => act(isActive ? "stop" : "start")}
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
  );
}
