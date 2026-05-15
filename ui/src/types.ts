export interface Agent {
  name: string;
  type: string;
  status: "active" | "inactive" | "failed" | "activating" | "deactivating";
  channels: string | null;
  isolation: string | null;
  workdir: string | null;
  createdAt: string | null;
}
