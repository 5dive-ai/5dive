# DIVE-320 — Chief of Staff (CoS) managed-bot provisioning.
#
# `5dive agent cos set|verify|mint-link|claim|rotate` — wraps the embedded
# cos-lib + cos-runner (Bot API 9.6 managed bots). A customer-owned CoS bot (Bot
# Management Mode ON) mints + manages a dedicated child bot per agent, killing the
# manual BotFather token paste. Per-customer CoS only (no central manager = no
# fleet SPOF; detach-after-mint is impossible, verified). The TS is embedded so
# the bundle is self-contained on any box; written to /opt/5dive on first use.

COS_ENV_DEFAULT="/etc/5dive/connectors/cos.env"
COS_RUN_DIR="/opt/5dive"

_cos_resolve_bun() {
  local c
  for c in /usr/local/bin/bun /home/claude/.bun/bin/bun; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  c=$(sudo -u claude -i bash -lc 'command -v bun' 2>/dev/null | tail -1)
  [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  printf '/usr/local/bin/bun'
}

# Write the embedded TS modules to /opt/5dive (idempotent). cos-runner imports
# ./cos-lib.ts so both must sit in the same dir.
_cos_install_runner() {
  mkdir -p "$COS_RUN_DIR"
  cat > "$COS_RUN_DIR/cos-lib.ts" <<'COS_LIB_TS'
// DIVE-320 — Chief of Staff (CoS) minting core.
//
// A CoS bot is a customer-owned Telegram bot with Bot Management Mode ON
// (can_manage_bots=true). It creates + manages a dedicated child bot per agent
// on the customer's behalf, via Bot API 9.6 "Managed Bots" — replacing the
// manual BotFather token-paste in onboarding.
//
// This module is the pure, side-effect-light core (raw api.telegram.org calls,
// no filesystem) so it can be driven by the CLI bash commands AND unit-tested.
// Architecture: per-customer CoS only (no central manager) — a CoS can fetch the
// token of any child it created, so a leak is contained to one customer's fleet.
// (Detach-after-mint is impossible: verified no detach API exists, 2026-06-13.)

const API = (token: string, method: string) =>
  `https://api.telegram.org/bot${token}/${method}`;

export type TgResult<T> = { ok: true; result: T } | { ok: false; error_code?: number; description?: string };

async function call<T = unknown>(token: string, method: string, params: Record<string, unknown> = {}): Promise<TgResult<T>> {
  try {
    const res = await fetch(API(token, method), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params),
    });
    return (await res.json()) as TgResult<T>;
  } catch (e) {
    return { ok: false, description: `transport: ${(e as Error).message}` };
  }
}

export type CosIdentity = { id: number; username: string; canManageBots: boolean };

/** Verify a token is a usable CoS: reachable AND has Bot Management Mode on. */
export async function verifyCos(cosToken: string): Promise<
  { ok: true; cos: CosIdentity } | { ok: false; reason: "unreachable" | "not_manager"; detail?: string }
> {
  const me = await call<{ id: number; username: string; can_manage_bots?: boolean }>(cosToken, "getMe");
  if (!me.ok) return { ok: false, reason: "unreachable", detail: me.description };
  if (!me.result.can_manage_bots)
    return { ok: false, reason: "not_manager", detail: "Bot Management Mode is off (BotFather → Bot Settings → Bot Management Mode → ON)" };
  return { ok: true, cos: { id: me.result.id, username: me.result.username, canManageBots: true } };
}

/** Build the one-tap deep link that prefills the child bot's username. */
export function mintDeepLink(cosUsername: string, suggestedUsername: string): string {
  return `https://t.me/newbot/${cosUsername}/${suggestedUsername}`;
}

export type MintedChild = { botId: number; username: string; ownerId: number };

/**
 * Poll the CoS's update queue for a managed_bot create. Returns the new child
 * once seen (optionally filtered to a target username). NOTE: getUpdates has a
 * single consumer — in production this runs inside the dedicated CoS listener,
 * never alongside another poller on the same token.
 */
export async function awaitMintedChild(
  cosToken: string,
  opts: { targetUsername?: string; timeoutMs?: number; offset?: number } = {},
): Promise<{ ok: true; child: MintedChild; nextOffset: number } | { ok: false; reason: "timeout" | "error"; detail?: string }> {
  const deadline = Date.now() + (opts.timeoutMs ?? 120_000);
  let offset = opts.offset ?? 0;
  // eslint-disable-next-line no-constant-condition
  while (Date.now() < deadline) {
    const ups = await call<Array<Record<string, any>>>(cosToken, "getUpdates", {
      timeout: 25,
      offset,
      allowed_updates: ["managed_bot"],
    });
    if (!ups.ok) return { ok: false, reason: "error", detail: ups.description };
    for (const u of ups.result) {
      offset = Math.max(offset, (u.update_id ?? 0) + 1);
      const mb = u.managed_bot ?? u.message?.managed_bot_created;
      const bot = mb?.bot;
      const owner = mb?.user ?? u.message?.from;
      if (bot?.id && (!opts.targetUsername || bot.username === opts.targetUsername)) {
        return { ok: true, child: { botId: bot.id, username: bot.username, ownerId: owner?.id ?? 0 }, nextOffset: offset };
      }
    }
  }
  return { ok: false, reason: "timeout" };
}

/** Fetch the bot token of a child the CoS manages. */
export async function getChildToken(cosToken: string, childBotId: number): Promise<{ ok: true; token: string } | { ok: false; detail?: string }> {
  const r = await call<string | { token: string }>(cosToken, "getManagedBotToken", { user_id: childBotId });
  if (!r.ok) return { ok: false, detail: r.description };
  const token = typeof r.result === "string" ? r.result : r.result.token;
  return { ok: true, token };
}

/** Rotate a child's token (e.g. on suspected leak). Invalidates the old one. */
export async function rotateChildToken(cosToken: string, childBotId: number): Promise<{ ok: true; token: string } | { ok: false; detail?: string }> {
  const r = await call<string | { token: string }>(cosToken, "replaceManagedBotToken", { user_id: childBotId });
  if (!r.ok) return { ok: false, detail: r.description };
  const token = typeof r.result === "string" ? r.result : r.result.token;
  return { ok: true, token };
}

/** Auto-configure a freshly minted child bot: display name, description, avatar. */
export async function configureChild(
  childToken: string,
  cfg: { name?: string; description?: string; shortDescription?: string; avatarPng?: Uint8Array },
): Promise<{ ok: true } | { ok: false; failed: string[] }> {
  const failed: string[] = [];
  if (cfg.name) {
    const r = await call(childToken, "setMyName", { name: cfg.name });
    if (!r.ok) failed.push(`name:${r.description}`);
  }
  if (cfg.description) {
    const r = await call(childToken, "setMyDescription", { description: cfg.description });
    if (!r.ok) failed.push(`description:${r.description}`);
  }
  if (cfg.shortDescription) {
    const r = await call(childToken, "setMyShortDescription", { short_description: cfg.shortDescription });
    if (!r.ok) failed.push(`shortDescription:${r.description}`);
  }
  if (cfg.avatarPng) {
    // Bot API 9.6 setMyProfilePhoto needs the InputProfilePhoto wrapper +
    // multipart attach:// — a raw photo field fails "photo isn't specified".
    const fd = new FormData();
    fd.append("photo", JSON.stringify({ type: "static", photo: "attach://pic" }));
    fd.append("pic", new Blob([cfg.avatarPng], { type: "image/png" }), "avatar.png");
    try {
      const res = await fetch(API(childToken, "setMyProfilePhoto"), { method: "POST", body: fd });
      const j = (await res.json()) as TgResult<boolean>;
      if (!j.ok) failed.push(`avatar:${j.description}`);
    } catch (e) {
      failed.push(`avatar:transport:${(e as Error).message}`);
    }
  }
  return failed.length ? { ok: false, failed } : { ok: true };
}
COS_LIB_TS
  cat > "$COS_RUN_DIR/cos-runner.ts" <<'COS_RUNNER_TS'
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

  // verify + mint-link wrap their result in the standard CLI envelope
  // {ok:true,data:{...}} so the dashboard's execAgent (which extracts `.data`)
  // reads them like any other command. (claim/rotate stay bare — they're
  // parsed by the create-path bash via `.token`/`.reason`, not the dashboard.)
  if (sub === "verify") {
    const v = await verifyCos(token);
    if (!v.ok) out({ ok: false, reason: v.reason, detail: v.detail });
    out({ ok: true, data: { username: v.cos.username, id: v.cos.id } });
  }

  if (sub === "mint-link") {
    const suggested = arg("suggested");
    if (!suggested) out({ ok: false, detail: "--suggested=<username> required" });
    const v = await verifyCos(token);
    if (!v.ok) out({ ok: false, reason: v.reason, detail: v.detail });
    out({ ok: true, data: { deepLink: mintDeepLink(v.cos.username, suggested!), suggested } });
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

  if (sub === "set-avatar") {
    // The caller passes the AGENT's OWN bot token via COS_TOKEN_OVERRIDE (a
    // bot sets its own profile photo — no CoS token needed). Reuses the proven
    // InputProfilePhoto attach:// path in configureChild.
    const avatar = arg("avatar");
    if (!avatar) out({ ok: false, detail: "--avatar=<png path> required" });
    const res = await configureChild(token, { avatarPng: new Uint8Array(readFileSync(avatar!)) });
    if (!res.ok) out({ ok: false, detail: `setMyProfilePhoto failed: ${res.failed.join(", ")}` });
    out({ ok: true });
  }

  out({ ok: false, detail: `unknown cos subcommand: ${sub} (verify|mint-link|claim|rotate|set-avatar)` });
} catch (e) {
  out({ ok: false, detail: (e as Error).message });
}
COS_RUNNER_TS
  chmod 644 "$COS_RUN_DIR/cos-lib.ts" "$COS_RUN_DIR/cos-runner.ts"
}

cmd_agent_cos() {
  local sub="${1:-}"; shift || true
  case "$sub" in set|verify|mint-link|claim|rotate|set-avatar) ;; *)
    fail "$E_USAGE" "usage: 5dive agent cos set|verify|mint-link|claim|rotate|set-avatar [--token=<tok>] [--suggested=<uname>] [--name=<agent>] [--agent=<name>] [--avatar=<png>] [--bot-id=<id>]" ;;
  esac
  local cos_env="${COS_ENV_FILE:-$COS_ENV_DEFAULT}"
  _cos_install_runner
  local bun; bun=$(_cos_resolve_bun)

  # `set` persists a pasted CoS token after verifying Bot Management Mode is on.
  if [[ "$sub" == "set" ]]; then
    local tok="" a
    for a in "$@"; do case "$a" in --token=*) tok="${a#--token=}" ;; esac; done
    [[ -n "$tok" ]] || fail "$E_USAGE" "usage: 5dive agent cos set --token=<cos bot token>"
    local res; res=$(COS_TOKEN_OVERRIDE="$tok" "$bun" "$COS_RUN_DIR/cos-runner.ts" verify)
    if [[ "$res" == *'"ok":true'* ]]; then
      mkdir -p "$(dirname "$cos_env")"
      ( umask 077; printf 'TEST_TG_COS_BOT_TOKEN=%s\n' "$tok" > "$cos_env" )
      chmod 600 "$cos_env"
      printf '%s\n' "$res"
      return 0
    fi
    printf '%s\n' "$res"; return 1
  fi

  # `set-avatar` sets a SPECIFIC agent's bot profile photo. A bot sets its own
  # photo with its OWN token, so this needs the agent's token (not the CoS one)
  # — works for any telegram agent, cos-minted or pasted. Resolve the agent's
  # stored TELEGRAM_BOT_TOKEN and hand it to the runner via COS_TOKEN_OVERRIDE.
  if [[ "$sub" == "set-avatar" ]]; then
    local agent="" avatar="" a
    for a in "$@"; do case "$a" in --agent=*) agent="${a#--agent=}" ;; --avatar=*) avatar="${a#--avatar=}" ;; esac; done
    [[ -n "$agent" && -n "$avatar" ]] || fail "$E_USAGE" "usage: 5dive agent cos set-avatar --agent=<name> --avatar=<png path>"
    valid_name "$agent" || fail "$E_VALIDATION" "invalid --agent (lowercase letters/digits/hyphens, start letter, <=16 chars)"
    [[ -r "$avatar" ]] || fail "$E_NOT_FOUND" "--avatar not readable: $avatar"
    local tok_env="$(dirname "$cos_env")/telegram-${agent}.env" atok
    [[ -r "$tok_env" ]] || fail "$E_NOT_FOUND" "no telegram token for agent '$agent' at $tok_env (is it a telegram agent?)"
    atok=$(sudo grep -m1 -oP '(?<=^TELEGRAM_BOT_TOKEN=).*' "$tok_env" 2>/dev/null | tr -d '"'"'"'' | tr -d '[:space:]')
    [[ -n "$atok" ]] || fail "$E_NOT_FOUND" "TELEGRAM_BOT_TOKEN empty/missing in $tok_env"
    COS_TOKEN_OVERRIDE="$atok" "$bun" "$COS_RUN_DIR/cos-runner.ts" set-avatar --avatar="$avatar"
    return $?
  fi

  # All other subcommands read the persisted token.
  [[ -r "$cos_env" ]] || fail "$E_NOT_FOUND" "no CoS token at $cos_env — run: 5dive agent cos set --token=<token>"
  COS_ENV_FILE="$cos_env" "$bun" "$COS_RUN_DIR/cos-runner.ts" "$sub" "$@"
}
