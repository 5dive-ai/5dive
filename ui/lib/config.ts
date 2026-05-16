// Per-user UI config. Lives at ~/.config/5dive/ui.json (mode 0600).
//
// Resolved on every server startup. Precedence: CLI flags / env vars > config
// file > built-in defaults. The setup helper (`5dive ui setup`) is the only
// thing that writes this file.

import { existsSync, readFileSync, writeFileSync, mkdirSync, chmodSync } from "fs";
import { homedir } from "os";
import { join } from "path";

export interface UIConfig {
  bind: { host: string; port: number };
  auth: {
    mode: "none" | "password";
    passwordHash?: string;
    sessionSecret?: string;
  };
}

const DEFAULTS: UIConfig = {
  bind: { host: "127.0.0.1", port: 5175 },
  auth: { mode: "none" },
};

export const CONFIG_DIR = join(process.env.HOME ?? homedir(), ".config", "5dive");
export const CONFIG_FILE = join(CONFIG_DIR, "ui.json");

export function loadConfig(): UIConfig {
  if (!existsSync(CONFIG_FILE)) return structuredClone(DEFAULTS);
  let raw: Partial<UIConfig>;
  try {
    raw = JSON.parse(readFileSync(CONFIG_FILE, "utf8")) as Partial<UIConfig>;
  } catch (e) {
    throw new Error(`failed to parse ${CONFIG_FILE}: ${(e as Error).message}`);
  }
  return {
    bind: { ...DEFAULTS.bind, ...(raw.bind ?? {}) },
    auth: { ...DEFAULTS.auth, ...(raw.auth ?? {}) },
  };
}

export function saveConfig(cfg: UIConfig): void {
  mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
  chmodSync(CONFIG_FILE, 0o600);
}
