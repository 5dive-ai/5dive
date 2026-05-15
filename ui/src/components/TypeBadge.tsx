import { Chip } from "@heroui/react";

const COLORS: Record<string, { bg: string; text: string }> = {
  claude:   { bg: "bg-orange-50",   text: "text-orange-700" },
  codex:    { bg: "bg-sky-50",      text: "text-sky-700" },
  gemini:   { bg: "bg-blue-50",     text: "text-blue-700" },
  hermes:   { bg: "bg-purple-50",   text: "text-purple-700" },
  openclaw: { bg: "bg-emerald-50",  text: "text-emerald-700" },
  opencode: { bg: "bg-surface-raised", text: "text-ink-secondary" },
};

export function TypeBadge({ type }: { type: string }) {
  const c = COLORS[type] ?? { bg: "bg-surface-raised", text: "text-ink-secondary" };
  return (
    <Chip
      size="sm"
      classNames={{
        base: `${c.bg} border-0 h-auto py-0.5`,
        content: `${c.text} text-[0.6875rem] font-medium px-1.5 py-0`,
      }}
    >
      {type}
    </Chip>
  );
}
