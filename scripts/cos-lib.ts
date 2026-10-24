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
