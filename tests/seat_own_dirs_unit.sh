#!/usr/bin/env bash
# DIVE-5201: a seat's ~/.config must be SEAT-owned. `install -d -o seat <leaf>`
# owns the leaf only and leaves every missing parent root-owned, so the co-author
# hook install made ~/.config root:root on every new seat and Chrome (crashpad DB
# under $HOME/.config once DIVE-4587 unset XDG_CONFIG_HOME) died with rc 133.
# `seat_own_dirs` creates the missing parents seat-owned and claims root-owned
# ones (the backfill the upgrade reconciler carries to existing seats).
#
# The ownership arms need root: chown to another uid is the property. Without
# root or `sudo -n` they SKIP loudly rather than pass on a no-op.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; ${SUDO:-} rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
is() { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1 (want=$2 got=$3)"; }

# ── STATIC: the co-author install claims the parents BEFORE it makes the leaf ──
body=$(sed -n '/^install_agent_coauthor_hook() {/,/^}/p' src/lib/agent_setup.sh)
own_ln=$(grep -n 'seat_own_dirs "\$user" "\$home" "\.config/5dive"' <<<"$body" | cut -d: -f1)
leaf_ln=$(grep -n 'install -d -m 700 -o "\$user" -g "\$user" "\$hooks"' <<<"$body" | cut -d: -f1)
[[ -n "$own_ln" && -n "$leaf_ln" ]] && (( own_ln < leaf_ln )) \
  && ok_t "install_agent_coauthor_hook claims ~/.config and ~/.config/5dive before the hooks leaf" \
  || bad_t "install_agent_coauthor_hook does not claim the parents first (own=${own_ln:-none} leaf=${leaf_ln:-none})"

SUDO="" CAN_ROOT=1
if (( EUID != 0 )); then
  sudo -n true 2>/dev/null && SUDO="sudo -n" || CAN_ROOT=0
fi
# The seat stand-in: the invoking user, whose same-named group the helper's
# `user:user` chown needs. Root itself cannot stand in (root-owned IS the bug).
SEAT="${SUDO_USER:-$(id -un)}"
if (( ! CAN_ROOT )) || [[ "$SEAT" == root ]] || ! getent group "$SEAT" >/dev/null; then
  echo "skip ownership arms (need root or sudo -n, and a non-root user with a same-named group)"
  echo "RESULT: $PASS passed, $FAIL failed"
  (( FAIL == 0 ))
  exit
fi

TMP=$(mktemp -d /tmp/seat-own-dirs.XXXXXX)
chmod 755 "$TMP"
SEAT_UID=$(id -u "$SEAT")
as_root() { $SUDO bash -c 'cd "$1"; shift; source src/lib/agent_setup.sh; "$@"' _ "$PWD" "$@"; }
owner() { stat -c %u "$1"; }
mode() { stat -c %a "$1"; }

# The seat owns its home, as `agent create` leaves it.
fresh_home() { local h="$TMP/$1"; mkdir -p "$h"; printf '%s' "$h"; }

# ── 1. THE CAUSE, MEASURED: the pre-fix call leaves ~/.config root-owned ──
h=$(fresh_home prefix)
$SUDO install -d -m 700 -o "$SEAT" -g "$SEAT" "$h/.config/5dive/git-hooks"
is "control: install -d -o on the leaf alone leaves ~/.config root-owned" 0 "$(owner "$h/.config")"
is "control: ... and ~/.config/5dive root-owned" 0 "$(owner "$h/.config/5dive")"

# ── 2. A FRESH HOME: every component is created seat-owned ──
h=$(fresh_home fresh)
as_root seat_own_dirs "$SEAT" "$h" .config/5dive; rc=$?
is "fresh home: seat_own_dirs succeeds" 0 "$rc"
is "fresh home: ~/.config is seat-owned" "$SEAT_UID" "$(owner "$h/.config")"
is "fresh home: ~/.config/5dive is seat-owned" "$SEAT_UID" "$(owner "$h/.config/5dive")"
is "fresh home: ~/.config keeps the 0755 it always had" 755 "$(mode "$h/.config")"
$SUDO install -d -m 700 -o "$SEAT" -g "$SEAT" "$h/.config/5dive/git-hooks"
mkdir -p "$h/.config/google-chrome/Crash Reports" 2>/dev/null \
  && ok_t "fresh home: the seat can create Chrome's crashpad dir under ~/.config" \
  || bad_t "fresh home: the seat cannot create ~/.config/google-chrome"

# ── 3. THE BACKFILL: an existing root-owned ~/.config is claimed, NON-recursively ──
h=$(fresh_home backfill)
$SUDO install -d -m 700 -o "$SEAT" -g "$SEAT" "$h/.config/5dive/git-hooks"
$SUDO install -d -m 700 "$h/.config/rootonly"
$SUDO chmod 750 "$h/.config"
as_root seat_own_dirs "$SEAT" "$h" .config/5dive; rc=$?
is "backfill: seat_own_dirs succeeds on a root-owned ~/.config" 0 "$rc"
is "backfill: ~/.config is now seat-owned" "$SEAT_UID" "$(owner "$h/.config")"
is "backfill: ~/.config/5dive is now seat-owned" "$SEAT_UID" "$(owner "$h/.config/5dive")"
is "backfill: the mode is untouched (chown only)" 750 "$(mode "$h/.config")"
is "backfill: a root-owned sibling is NOT chowned (non-recursive)" 0 "$(owner "$h/.config/rootonly")"
is "backfill: the seat-owned leaf keeps its 0700" 700 "$(mode "$h/.config/5dive/git-hooks")"

# ── 4. IDEMPOTENT: a second pass changes nothing ──
before=$(stat -c '%u %a %Y' "$h/.config" "$h/.config/5dive")
as_root seat_own_dirs "$SEAT" "$h" .config/5dive; rc=$?
is "idempotent: second pass succeeds" 0 "$rc"
is "idempotent: owner/mode/mtime unchanged" "$before" "$(stat -c '%u %a %Y' "$h/.config" "$h/.config/5dive")"

# ── 5. A SYMLINKED COMPONENT IS REFUSED, and its target is never chowned ──
h=$(fresh_home link)
tgt="$TMP/elsewhere"; $SUDO install -d -m 755 "$tgt"
ln -s "$tgt" "$h/.config"
as_root seat_own_dirs "$SEAT" "$h" .config/5dive; rc=$?
[[ "$rc" != 0 ]] && ok_t "symlink: a symlinked ~/.config is refused (rc=$rc)" || bad_t "symlink: a symlinked ~/.config was accepted"
is "symlink: the link's root-owned target is NOT chowned" 0 "$(owner "$tgt")"
[[ ! -e "$tgt/5dive" ]] && ok_t "symlink: nothing was created through the link" || bad_t "symlink: created $tgt/5dive through the link"

# ── 6. A NON-DIRECTORY COMPONENT AND A `..` PATH ARE REFUSED ──
h=$(fresh_home file)
: >"$h/.config"
as_root seat_own_dirs "$SEAT" "$h" .config/5dive; rc=$?
[[ "$rc" != 0 ]] && ok_t "file: a regular-file ~/.config is refused (rc=$rc)" || bad_t "file: a regular-file ~/.config was accepted"
h=$(fresh_home dotdot)
as_root seat_own_dirs "$SEAT" "$h" ../escape; rc=$?
[[ "$rc" != 0 ]] && ok_t "dotdot: a '..' component is refused (rc=$rc)" || bad_t "dotdot: a '..' component was accepted"
[[ ! -e "$TMP/escape" ]] && ok_t "dotdot: nothing was created outside the home" || bad_t "dotdot: created $TMP/escape"

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
