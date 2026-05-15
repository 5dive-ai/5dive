interface Props {
  status: string;
}

const COLOR: Record<string, string> = {
  active: "bg-green-500",
  activating: "bg-yellow-400 animate-pulse",
  deactivating: "bg-yellow-400 animate-pulse",
  failed: "bg-red-500",
  inactive: "bg-zinc-300",
};

export function StatusDot({ status }: Props) {
  return (
    <span
      className={`inline-block size-1.5 rounded-full ${COLOR[status] ?? "bg-zinc-300"}`}
      title={status}
    />
  );
}
