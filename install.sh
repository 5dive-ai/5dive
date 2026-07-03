#!/usr/bin/env bash
# 5dive CLI installer / uninstaller
# Install:   curl -fsSL https://install.5dive.com | sudo bash
# Upgrade:   curl -fsSL https://install.5dive.com | sudo bash -s -- --upgrade
# Uninstall: curl -fsSL https://install.5dive.com | sudo bash -s -- --uninstall
set -euo pipefail

# GitHub org our repos live under. The org is being renamed
# 5dive-com -> 5dive-ai (2026-06); installs must work on either side of the
# rename, so probe the new org once and fall back to the old name. GH_ORG
# env overrides the probe (CI, forks, air-gapped mirrors). Standalone copy
# of the bundle's gh_org() — this script runs before the bundle exists.
if [[ -z "${GH_ORG:-}" ]]; then
  if curl -fsI --max-time 8 "https://raw.githubusercontent.com/5dive-ai/5dive/main/install.sh" >/dev/null 2>&1; then
    GH_ORG="5dive-ai"
  else
    GH_ORG="5dive-com"
  fi
fi

# Source for binaries / hooks / skills. Overridable for offline installs,
# enterprise mirrors, and pre-publish smoke tests (which point this at a
# `file://` bundle of the working tree).
REPO="${REPO:-https://raw.githubusercontent.com/$GH_ORG/5dive/main}"
BIN_DIR="/usr/local/bin"
STATE_DIR="/var/lib/5dive"
CONNECTORS_DIR="/etc/5dive/connectors"
SYSTEMD_DIR="/etc/systemd/system"
LIB_DIR="/usr/local/lib/5dive"
NODE_VERSION="22"

die() { echo "error: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
say() { echo "→ $*"; }

[[ $EUID -eq 0 ]] || die "run as root: curl -fsSL ... | sudo bash"

# Refresh CLI binaries, systemd unit, hooks, and skills from $REPO. Shared by
# the default install path and `--upgrade`. Never touches state, auth profiles,
# the claude user, apt packages, nvm, or bun — so it's safe to rerun on a
# populated host.
refresh_managed_files() {
  curl -fsSL "$REPO/5dive" -o "$BIN_DIR/5dive"
  chmod 755 "$BIN_DIR/5dive"
  ok "5dive → $BIN_DIR/5dive"

  # DIVE-544: per-customer standup digest. The cron runs HOURLY but `digest tick`
  # is gated on a per-box pref that defaults OFF — nothing is delivered until a
  # customer runs `/digest on` (Mark: opt-in only). The cron is idempotent
  # (rewritten every update); the PREF is seeded once and never clobbered, so an
  # off/on choice + custom hour survives CLI updates.
  if [[ -d /etc/cron.d ]]; then
    cat > /etc/cron.d/5dive-digest <<'DIGESTCRON'
# 5dive per-customer standup digest (DIVE-544) — hourly driver; gated on the
# per-box pref (default OFF, set via the telegram /digest command).
0 * * * * root /usr/local/bin/5dive digest tick >> /var/log/5dive-digest.log 2>&1
DIGESTCRON
    chmod 644 /etc/cron.d/5dive-digest
    ok "/etc/cron.d/5dive-digest (standup digest driver)"
  fi
  # Seed the pref OFF on first install only — never overwrite a customer's choice.
  if [[ -n "${STATE_DIR:-}" && ! -f "${STATE_DIR}/digest.json" ]]; then
    mkdir -p "${STATE_DIR}"
    echo '{"enabled":false,"hour":7}' > "${STATE_DIR}/digest.json"
    ok "digest pref seeded (off by default)"
  fi

  # DIVE-948: cap systemd journal growth. With no explicit limit journald drifts
  # to the distro default (~10% of disk, up to 4G); on the small cx plans that's
  # wasteful (boxes were reaching ~500M+/month). Idempotent drop-in, rewritten
  # every update; applying it back-fills the existing fleet via the daily refresh.
  # Bounds ONLY logs, never app data. 200M / 14d (tunable).
  if [[ -d /etc/systemd ]]; then
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/5dive.conf <<'JOURNALD'
# 5dive managed (DIVE-948) — bound journal disk use. Rewritten on every update.
[Journal]
SystemMaxUse=200M
MaxRetentionSec=14d
JOURNALD
    chmod 644 /etc/systemd/journald.conf.d/5dive.conf
    # Apply the new SystemMaxUse and reclaim immediately (retroactive on boxes
    # already over the cap). Both best-effort — never fail the update over logs.
    systemctl restart systemd-journald 2>/dev/null || true
    journalctl --vacuum-size=200M >/dev/null 2>&1 || true
    ok "/etc/systemd/journald.conf.d/5dive.conf (journal capped 200M/14d)"
  fi

  curl -fsSL "$REPO/5dive-agent-start" -o "$BIN_DIR/5dive-agent-start"
  chmod 755 "$BIN_DIR/5dive-agent-start"
  ok "5dive-agent-start → $BIN_DIR/5dive-agent-start"

  # Refresh helper — plugin updates are SHA-pinned in installed_plugins.json,
  # so a claude restart alone won't pick up new plugin versions. The daily
  # update cron calls this script before restarting agents.
  curl -fsSL "$REPO/5dive-refresh-plugins.sh" -o "$BIN_DIR/5dive-refresh-plugins.sh"
  chmod 755 "$BIN_DIR/5dive-refresh-plugins.sh"
  ok "5dive-refresh-plugins.sh → $BIN_DIR/5dive-refresh-plugins.sh"

  # Skills backfill — brings existing agents up to the current default skill
  # set (new defaults like openagent, DIVE-658). The daily update cron runs it
  # right after the plugin refresh, before agents restart.
  curl -fsSL "$REPO/5dive-refresh-skills.sh" -o "$BIN_DIR/5dive-refresh-skills.sh"
  chmod 755 "$BIN_DIR/5dive-refresh-skills.sh"
  ok "5dive-refresh-skills.sh → $BIN_DIR/5dive-refresh-skills.sh"

  curl -fsSL "$REPO/systemd/5dive-agent%40.service" -o "$SYSTEMD_DIR/5dive-agent@.service"
  ok "systemd template installed"

  # hermes-perms watchdog — hermes resets /home/claude/.hermes to 0700 on
  # every auth.json/config.yaml write, blocking agent-<name> users (in the
  # `claude` group) from traversing to venv/bin/hermes. The .path unit
  # watches the dir; the .service oneshot chmods it back to 0775.
  curl -fsSL "$REPO/systemd/5dive-hermes-perms.path"    -o "$SYSTEMD_DIR/5dive-hermes-perms.path"
  curl -fsSL "$REPO/systemd/5dive-hermes-perms.service" -o "$SYSTEMD_DIR/5dive-hermes-perms.service"
  ok "hermes-perms units installed"

  systemctl daemon-reload
  # Pre-create the watched dir if it's missing so enabling the path unit
  # doesn't immediately fail. The /home/claude user is created earlier in
  # this script's install path; on --upgrade re-runs the dir is already
  # there. Fail-soft: if /home/claude doesn't exist (atypical), skip.
  if [[ -d /home/claude ]]; then
    # setgid 2770: new files inherit the `claude` group, so agent-<name> users
    # (in that group) can read auth state hermes writes — mirroring the perms
    # established at host-install time in scripts/install/users.sh.
    install -d -m 2770 -o claude -g claude /home/claude/.hermes
    systemctl enable --now 5dive-hermes-perms.path >/dev/null 2>&1 || true
  fi

  install -d -m 755 "$LIB_DIR" "$LIB_DIR/skills/notify-user"
  # Remove the deprecated sender-side PreToolUse mirror: it read the
  # pre-expansion command string, so it couldn't see heredoc bodies. The
  # receiver-side userprompt-mirror-inter-agent.sh below replaces it.
  rm -f "$LIB_DIR/mirror-agent-send.sh"
  for hook in stop-failure-telegram.sh resume-after-reset.sh \
              pretool-telegram-question.sh stop-telegram-reply-check.sh \
              posttool-telegram-relay.sh userprompt-mirror-inter-agent.sh \
              stop-mirror-inter-agent.sh push-notify.sh \
              sessionstart-resume-context.sh; do
    curl -fsSL "$REPO/hooks/$hook" -o "$LIB_DIR/$hook"
    chmod 755 "$LIB_DIR/$hook"
    ok "$hook"
  done
  curl -fsSL "$REPO/skills/notify-user/SKILL.md" -o "$LIB_DIR/skills/notify-user/SKILL.md"
  chmod 644 "$LIB_DIR/skills/notify-user/SKILL.md"
  ok "notify-user skill"

  # Stage 5dive-cli skill (from the skills repo — separate repo from this
  # CLI's source). Unlike notify-user which is a single SKILL.md, this one
  # ships SKILL.md plus a references/ subdir, so we tarball the whole subdir
  # in one shot. update.sh's per-agent refresh loop syncs from here, so an
  # existing agent's 5dive-cli skill picks up upstream changes on the daily
  # 03:00 cron instead of being frozen at agent-create time.
  SKILLS_REPO_TARBALL="${SKILLS_REPO_TARBALL:-https://github.com/$GH_ORG/skills/archive/refs/heads/main.tar.gz}"
  install -d -m 755 "$LIB_DIR/skills/5dive-cli"
  _skill_tmp=$(mktemp -d)
  if curl -fsSL "$SKILLS_REPO_TARBALL" \
      | tar -xz -C "$_skill_tmp" --strip-components=1 'skills-main/5dive-cli' 2>/dev/null \
      && [ -f "$_skill_tmp/5dive-cli/SKILL.md" ]; then
    # cp -a preserves the source's references/ dir layout; --no-target-directory
    # would clobber, so use the trailing slash + dot to copy contents.
    cp -a "$_skill_tmp/5dive-cli/." "$LIB_DIR/skills/5dive-cli/"
    find "$LIB_DIR/skills/5dive-cli" -type f -exec chmod 644 {} +
    find "$LIB_DIR/skills/5dive-cli" -type d -exec chmod 755 {} +
    ok "5dive-cli skill"
  else
    echo "warn: failed to stage 5dive-cli skill from $SKILLS_REPO_TARBALL — existing agents won't see updates until next try" >&2
  fi
  rm -rf "$_skill_tmp"

  # Stage the telegram-codex plugin (from the 5dive-plugins repo). Codex has
  # no plugin marketplace, so unlike claude there's nothing to install per
  # agent — its MCP server + lifecycle hooks run from this one shared checkout.
  # 5dive-agent-start points each codex+telegram agent's config.toml at
  # $LIB_DIR/telegram-codex/{server.ts,hooks/*.ts}, and server.ts resolves each
  # agent's own state dir from $HOME, so a single staged copy serves every
  # codex agent. Whole-subdir tarball (like 5dive-cli above), then `bun install`
  # the runtime deps (grammy) so the hooks/server actually run. cp -a overlays
  # the source onto any existing copy so node_modules survives across --upgrade
  # refreshes; bun reconciles deps against the (possibly updated) lockfile.
  CODEX_PLUGIN_TARBALL="${CODEX_PLUGIN_TARBALL:-https://github.com/$GH_ORG/5dive-plugins/archive/refs/heads/main.tar.gz}"
  _cdx_tmp=$(mktemp -d)
  if curl -fsSL "$CODEX_PLUGIN_TARBALL" \
      | tar -xz -C "$_cdx_tmp" --strip-components=1 '5dive-plugins-main/plugins/telegram-codex' 2>/dev/null \
      && [ -f "$_cdx_tmp/plugins/telegram-codex/server.ts" ]; then
    install -d -m 755 "$LIB_DIR/telegram-codex"
    cp -a "$_cdx_tmp/plugins/telegram-codex/." "$LIB_DIR/telegram-codex/"
    # bun lives in claude's home; install deps as claude (needs write on the
    # staged dir), then make the tree world-readable+traversable so every
    # agent-<name> user (incl. ones outside the claude group) can run
    # server.ts + the hooks.
    if id -u claude >/dev/null 2>&1; then
      chown -R claude:claude "$LIB_DIR/telegram-codex"
      if sudo -u claude -H bash -lc "cd $(printf %q "$LIB_DIR/telegram-codex") && bun install --production --ignore-scripts --no-progress --no-summary" >/dev/null 2>&1; then
        chmod -R a+rX "$LIB_DIR/telegram-codex"
        ok "telegram-codex plugin"
      else
        echo "warn: bun install for telegram-codex failed — codex+telegram agents won't have the bridge until the next successful refresh" >&2
      fi
    else
      echo "warn: no claude user — skipping telegram-codex bun install" >&2
    fi
  else
    echo "warn: failed to stage telegram-codex from $CODEX_PLUGIN_TARBALL — codex+telegram won't be available until the next successful refresh" >&2
  fi
  rm -rf "$_cdx_tmp"

  # Stage the telegram-grok plugin — same shape as telegram-codex above. grok
  # also has no plugin marketplace; its MCP server + lifecycle hooks run from
  # this one shared checkout via absolute paths written into ~/.grok/config.toml
  # by 5dive-agent-start. Override the tarball with GROK_PLUGIN_TARBALL for
  # offline / test installs.
  GROK_PLUGIN_TARBALL="${GROK_PLUGIN_TARBALL:-https://github.com/$GH_ORG/5dive-plugins/archive/refs/heads/main.tar.gz}"
  _grk_tmp=$(mktemp -d)
  if curl -fsSL "$GROK_PLUGIN_TARBALL" \
      | tar -xz -C "$_grk_tmp" --strip-components=1 '5dive-plugins-main/plugins/telegram-grok' 2>/dev/null \
      && [ -f "$_grk_tmp/plugins/telegram-grok/server.ts" ]; then
    install -d -m 755 "$LIB_DIR/telegram-grok"
    cp -a "$_grk_tmp/plugins/telegram-grok/." "$LIB_DIR/telegram-grok/"
    if id -u claude >/dev/null 2>&1; then
      chown -R claude:claude "$LIB_DIR/telegram-grok"
      if sudo -u claude -H bash -lc "cd $(printf %q "$LIB_DIR/telegram-grok") && bun install --production --ignore-scripts --no-progress --no-summary" >/dev/null 2>&1; then
        chmod -R a+rX "$LIB_DIR/telegram-grok"
        ok "telegram-grok plugin"
      else
        echo "warn: bun install for telegram-grok failed — grok+telegram agents won't have the bridge until the next successful refresh" >&2
      fi
    else
      echo "warn: no claude user — skipping telegram-grok bun install" >&2
    fi
  else
    echo "warn: failed to stage telegram-grok from $GROK_PLUGIN_TARBALL — grok+telegram won't be available until the next successful refresh" >&2
  fi

  # Stage the telegram-agy plugin — same shape as telegram-grok above.
  # antigravity (agy) has no plugin marketplace, so every agy+telegram agent
  # shares this one checkout via absolute paths written into the GLOBAL
  # ~/.gemini/config/{mcp_config.json,hooks.json} by 5dive-agent-start (agy
  # doesn't auto-load a plugin's mcp_config/hooks — only skills/agents).
  # Override the tarball with AGY_PLUGIN_TARBALL for offline / pinned installs.
  AGY_PLUGIN_TARBALL="${AGY_PLUGIN_TARBALL:-https://github.com/$GH_ORG/5dive-plugins/archive/refs/heads/main.tar.gz}"
  _agy_tmp="$(mktemp -d)"
  if curl -fsSL "$AGY_PLUGIN_TARBALL" \
      | tar -xz -C "$_agy_tmp" --strip-components=1 '5dive-plugins-main/plugins/telegram-agy' 2>/dev/null \
      && [ -f "$_agy_tmp/plugins/telegram-agy/server.ts" ]; then
    install -d -m 755 "$LIB_DIR/telegram-agy"
    cp -a "$_agy_tmp/plugins/telegram-agy/." "$LIB_DIR/telegram-agy/"
    if id -u claude >/dev/null 2>&1; then
      chown -R claude:claude "$LIB_DIR/telegram-agy"
      if sudo -u claude -H bash -lc "cd $(printf %q "$LIB_DIR/telegram-agy") && bun install --production --ignore-scripts --no-progress --no-summary" >/dev/null 2>&1; then
        chmod -R a+rX "$LIB_DIR/telegram-agy"
        ok "telegram-agy plugin"
      else
        echo "warn: bun install for telegram-agy failed — antigravity+telegram agents won't have the bridge until the next successful refresh" >&2
      fi
    else
      echo "warn: no claude user — skipping telegram-agy bun install" >&2
    fi
  else
    echo "warn: failed to stage telegram-agy from $AGY_PLUGIN_TARBALL — antigravity+telegram won't be available until the next successful refresh" >&2
  fi
  rm -rf "$_agy_tmp"
  rm -rf "$_grk_tmp"

  # Stage the telegram-opencode plugin — same shape as telegram-agy above.
  # opencode has no plugin marketplace; its telegram bridge is a standalone
  # long-running relay (server.ts over `opencode serve`) launched by
  # 5dive-agent-start from this one shared checkout via absolute paths. Without
  # this, opencode+telegram agents can't be provisioned (install_channel_for_
  # opencode_agent's plugin-dir check fails) — i.e. opencode telegram is a
  # no-op on customer boxes until staged. Override with OPENCODE_PLUGIN_TARBALL
  # for offline / pinned installs.
  OPENCODE_PLUGIN_TARBALL="${OPENCODE_PLUGIN_TARBALL:-https://github.com/$GH_ORG/5dive-plugins/archive/refs/heads/main.tar.gz}"
  _ocode_tmp="$(mktemp -d)"
  if curl -fsSL "$OPENCODE_PLUGIN_TARBALL" \
      | tar -xz -C "$_ocode_tmp" --strip-components=1 '5dive-plugins-main/plugins/telegram-opencode' 2>/dev/null \
      && [ -f "$_ocode_tmp/plugins/telegram-opencode/server.ts" ]; then
    install -d -m 755 "$LIB_DIR/telegram-opencode"
    cp -a "$_ocode_tmp/plugins/telegram-opencode/." "$LIB_DIR/telegram-opencode/"
    if id -u claude >/dev/null 2>&1; then
      chown -R claude:claude "$LIB_DIR/telegram-opencode"
      if sudo -u claude -H bash -lc "cd $(printf %q "$LIB_DIR/telegram-opencode") && bun install --production --ignore-scripts --no-progress --no-summary" >/dev/null 2>&1; then
        chmod -R a+rX "$LIB_DIR/telegram-opencode"
        ok "telegram-opencode plugin"
      else
        echo "warn: bun install for telegram-opencode failed — opencode+telegram agents won't have the bridge until the next successful refresh" >&2
      fi
    else
      echo "warn: no claude user — skipping telegram-opencode bun install" >&2
    fi
  else
    echo "warn: failed to stage telegram-opencode from $OPENCODE_PLUGIN_TARBALL — opencode+telegram won't be available until the next successful refresh" >&2
  fi
  rm -rf "$_ocode_tmp"

  # CLAUDE.md fragment that preseed_claude_agent drops into a telegram-paired
  # agent's $HOME/.claude/ so the per-turn reply mandate + AskUserQuestion /
  # ExitPlanMode warning ride with the agents that actually need them — not
  # the shared projects-level file every agent reads.
  curl -fsSL "$REPO/telegram-agent-CLAUDE.md" -o "$LIB_DIR/telegram-agent-CLAUDE.md"
  chmod 644 "$LIB_DIR/telegram-agent-CLAUDE.md"
  ok "telegram-agent-CLAUDE.md"

  # CLAUDE.md fragment appended to every claude-type agent's $HOME/.claude/
  # CLAUDE.md at create: the self-gated Fable-orchestrator + per-subagent
  # model-tiering default (DIVE-899 — inert unless the session model is Fable).
  # Fail-soft: a missing/transient-404 content fragment shouldn't hard-abort
  # the whole install (curl -f exits 37 on a file:// bundle that omits it, which
  # is what reddened install-smoke — DIVE-938). This mirrors the team-templates
  # staging below. The file is inert unless the session model is Fable (DIVE-899).
  if curl -fsSL "$REPO/model-tiering-CLAUDE.md" -o "$LIB_DIR/model-tiering-CLAUDE.md"; then
    chmod 644 "$LIB_DIR/model-tiering-CLAUDE.md"
    ok "model-tiering-CLAUDE.md"
  else
    echo "warn: failed to stage model-tiering-CLAUDE.md — Fable model-tiering default won't apply until the next refresh" >&2
  fi

  # Curated team templates for `5dive team import <slug>` (the compose engine
  # resolves $LIB_DIR/team-templates first). Enumerated explicitly because $REPO
  # is a flat fetch URL with no directory listing — add a line per new template.
  mkdir -p "$LIB_DIR/team-templates"
  for _tpl in startup.5dive.yaml content-studio.5dive.yaml eng-studio.5dive.yaml SCHEMA-v2.md; do
    if curl -fsSL "$REPO/team-templates/$_tpl" -o "$LIB_DIR/team-templates/$_tpl"; then
      chmod 644 "$LIB_DIR/team-templates/$_tpl"
    else
      echo "warn: failed to stage team-template $_tpl — 5dive team import $_tpl won't be available until the next refresh" >&2
    fi
  done
  ok "team-templates"

  # /etc/claude-code/managed-settings.json — channel-plugin allowlist.
  # Claude reads a default Anthropic-blessed ledger when this file is
  # absent, which permits telegram@claude-plugins-official but NOT our
  # fork. The moment a custom allowlist exists, claude ignores the
  # default ledger entirely — so we list BOTH the 5dive fork and the
  # upstream entry, plus discord upstream. Existing agents pinned to
  # claude-plugins-official keep working; new agents on 5dive-plugins
  # are now allowlisted. Use install -m to preserve the file mode and
  # never clobber a customised entry: skip if the operator already
  # wrote one (e.g. with extra plugins of their own).
  # channelsEnabled: claude code 2.1.150+ requires this flag for any
  # allowedChannelPlugins entry to actually take effect. Without it,
  # the allowlist is silently inert and inbound channel messages
  # don't reach the session.
  # requiredMinimumVersion (DIVE-133): a known-good CC floor. CC 2.1.163+ refuses
  # to start below it; older CC ignores the key, so it can never brick a box.
  # Pure downgrade guardrail (botched rollback / accidental pin-back) — every box
  # runs latest >= floor. NO requiredMaximumVersion: our installer chases latest
  # (apps.sh + nightly soft-updates.sh), so a ceiling would brick boxes once
  # upstream passes it, not hold them at a version. Release-safety from a bad
  # upstream CC belongs in installer-pinning, not a managed-settings ceiling.
  install -d -m 755 /etc/claude-code
  if [[ ! -f /etc/claude-code/managed-settings.json ]]; then
    cat > /etc/claude-code/managed-settings.json <<'MANAGED'
{
  "channelsEnabled": true,
  "requiredMinimumVersion": "2.1.163",
  "allowedChannelPlugins": [
    {"plugin": "telegram", "marketplace": "5dive-plugins"},
    {"plugin": "telegram", "marketplace": "claude-plugins-official"},
    {"plugin": "discord", "marketplace": "claude-plugins-official"}
  ]
}
MANAGED
    chmod 644 /etc/claude-code/managed-settings.json
    ok "/etc/claude-code/managed-settings.json (new)"
  else
    ok "/etc/claude-code/managed-settings.json (kept existing)"
  fi

  # Drop a slim projects-level CLAUDE.md so every agent spawned on this host
  # picks up baseline self-management guidance (project layout, sudo, where
  # the agent's own settings live, the host CLI). Only on first install —
  # never clobber a customised file. Symlink AGENTS.md so non-claude agent
  # types (codex, …) see the same instructions.
  install -d -m 755 -o claude -g claude /home/claude/projects
  if [[ ! -f /home/claude/projects/CLAUDE.md ]]; then
    curl -fsSL "$REPO/projects-CLAUDE.md" -o /home/claude/projects/CLAUDE.md
    chown claude:claude /home/claude/projects/CLAUDE.md
    chmod 644 /home/claude/projects/CLAUDE.md
    ok "projects/CLAUDE.md"
  else
    ok "projects/CLAUDE.md (kept existing)"
  fi
  if [[ ! -e /home/claude/projects/AGENTS.md ]]; then
    ln -sfn CLAUDE.md /home/claude/projects/AGENTS.md
    chown -h claude:claude /home/claude/projects/AGENTS.md
  fi
}

# --- Subcommand dispatch ---------------------------------------------------

if [[ "${1:-}" == "--uninstall" ]]; then
  shift
  PURGE=0
  YES=0
  for a in "$@"; do
    case "$a" in
      --purge) PURGE=1 ;;
      --yes|-y) YES=1 ;;
      *) die "unknown uninstall flag: $a" ;;
    esac
  done

  say "Uninstalling 5dive CLI"

  # 1. Stop + remove any running agents — leaves /var/lib/5dive/agents.json
  # consistent so an --upgrade reinstall could restore the registry. With
  # --purge we wipe everything anyway.
  if command -v 5dive >/dev/null 2>&1; then
    if [[ -f "$STATE_DIR/agents.json" ]]; then
      mapfile -t AGENT_NAMES < <(jq -r '.agents | keys[]?' "$STATE_DIR/agents.json" 2>/dev/null || true)
      if [[ ${#AGENT_NAMES[@]} -gt 0 ]]; then
        say "Stopping ${#AGENT_NAMES[@]} agent(s)"
        if [[ $YES -eq 0 ]]; then
          printf "    %s\n" "${AGENT_NAMES[@]}"
          read -r -p "  remove these agents? [y/N] " ans
          [[ "$ans" =~ ^[yY] ]] || die "aborted"
        fi
        for n in "${AGENT_NAMES[@]}"; do
          5dive agent rm "$n" >/dev/null 2>&1 || true
          ok "removed agent $n"
        done
      fi
    fi
  fi

  # 2. systemd units + reload
  if [[ -f "$SYSTEMD_DIR/5dive-hermes-perms.path" ]]; then
    systemctl disable --now 5dive-hermes-perms.path >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/5dive-hermes-perms.path" "$SYSTEMD_DIR/5dive-hermes-perms.service"
    ok "removed hermes-perms units"
  fi
  if [[ -f "$SYSTEMD_DIR/5dive-agent@.service" ]]; then
    rm -f "$SYSTEMD_DIR/5dive-agent@.service"
    ok "removed systemd template"
  fi
  systemctl daemon-reload || true

  # 3. Binaries + shared libs
  rm -f "$BIN_DIR/5dive" "$BIN_DIR/5dive-agent-start"
  ok "removed CLI binaries"
  if [[ -d "$LIB_DIR" ]]; then
    rm -rf "$LIB_DIR"
    ok "removed $LIB_DIR (hooks, skills, ui)"
  fi

  # 4. State / connector / claude user — keep by default; --purge wipes.
  if [[ $PURGE -eq 1 ]]; then
    if [[ $YES -eq 0 ]]; then
      echo
      echo "  --purge will permanently delete:"
      [[ -d "$STATE_DIR" ]] && echo "    $STATE_DIR (registry, auth profiles, audit log)"
      [[ -d "$CONNECTORS_DIR" ]] && echo "    $CONNECTORS_DIR (telegram/discord bot tokens)"
      id -u claude >/dev/null 2>&1 && echo "    user 'claude' and /home/claude"
      read -r -p "  continue? [y/N] " ans
      [[ "$ans" =~ ^[yY] ]] || die "aborted"
    fi
    rm -rf "$STATE_DIR" "$CONNECTORS_DIR"
    ok "removed state + connector dirs"
    if id -u claude >/dev/null 2>&1; then
      userdel -r claude 2>/dev/null || userdel claude 2>/dev/null || true
      ok "removed user 'claude'"
    fi
    getent group claude >/dev/null 2>&1 && groupdel claude 2>/dev/null && ok "removed group 'claude'" || true
  else
    echo
    say "kept (run again with --purge to remove):"
    [[ -d "$STATE_DIR" ]] && echo "    $STATE_DIR"
    [[ -d "$CONNECTORS_DIR" ]] && echo "    $CONNECTORS_DIR"
    id -u claude >/dev/null 2>&1 && echo "    user 'claude'"
  fi

  echo
  echo "5dive uninstalled."
  exit 0
fi

if [[ "${1:-}" == "--upgrade" ]]; then
  shift
  # --no-ui used to gate the (since-removed) local dashboard install; the flag
  # was dropped in 8932961 but smoke harnesses and operator scripts still pass
  # it. Swallow it here as a deprecated no-op rather than break callers.
  [[ "${1:-}" == "--no-ui" ]] && shift
  [[ $# -eq 0 ]] || die "--upgrade takes no extra flags"

  [[ -x "$BIN_DIR/5dive" ]] || die "no existing 5dive at $BIN_DIR/5dive — run install without --upgrade first"

  say "Upgrading 5dive CLI (skipping apt / nvm / bun / state setup)"
  refresh_managed_files

  # Plugins are SHA-pinned per-user in installed_plugins.json, so CLI
  # upgrade alone doesn't refresh them. Run the helper best-effort: if
  # no agents are registered yet (fresh box) it's a no-op; if claude
  # is missing it self-skips. Failures here shouldn't block the upgrade.
  if [[ -x "$BIN_DIR/5dive-refresh-plugins.sh" ]]; then
    "$BIN_DIR/5dive-refresh-plugins.sh" 2>&1 | tail -20 || true
  fi

  # Backfill default skills onto existing agents (e.g. openagent, DIVE-658).
  # Same best-effort contract: no-op on a fresh box, self-skips never-booted
  # agents, failures don't block the upgrade.
  if [[ -x "$BIN_DIR/5dive-refresh-skills.sh" ]]; then
    "$BIN_DIR/5dive-refresh-skills.sh" 2>&1 | tail -20 || true
  fi

  # DIVE-758: turn gate-proof enforcement ON as boxes adopt the tamper-evidence
  # build. Once enforced, an UNPROVEN agent-path answer to an approval/secret gate
  # is rejected (human taps via --human always clear, the dashboard doesn't answer
  # gates), so "X approved gate Y" can't be self-cleared by an agent. Idempotent +
  # best-effort: never block an upgrade on it.
  "$BIN_DIR/5dive" gate-proof enforce on >/dev/null 2>&1 || true

  echo
  echo "5dive upgraded."
  exit 0
fi

# --- Install (default) -----------------------------------------------------

say "Installing 5dive CLI"

# System dependencies. Skip apt entirely if every package is already
# installed — both speeds up reruns and avoids apt-lock contention when
# unattended-upgrades is running concurrently (common on freshly-provisioned
# boxes).
say "Installing system dependencies"
APT_PKGS="jq tmux git curl python3-yaml unzip sqlite3"
apt_need=0
for p in $APT_PKGS; do
  dpkg -s "$p" >/dev/null 2>&1 || { apt_need=1; break; }
done
if (( apt_need )); then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PKGS
  ok "$APT_PKGS"
else
  ok "$APT_PKGS already present"
fi

# Create claude group + user (agents run as agent-<name> in the claude group)
if ! getent group claude >/dev/null 2>&1; then
  groupadd --system claude
  ok "group 'claude' created"
fi
if ! id -u claude >/dev/null 2>&1; then
  useradd --system --gid claude --shell /bin/bash --create-home --home-dir /home/claude claude
  ok "user 'claude' created"
fi

# nvm + node (needed for codex agent type)
say "Installing nvm + Node.js"
if [[ ! -f /home/claude/.nvm/nvm.sh ]]; then
  sudo -u claude bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash'
  ok "nvm installed"
fi
# Write nvm init to .bash_profile so `bash -lc` commands (used by the CLI) find
# node/npm. Guarded so reruns don't accumulate duplicate blocks.
if ! sudo -u claude grep -q 'NVM_DIR="$HOME/.nvm"' /home/claude/.bash_profile 2>/dev/null; then
  sudo -u claude bash -c 'cat >> /home/claude/.bash_profile <<'"'"'NVM_INIT'"'"'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
NVM_INIT
'
fi
sudo -u claude bash -lc "nvm install $NODE_VERSION && nvm alias default $NODE_VERSION" 2>&1 | grep -E "Downloading|Now using|default" || true
ok "Node.js $NODE_VERSION"

# bun (needed for telegram plugin)
say "Installing bun"
if ! sudo -u claude bash -lc 'command -v bun' >/dev/null 2>&1; then
  sudo -u claude bash -c 'curl -fsSL https://bun.sh/install | bash' 2>/dev/null
  ok "bun installed"
else
  ok "bun already present"
fi

# Create directories
say "Setting up 5dive directories"
# setgid 2750: agent-<name> users (in the claude group) need to traverse the
# tree to read their own *.env, but no one outside the group should see the
# registry. setgid keeps the group on any file written here by the root-only
# CLI (registry rewrites, per-agent envs).
install -d -m 2750 "$STATE_DIR"
install -d -m 2750 "$STATE_DIR/agents.d"
install -d -m 750  "$CONNECTORS_DIR"
chown root:claude "$STATE_DIR" "$STATE_DIR/agents.d" "$CONNECTORS_DIR"
# Pre-create an empty registry so the first `5dive agent create` doesn't race
# the lazy-init path. Mode 640 root:claude — readable by the group, only root
# can write.
if [[ ! -f "$STATE_DIR/agents.json" ]]; then
  echo '{"agents":{}}' > "$STATE_DIR/agents.json"
  chown root:claude "$STATE_DIR/agents.json"
  chmod 640 "$STATE_DIR/agents.json"
fi
ok "directories ready"

# Install / refresh CLI binaries, systemd unit, hooks, and skills.
# preseed_claude_agent references the hooks by absolute path under
# /usr/local/lib/5dive/ and warns at agent-create time if any are missing —
# without them the channel-paired agent will appear to start fine but its
# rate-limit handler / picker-blocking guard / missed-reply auto-relay are
# all silently disabled.
say "Installing CLI binaries, systemd unit, hooks, and skills"
refresh_managed_files

echo
echo "5dive installed successfully."
echo

# Show health state immediately so a fresh user knows whether anything is
# missing (e.g. agent type binaries) before they try to create an agent.
# Fail-soft: doctor itself always exits 0, but `|| true` guards against
# future regressions so a doctor crash never breaks the install.
say "Running health check"
5dive doctor || true

# DIVE-758: secure-by-default — new boxes get gate-proof enforcement ON (same as
# the --upgrade path flips it for existing boxes). Best-effort; never block install.
5dive gate-proof enforce on >/dev/null 2>&1 || true

echo
echo "Next steps:"
echo "  5dive agent list                          # list agents"
echo "  5dive doctor --repair                     # auto-install agent type binaries"
echo "  5dive agent create my-agent --type=claude # create your first agent"
echo
echo "To upgrade later: curl -fsSL $REPO/install.sh | sudo bash -s -- --upgrade"
echo "Docs: https://github.com/$GH_ORG/5dive"
