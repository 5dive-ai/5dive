const COLORS: Record<string, string> = {
  claude: "bg-orange-50 text-orange-700",
  codex: "bg-sky-50 text-sky-700",
  gemini: "bg-blue-50 text-blue-700",
  hermes: "bg-purple-50 text-purple-700",
  openclaw: "bg-emerald-50 text-emerald-700",
  opencode: "bg-zinc-100 text-zinc-600",
};

export function TypeBadge({ type }: { type: string }) {
  return (
    <span
      className={`rounded-md px-1.5 py-0.5 text-[0.6875rem] font-medium ${COLORS[type] ?? "bg-zinc-100 text-zinc-600"}`}
    >
      {type}
    </span>
  );
}
