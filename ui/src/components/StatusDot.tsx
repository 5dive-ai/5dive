interface Props {
  status: string;
}

const COLOR: Record<string, string> = {
  active: "bg-green-status",
  activating: "bg-amber-status animate-pulse",
  deactivating: "bg-amber-status animate-pulse",
  failed: "bg-red-500",
  inactive: "bg-border-hard",
};

export function StatusDot({ status }: Props) {
  return (
    <span
      className={`inline-block size-1.5 rounded-full ${COLOR[status] ?? "bg-border-hard"}`}
      title={status}
    />
  );
}
