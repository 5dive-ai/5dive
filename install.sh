#!/usr/bin/env bash
# 5dive CLI installer / uninstaller
# Install:   curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash
# Upgrade:   curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash -s -- --upgrade
# Uninstall: curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash -s -- --uninstall
# Skip UI:   add --no-ui to any of the above (CLI-only, ~5min faster, no bun build)
set -euo pipefail

# Source for binaries / hooks / skills. Overridable for offline installs,
# enterprise mirrors, and pre-publish smoke tests (which point this at a
# `file://` bundle of the working tree).
REPO="${REPO:-https://raw.githubusercontent.com/5dive-com/5dive/main}"
BIN_DIR="/usr/local/bin"
STATE_DIR="/var/lib/5dive"
CONNECTORS_DIR="/etc/5dive/connectors"
SYSTEMD_DIR="/etc/systemd/system"
LIB_DIR="/usr/local/lib/5dive"
UI_DIR="$LIB_DIR/ui"
NODE_VERSION="22"

die() { echo "error: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
say() { echo "→ $*"; }

[[ $EUID -eq 0 ]] || die "run as root: curl -fsSL ... | sudo bash"

# Pre-parse cross-subcommand flags so they can appear anywhere on the line
# (--no-ui works with install, --upgrade, and --uninstall doesn't care). We
# strip them from $@ and re-set so the subcommand dispatch below sees a clean
# arg list.
INSTALL_UI=1
_FILTERED_ARGS=()
for _arg in "$@"; do
  case "$_arg" in
    --no-ui) INSTALL_UI=0 ;;
    *)       _FILTERED_ARGS+=("$_arg") ;;
  esac
done
if (( ${#_FILTERED_ARGS[@]} )); then
  set -- "${_FILTERED_ARGS[@]}"
else
  set --
fi
unset _FILTERED_ARGS _arg

# Refresh CLI binaries, systemd unit, hooks, and skills from $REPO. Shared by
# the default install path and `--upgrade`. Never touches state, auth profiles,
# the claude user, apt packages, nvm, or bun — so it's safe to rerun on a
# populated host.
refresh_managed_files() {
  curl -fsSL "$REPO/5dive" -o "$BIN_DIR/5dive"
  chmod 755 "$BIN_DIR/5dive"
  ok "5dive → $BIN_DIR/5dive"

  curl -fsSL "$REPO/5dive-agent-start" -o "$BIN_DIR/5dive-agent-start"
  chmod 755 "$BIN_DIR/5dive-agent-start"
  ok "5dive-agent-start → $BIN_DIR/5dive-agent-start"

  curl -fsSL "$REPO/systemd/5dive-agent%40.service" -o "$SYSTEMD_DIR/5dive-agent@.service"
  systemctl daemon-reload
  ok "systemd template installed"

  install -d -m 755 "$LIB_DIR" "$LIB_DIR/skills/notify-user"
  for hook in stop-failure-telegram.sh resume-after-reset.sh \
              pretool-telegram-question.sh stop-telegram-reply-check.sh; do
    curl -fsSL "$REPO/hooks/$hook" -o "$LIB_DIR/$hook"
    chmod 755 "$LIB_DIR/$hook"
    ok "$hook"
  done
  curl -fsSL "$REPO/skills/notify-user/SKILL.md" -o "$LIB_DIR/skills/notify-user/SKILL.md"
  chmod 644 "$LIB_DIR/skills/notify-user/SKILL.md"
  ok "notify-user skill"
}

# Derive a UI source URL/path from $REPO unless UI_SOURCE was set explicitly.
# - file:// REPO → "${REPO}/ui" directory (smoke test / offline install path)
# - raw.githubusercontent.com REPO → codeload tarball of the same {owner,repo,ref}
#   (the published one-liner path). We use a tarball instead of fetching every
#   ui/ file by curl because the tree is several hundred files; a tarball is
#   one round-trip and ~200 KB.
# - Anything else → user must set UI_SOURCE explicitly (mirrored install).
derive_ui_source() {
  if [[ -n "${UI_SOURCE:-}" ]]; then
    echo "$UI_SOURCE"
    return
  fi
  if [[ "$REPO" == file://* ]]; then
    echo "${REPO%/}/ui"
    return
  fi
  if [[ "$REPO" =~ ^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/?$ ]]; then
    echo "https://codeload.github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/tar.gz/refs/heads/${BASH_REMATCH[3]}"
    return
  fi
  die "UI install: REPO ($REPO) doesn't match raw.githubusercontent.com pattern; set UI_SOURCE or pass --no-ui"
}

# Drop ui/ at $UI_DIR + `bun install` + `bun run build`. Idempotent: wipes
# $UI_DIR first so reruns aren't fooled by half-stale trees. node_modules and
# dist are excluded on the copy and rebuilt locally so the host bun matches
# the host arch + node version.
install_ui() {
  local src tmp tarball_root local_src
  src="$(derive_ui_source)"

  say "Installing 5dive UI ($src)"
  install -d -m 755 "$LIB_DIR"
  rm -rf "$UI_DIR"

  if [[ "$src" == file://* ]] || [[ "$src" != http* && -d "$src" ]]; then
    local_src="${src#file://}"
    [[ -d "$local_src" ]] || die "UI source dir not found: $local_src"
    install -d -m 755 "$UI_DIR"
    # tar pipe rather than cp -a — excludes node_modules (~300MB) + dist
    # without depending on rsync; everything else is a few hundred files.
    (cd "$local_src" && tar --exclude=./node_modules --exclude=./dist -cf - .) \
      | (cd "$UI_DIR" && tar -xf -)
    ok "ui files copied from $local_src"
  else
    tmp=$(mktemp -d)
    curl -fsSL "$src" -o "$tmp/ui.tgz" \
      || die "failed to download UI source from $src"
    tar -xzf "$tmp/ui.tgz" -C "$tmp"
    # Codeload tarballs unpack to <repo>-<ref>/ ; pluck ui/ from the first
    # top-level dir. If $src was a direct ui/ tarball, it'll already be at
    # $tmp/ui after extract.
    if [[ -d "$tmp/ui" ]]; then
      mv "$tmp/ui" "$UI_DIR"
    else
      tarball_root=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
      if [[ -n "$tarball_root" && -d "$tarball_root/ui" ]]; then
        mv "$tarball_root/ui" "$UI_DIR"
      else
        die "UI tarball at $src didn't contain a ui/ folder"
      fi
    fi
    rm -rf "$tmp"
    ok "ui files extracted from $src"
  fi

  chown -R claude:claude "$UI_DIR"

  # bun.lock is gitignored upstream, so frozen-lockfile would fail on the
  # codeload path. Use a plain install — slightly less reproducible but works
  # whether bun.lock was carried over from a file:// copy or not.
  say "Installing UI dependencies (bun install — ~30s)"
  if ! sudo -u claude bash -lc "cd '$UI_DIR' && bun install 2>&1" >/tmp/5dive-ui-bun.log; then
    tail -20 /tmp/5dive-ui-bun.log >&2
    die "bun install failed in $UI_DIR (full log: /tmp/5dive-ui-bun.log)"
  fi
  ok "ui dependencies installed"

  # Build the production bundle. server.ts serves dist/ when it exists, so
  # without this the UI would 404 on /. Re-runnable; vite is idempotent.
  say "Building UI bundle (vite build — ~20s)"
  if ! sudo -u claude bash -lc "cd '$UI_DIR' && bun run build 2>&1" >/tmp/5dive-ui-build.log; then
    tail -20 /tmp/5dive-ui-build.log >&2
    die "vite build failed in $UI_DIR (full log: /tmp/5dive-ui-build.log)"
  fi
  ok "ui bundle built → $UI_DIR/dist"
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

  # 2. systemd template + reload
  if [[ -f "$SYSTEMD_DIR/5dive-agent@.service" ]]; then
    rm -f "$SYSTEMD_DIR/5dive-agent@.service"
    systemctl daemon-reload || true
    ok "removed systemd template"
  fi

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
  [[ $# -eq 0 ]] || die "--upgrade takes no extra flags (other than --no-ui, which is pre-parsed)"

  [[ -x "$BIN_DIR/5dive" ]] || die "no existing 5dive at $BIN_DIR/5dive — run install without --upgrade first"

  say "Upgrading 5dive CLI (skipping apt / nvm / bun / state setup)"
  refresh_managed_files

  # --upgrade refreshes the UI too unless it was opted out at install time.
  # We can't reliably detect "was UI installed last time" from disk (someone
  # could have rm -rf'd ui/) so the rule is: --no-ui on upgrade skips UI;
  # otherwise refresh. If $UI_DIR doesn't exist this becomes a first-time UI
  # install, which is what someone running `--upgrade` after originally
  # installing with --no-ui would want.
  if (( INSTALL_UI )); then
    install_ui
  else
    say "Skipping UI refresh (--no-ui)"
  fi

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
APT_PKGS="jq tmux git curl python3-yaml unzip"
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

# nvm + node (needed for codex, gemini agent types)
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
install -d -m 755 "$STATE_DIR"
install -d -m 755 "$STATE_DIR/agents.d"
install -d -m 755 "$CONNECTORS_DIR"
chown root:claude "$STATE_DIR" "$STATE_DIR/agents.d" "$CONNECTORS_DIR"
chmod 750 "$CONNECTORS_DIR"
ok "directories ready"

# Install / refresh CLI binaries, systemd unit, hooks, and skills.
# preseed_claude_agent references the hooks by absolute path under
# /usr/local/lib/5dive/ and warns at agent-create time if any are missing —
# without them the channel-paired agent will appear to start fine but its
# rate-limit handler / picker-blocking guard / missed-reply auto-relay are
# all silently disabled.
say "Installing CLI binaries, systemd unit, hooks, and skills"
refresh_managed_files

# Install the local dashboard. Default-on because `5dive ui` is one of the
# marquee features for self-hosters; opt out with --no-ui for headless boxes
# or to shave ~30s + a few hundred MB of node_modules off the install.
# 5dive-api's customer provisioning intentionally never runs this script, so
# managed Hetzner boxes don't get the local UI (those customers use
# app.5dive.com instead).
if (( INSTALL_UI )); then
  install_ui
else
  say "Skipping UI install (--no-ui)"
fi

echo
echo "5dive installed successfully."
echo

# Show health state immediately so a fresh user knows whether anything is
# missing (e.g. agent type binaries) before they try to create an agent.
# Fail-soft: doctor itself always exits 0, but `|| true` guards against
# future regressions so a doctor crash never breaks the install.
say "Running health check"
5dive doctor || true

echo
echo "Next steps:"
echo "  5dive agent list                          # list agents"
echo "  5dive doctor --repair                     # auto-install agent type binaries"
echo "  5dive agent create my-agent --type=claude # create your first agent"
if (( INSTALL_UI )); then
  echo "  5dive ui setup                            # set a password (required for non-loopback bind)"
  echo "  5dive ui                                  # open the local dashboard on http://localhost:5175"
fi
echo
echo "To upgrade later: curl -fsSL $REPO/install.sh | sudo bash -s -- --upgrade"
echo "Docs: https://github.com/5dive-com/5dive"
