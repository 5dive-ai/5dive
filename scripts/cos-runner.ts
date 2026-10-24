// DIVE-320 — thin CLI runner over cos-lib. Invoked by the bash `5dive agent cos`
// command. Each subcommand prints a single JSON line on stdout (machine-readable
// for the dashboard) and exits non-zero on failure.
//
// v1 deliberately has NO always-on listener service: a freshly minted child's
// managed_bot update sits in the CoS getUpdates queue until claimed, so `claim`
// does a short on-demand poll — same pattern as `team-bot discover`. The CoS bot
// is dedicated (no plugin polls it), so on-demand getUpdates is safe.
//
// Subcommands:
//   verify                                   -> {ok, username, id}
//   mint-link  --suggested=<uname>           -> {ok, deepLink, suggested}
//   claim      --suggested=<uname> --name=<agent> [--avatar=<png path>]
//                                            -> {ok, token, botId, username} (configures child)
//   rotate     --bot-id=<id>                 -> {ok, token}

import { verifyCos, mintDeepLink, awaitMintedChild, getChildToken, rotateChildToken, configureChild } from "./cos-lib.ts";
import { readFileSync } from "node:fs";

const COS_ENV = process.env.COS_ENV_FILE || "/etc/5dive/connectors/cos.env";

function cosToken(): string {
  // A pasted token (pre-persist verify, used by the dashboard) takes precedence.
  if (process.env.COS_TOKEN_OVERRIDE) return process.env.COS_TOKEN_OVERRIDE.trim();
  const raw = readFileSync(COS_ENV, "utf8");
  // Accept either TEST_TG_COS_BOT_TOKEN (current) or COS_BOT_TOKEN.
  const m = raw.match(/^\s*(?:TEST_TG_COS_BOT_TOKEN|COS_BOT_TOKEN)\s*=\s*(.+?)\s*$/m);
  if (!m) throw new Error(`no CoS token in ${COS_ENV}`);
  return m[1].replace(/^["']|["']$/g, "").trim();
}

function arg(name: string): string | undefined {
  const p = process.argv.find((a) => a.startsWith(`--${name}=`));
  return p ? p.slice(name.length + 3) : undefined;
}

function out(obj: Record<string, unknown>): never {
  process.stdout.write(JSON.stringify(obj) + "\n");
  process.exit(obj.ok ? 0 : 1);
}

const sub = process.argv[2];

try {
  const token = cosToken();

  if (sub === "verify") {
    const v = await verifyCos(token);
    if (!v.ok) out({ ok: false, reason: v.reason, detail: v.detail });
    out({ ok: true, username: v.cos.username, id: v.cos.id });
  }

  if (sub === "mint-link") {
    const suggested = arg("suggested");
    if (!suggested) out({ ok: false, detail: "--suggested=<username> required" });
    const v = await verifyCos(token);
    if (!v.ok) out({ ok: false, reason: v.reason, detail: v.detail });
    out({ ok: true, deepLink: mintDeepLink(v.cos.username, suggested!), suggested });
  }

  if (sub === "claim") {
    const suggested = arg("suggested");
    const name = arg("name");
    if (!suggested || !name) out({ ok: false, detail: "--suggested and --name required" });
    const minted = await awaitMintedChild(token, { targetUsername: suggested, timeoutMs: Number(arg("timeout-ms") ?? 15_000) });
    if (!minted.ok) out({ ok: false, reason: minted.reason, detail: minted.detail });
    const t = await getChildToken(token, minted.child.botId);
    if (!t.ok) out({ ok: false, detail: t.detail });
    const avatarPath = arg("avatar");
    const display = name!.charAt(0).toUpperCase() + name!.slice(1);
    await configureChild(t.token, {
      name: display,
      description: `${display} — a 5dive agent.`,
      shortDescription: "5dive agent",
      avatarPng: avatarPath ? new Uint8Array(readFileSync(avatarPath)) : undefined,
    });
    out({ ok: true, token: t.token, botId: minted.child.botId, username: minted.child.username });
  }

  if (sub === "rotate") {
    const botId = Number(arg("bot-id"));
    if (!botId) out({ ok: false, detail: "--bot-id=<id> required" });
    const r = await rotateChildToken(token, botId);
    if (!r.ok) out({ ok: false, detail: r.detail });
    out({ ok: true, token: r.token });
  }

  out({ ok: false, detail: `unknown cos subcommand: ${sub} (verify|mint-link|claim|rotate)` });
} catch (e) {
  out({ ok: false, detail: (e as Error).message });
}
