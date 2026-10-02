# ── DIVE-5396: `5dive pkg install <name>...` — a system package, no raw root ───
#
# lodar 2026-10-02: "It will be confusing for humans if they hire an agent that
# cannot do anything. i want them to be able to install tools too." npm, pip and
# uv tools install into the seat's own ~/.local with no sudo (the tool-env shim
# install.sh writes). A SYSTEM package (ffmpeg, a library) needs root, and the
# only seat with root on a customer box is claude. This verb gives every agent
# that one act and nothing around it:
#   * apt only, from the box's configured repositories (no .deb path, no URL)
#   * package NAMES only: no flags, no version pins, no release selectors
#   * --no-install-recommends, and --no-remove: an install that would remove a
#     package (a conflict) aborts instead
#   * no repository, key, remove, purge or upgrade verb exists here at all
#   * logged to the audit log root-side, under the seat derived from SUDO_UID
#
# Root half: `_pkg_do`, one exact-path NOPASSWD line in every standard seat's
# sudoers (render_standard_sudoers); the names travel NUL-separated on stdin.

# Test seams. Under sudo (root, SUDO_UID set) they are ignored whatever the
# environment carries: env_reset strips them today, and the root half must not
# depend on that staying true.
# $1 stands in for a root euid in the harness; it can only narrow (reset to defaults).
_pkg_trust_env() {
  [[ $EUID -eq 0 || "${1:-}" == 0 ]] || return 0
  [[ -n "${SUDO_UID:-}" ]] || return 0
  PKG_APT_GET=apt-get PKG_APT_CACHE=apt-cache
}
PKG_APT_GET="${PKG_APT_GET:-apt-get}"
PKG_APT_CACHE="${PKG_APT_CACHE:-apt-cache}"
_pkg_trust_env
PKG_MAX=20

# Debian package-name shape (policy 5.6.1), plus a leading-letter-or-digit rule
# that already makes a `-flag` impossible.
_pkg_name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]{1,62}$ ]]; }

_pkg_usage() {
  printf '%s\n' \
    "usage: 5dive pkg install <package>... [--json]   # a system package from the box's apt repositories" \
    "" \
    "  For a command-line tool, prefer your own installs (no sudo):" \
    "    npm i -g <pkg>   pip install <pkg>   uv tool install <pkg>   (into ~/.local)" \
    "  Package names only: no flags, versions, files or URLs. Nothing is ever removed."
}

cmd_pkg() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    install) ;;
    -h|--help|"") _pkg_usage; return 0 ;;
    remove|purge|autoremove|upgrade|dist-upgrade|full-upgrade|update|add-repo|add-key)
      fail "$E_PERMISSION" "pkg only installs; '$sub' is not something an agent can do here (ask the box owner)" ;;
    *) fail "$E_USAGE" "unknown pkg subcommand '$sub' (install)" ;;
  esac
  local -a names=(); local a
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      -*) fail "$E_PERMISSION" "pkg install takes package names only; '$a' is not allowed" ;;
      *) _pkg_name_ok "$a" || fail "$E_VALIDATION" "'${a:0:40}' is not a package name (lowercase letters, digits, + . -; no versions, files or URLs)"
         names+=("$a") ;;
    esac
  done
  (( ${#names[@]} )) || fail "$E_USAGE" "usage: 5dive pkg install <package>..."
  (( ${#names[@]} <= PKG_MAX )) || fail "$E_VALIDATION" "at most $PKG_MAX packages per call"

  # Root runs it in-process; SUDO_UID is sudo's stamp, read only under this guard.
  if [[ $EUID -eq 0 ]]; then
    _pkg_exec "${SUDO_UID:-0}" "${names[@]}"
    return
  fi
  local mode=text rc=0
  (( ${JSON_MODE:-0} )) && mode=json
  printf '%s\0' "$mode" install "${names[@]}" | sudo -n /usr/local/bin/5dive _pkg_do || rc=$?
  (( rc == 0 )) || mark_reported
  exit "$rc"
}

# Root half. Reached ONLY through the exact-path NOPASSWD grant (or by root).
cmd_pkg_delegated() {
  _gate_is_root || fail "$E_PERMISSION" "_pkg_do is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant)."
  [[ $# -eq 0 ]] || fail "$E_USAGE" "_pkg_do takes no arguments (the packages are read from stdin)."
  local -a wire=(); local a
  while IFS= read -r -d '' a; do wire+=("$a"); done
  (( ${#wire[@]} >= 3 )) || fail "$E_VALIDATION" "_pkg_do requires an output mode, 'install' and at least one package on stdin."
  case "${wire[0]}" in json) JSON_MODE=1 ;; text) JSON_MODE=0 ;; *) fail "$E_VALIDATION" "_pkg_do output mode must be json or text." ;; esac
  [[ "${wire[1]}" == install ]] || fail "$E_PERMISSION" "_pkg_do allows only install."
  (( ${#wire[@]} - 2 <= PKG_MAX )) || fail "$E_VALIDATION" "at most $PKG_MAX packages per call"
  for a in "${wire[@]:2}"; do
    _pkg_name_ok "$a" || fail "$E_VALIDATION" "'${a:0:40}' is not a package name"
  done
  _pkg_exec "${SUDO_UID:-0}" "${wire[@]:2}"
}

# _pkg_exact <name> — a package in the box's lists is named exactly <name>.
# apt-get reads a name it cannot find exactly as a REGEX ('x11-.+' simulates 708
# new packages), so only an exact name ever reaches it. pkgnames matches a
# PREFIX, hence the whole-line grep; captured first so pipefail cannot see a
# SIGPIPE from an early grep exit.
_pkg_exact() {
  local all; all=$("$PKG_APT_CACHE" pkgnames -- "$1" 2>/dev/null) || true
  grep -qxF -- "$1" <<<"$all"
}
# _pkg_unknown <name>... — prints the names that are not exact packages.
_pkg_unknown() { local n; for n in "$@"; do _pkg_exact "$n" || printf '%s ' "$n"; done; }

# _pkg_exec <caller uid> <name>... — runs as root.
_pkg_exec() {
  _pkg_trust_env
  local uid="$1"; shift
  local by="root"
  if [[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]]; then
    by=$(_gate_uid_to_agent "$uid")
    [[ -n "$by" ]] || by=$(getent passwd "$uid" | cut -d: -f1)
    [[ -n "$by" ]] || fail "$E_AUTH_REQUIRED" "pkg: caller uid ${uid} is not a user on this box"
  fi
  # Non-interactive, and never restart services mid-install (needrestart would
  # otherwise bounce agent units, including the caller's own).
  local -a env=(DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l)
  local -a opts=(-y -q --no-install-recommends --no-remove -o DPkg::Lock::Timeout=300
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  local out rc=0 updated=0 miss
  # Every name must be an exact package BEFORE apt-get sees it. A miss may be a
  # stale list on a box that has not updated lately: refresh once, then ask again.
  miss=$(_pkg_unknown "$@")
  if [[ -n "$miss" ]]; then
    env "${env[@]}" "$PKG_APT_GET" update -q -o DPkg::Lock::Timeout=300 >/dev/null 2>&1 || true
    updated=1; miss=$(_pkg_unknown "$@")
  fi
  if [[ -n "$miss" ]]; then
    audit_log "_pkg_do install" refused "$E_VALIDATION" -- "by=$by" "$@"
    fail "$E_VALIDATION" "no package is named exactly: ${miss% } (check the spelling with apt-cache search; nothing was installed)"
  fi
  out=$(env "${env[@]}" "$PKG_APT_GET" install "${opts[@]}" -- "$@" 2>&1) || rc=$?
  if (( rc != 0 && ! updated )) && grep -qE 'Unable to locate package|has no installation candidate' <<<"$out"; then
    # The lists moved under us: refresh once, and hold the new lists to the
    # same exact-name rule before the second install.
    env "${env[@]}" "$PKG_APT_GET" update -q -o DPkg::Lock::Timeout=300 >/dev/null 2>&1 || true
    miss=$(_pkg_unknown "$@")
    if [[ -n "$miss" ]]; then
      audit_log "_pkg_do install" refused "$E_VALIDATION" -- "by=$by" "$@"
      fail "$E_VALIDATION" "no package is named exactly: ${miss% } (nothing was installed)"
    fi
    rc=0; out=$(env "${env[@]}" "$PKG_APT_GET" install "${opts[@]}" -- "$@" 2>&1) || rc=$?
  fi
  if (( rc != 0 )); then
    audit_log "_pkg_do install" error "$rc" -- "by=$by" "$@"
    local why; why=$(grep -E '^E: ' <<<"$out" | head -3 | tr '\n' ' ') || why=""
    [[ -n "$why" ]] || why=$(tail -3 <<<"$out" | tr '\n' ' ')
    if grep -q 'Packages need to be removed' <<<"$out"; then
      fail "$E_PERMISSION" "installing $* would remove other packages, so nothing was installed (ask the box owner)"
    fi
    fail "$E_GENERIC" "apt could not install $*: ${why% }"
  fi
  audit_log "_pkg_do install" ok 0 -- "by=$by" "$@"
  ok "installed $*" '{installed:$p}' --argjson p "$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
}
