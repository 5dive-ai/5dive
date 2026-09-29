#!/usr/bin/env bash
# DIVE-5201: a seat's ~/.config must be SEAT-owned. `install -d -o seat <leaf>`
# owns the leaf only and leaves every missing parent root-owned, so the co-author
# hook install made ~/.config root:root on every new seat and Chrome (crashpad DB
# under $HOME/.config once DIVE-4587 unset XDG_CONFIG_HOME) died with rc 133.
# `seat_own_dirs` creates the missing parents seat-owned and claims root-owned
# ones (the backfill the upgrade reconciler carries to existing seats).
# Because root runs it inside a tree the live seat owns, arms 8a/8 swap
# ~/.config for a symlink mid-pass (pinned by a FIFO, then as a free race) and
# assert nothing outside the home is ever created, chowned or written.
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

# ── STATIC: the co-author install claims every component, leaf included, BEFORE
# it writes the hook, and never touches the seat's tree by NAME as root ──
body=$(sed -n '/^install_agent_coauthor_hook() {/,/^}/p' src/lib/agent_setup.sh)
own_ln=$(grep -n 'seat_own_dirs "\$user" "\$home" "\.config/5dive/git-hooks" 700' <<<"$body" | cut -d: -f1)
put_ln=$(grep -n 'seat_put_file "\$user" "\$home" "\.config/5dive/git-hooks" prepare-commit-msg 755' <<<"$body" | cut -d: -f1)
[[ -n "$own_ln" && -n "$put_ln" ]] && (( own_ln < put_ln )) \
  && ok_t "install_agent_coauthor_hook claims ~/.config/5dive/git-hooks before it writes the hook" \
  || bad_t "install_agent_coauthor_hook does not claim the dirs first (own=${own_ln:-none} put=${put_ln:-none})"
grep -Eq '^[[:space:]]*(install|mkdir|chown|chmod|cp|mv)[[:space:]]' <<<"$body" \
  && bad_t "install_agent_coauthor_hook still writes into the seat's tree by path as root" \
  || ok_t "install_agent_coauthor_hook has no by-path install/mkdir/chown into the seat's tree"
helper=$(sed -n '/^_seat_tree() {/,/^}/p' src/lib/agent_setup.sh)
grep -q 'O_NOFOLLOW' <<<"$helper" && grep -q 'dir_fd=fd' <<<"$helper" && grep -q 'os.fchown(fd' <<<"$helper" \
  && ok_t "the helper descends by fd (O_NOFOLLOW, dir_fd=, fchown on the held fd)" \
  || bad_t "the helper does not descend by fd"

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

# ── 7. THE LEAF MODE AND THE HOOK FILE ──
h=$(fresh_home leaf)
as_root seat_own_dirs "$SEAT" "$h" .config/5dive/git-hooks 700; rc=$?
is "leaf: seat_own_dirs with a leaf mode succeeds" 0 "$rc"
is "leaf: git-hooks is seat-owned" "$SEAT_UID" "$(owner "$h/.config/5dive/git-hooks")"
is "leaf: git-hooks is 0700" 700 "$(mode "$h/.config/5dive/git-hooks")"
is "leaf: the parents stay 0755" 755 "$(mode "$h/.config/5dive")"
src="$TMP/hook-src"; printf '#!/bin/sh\necho hook\n' >"$src"
$SUDO install -d -m 755 "$TMP/outside-file"; $SUDO bash -c "printf keep >'$TMP/outside-file/f'"
ln -s "$TMP/outside-file/f" "$h/.config/5dive/git-hooks/prepare-commit-msg"
as_root seat_put_file "$SEAT" "$h" .config/5dive/git-hooks prepare-commit-msg 755 "$src"; rc=$?
f="$h/.config/5dive/git-hooks/prepare-commit-msg"
is "put: seat_put_file succeeds" 0 "$rc"
[[ -f "$f" && ! -L "$f" ]] && ok_t "put: a symlink at the hook's name is REPLACED, not written through" || bad_t "put: the hook is not a regular file"
is "put: the hook is seat-owned" "$SEAT_UID" "$(owner "$f")"
is "put: the hook is 0755" 755 "$(mode "$f")"
is "put: the hook has the rendered bytes" "$(cat "$src")" "$(cat "$f")"
is "put: the symlink's root-owned target is untouched" "keep 0" "$(cat "$TMP/outside-file/f") $(owner "$TMP/outside-file/f")"
[[ -z "$(find "$h/.config/5dive/git-hooks" -name '.prepare-commit-msg.5dive.*')" ]] \
  && ok_t "put: no temp file left behind" || bad_t "put: a temp file was left behind"
ln -sfn "$TMP/outside-file" "$h/.config/5dive/linked"
as_root seat_put_file "$SEAT" "$h" .config/5dive/linked prepare-commit-msg 755 "$src"; rc=$?
[[ "$rc" != 0 ]] && ok_t "put: a symlinked directory on the way is refused (rc=$rc)" || bad_t "put: wrote through a symlinked directory"
[[ ! -e "$TMP/outside-file/prepare-commit-msg" ]] && ok_t "put: nothing written into the link's target" || bad_t "put: wrote into the link's target"

# ── 8a. THE SWAP, PINNED (deterministic half of the race): the hook source is a
# FIFO, so root blocks opening it AFTER it has descended to git-hooks. While it
# is parked there the seat renames ~/.config away and plants a symlink to a
# root-owned decoy tree, then feeds the FIFO. A by-name write resolves the
# planted link and lands in the decoy; a write through the held fd lands in the
# real (renamed) directory. No timing luck in either direction. ──
h=$(fresh_home pinned)
pdecoy="$TMP/pdecoy"
$SUDO install -d -m 755 "$pdecoy" "$pdecoy/5dive" "$pdecoy/5dive/git-hooks"
as_root seat_own_dirs "$SEAT" "$h" .config/5dive/git-hooks 700
fifo="$TMP/fifo-src"; mkfifo "$fifo"
pdecoy_before=$($SUDO find "$pdecoy" -printf '%p %U %G %m %s\n' | sort)
timeout 20 bash -c 'exec 3>"$1"; mv -T "$2/.config" "$2/.cfg-real" && ln -s "$3" "$2/.config" \
  && printf "#!/bin/sh\necho pinned\n" >&3' _ "$fifo" "$h" "$pdecoy" &
writer=$!
timeout 20 $SUDO bash -c 'cd "$1"; shift; source src/lib/agent_setup.sh; "$@"' _ "$PWD" \
  seat_put_file "$SEAT" "$h" .config/5dive/git-hooks prepare-commit-msg 755 "$fifo" 2>/dev/null
wait "$writer" 2>/dev/null
[[ -L "$h/.config" && -d "$h/.cfg-real" ]] \
  && ok_t "pinned: the seat's swap happened while root was mid-pass" || bad_t "pinned: the swap did not happen"
is "pinned: the decoy behind the planted symlink is untouched" "$pdecoy_before" \
  "$($SUDO find "$pdecoy" -printf '%p %U %G %m %s\n' | sort)"
is "pinned: the hook landed in the directory root had opened, not the link's target" \
  "$(printf '#!/bin/sh\necho pinned')" "$(cat "$h/.cfg-real/5dive/git-hooks/prepare-commit-msg" 2>/dev/null)"

# ── 8. THE RACE (quinn, iteration 1): the seat owns its home and is live while
# the upgrade reconciler runs as root, so it can rename ~/.config away and plant
# a symlink to a root-only dir BETWEEN two components of one pass. A background
# swap loop, run as the seat, flips ~/.config and ~/.config/5dive between the
# real dir and a symlink into a root-owned decoy tree, while root runs the full
# co-author sequence (dirs + hook file) ROUNDS times. Nothing may be created,
# chowned, chmodded or written anywhere outside the home; the arm also requires
# both outcomes to have occurred, so a race that never landed cannot pass. ──
ROUNDS=${SEAT_OWN_DIRS_RACE_ROUNDS:-400}
h=$(fresh_home race)
decoy="$TMP/decoy"
$SUDO install -d -m 755 "$decoy" "$decoy/5dive" "$decoy/5dive/git-hooks"
$SUDO bash -c "printf decoy >'$decoy/5dive/git-hooks/prepare-commit-msg'"
$SUDO install -d -m 755 "$TMP/marker-dir"; marker="$TMP/marker-dir/m"; $SUDO touch "$marker"
decoy_before=$($SUDO find "$decoy" -printf '%p %U %G %m %s\n' | sort)
stop="$TMP/marker-dir/stop"
(
  cd "$h" || exit 1
  while [[ ! -e "$stop" ]]; do
    mv -T .config .cfg-real 2>/dev/null && ln -s "$decoy" .config 2>/dev/null
    [[ -L .config ]] && rm -f .config
    mv -T .cfg-real .config 2>/dev/null
    if [[ -d .config && ! -L .config ]]; then
      mv -T .config/5dive .config/.5d-real 2>/dev/null && ln -s "$decoy/5dive" .config/5dive 2>/dev/null
      [[ -L .config/5dive ]] && rm -f .config/5dive
      mv -T .config/.5d-real .config/5dive 2>/dev/null
    fi
  done
) &
swapper=$!
counts=$($SUDO bash -c '
  cd "$1"; source src/lib/agent_setup.sh; ok=0 refused=0
  for ((i = 0; i < $5; i++)); do
    if seat_own_dirs "$2" "$3" .config/5dive/git-hooks 700 2>/dev/null \
       && seat_put_file "$2" "$3" .config/5dive/git-hooks prepare-commit-msg 755 "$4" 2>/dev/null; then
      ok=$((ok + 1))
    else
      refused=$((refused + 1))
    fi
  done
  echo "$ok $refused"' _ "$PWD" "$SEAT" "$h" "$src" "$ROUNDS")
$SUDO touch "$stop"; wait "$swapper" 2>/dev/null
read -r race_ok race_refused <<<"$counts"
echo "     race: $ROUNDS rounds, ${race_ok:-?} completed, ${race_refused:-?} refused a swapped component"
(( ${race_ok:-0} > 0 && ${race_refused:-0} > 0 )) \
  && ok_t "race: the swap landed mid-pass (both outcomes seen), so the arm is live" \
  || bad_t "race: the swap never interleaved (ok=${race_ok:-?} refused=${race_refused:-?}) — the arm proved nothing"
is "race: the decoy tree is byte-for-byte, owner-for-owner unchanged" "$decoy_before" \
  "$($SUDO find "$decoy" -printf '%p %U %G %m %s\n' | sort)"
touched=$($SUDO find "$TMP" -path "$h" -prune -o -path "$TMP/marker-dir" -prune -o -path "$TMP" -o -cnewer "$marker" -print)
is "race: no inode outside the seat home changed (create, chown or chmod)" "" "$touched"
# Converges once the seat stops: one clean pass leaves the whole path seat-owned.
as_root seat_own_dirs "$SEAT" "$h" .config/5dive/git-hooks 700 \
  && as_root seat_put_file "$SEAT" "$h" .config/5dive/git-hooks prepare-commit-msg 755 "$src"
is "race: a clean pass afterwards leaves every component and the hook seat-owned" \
  "$SEAT_UID $SEAT_UID $SEAT_UID $SEAT_UID" \
  "$(stat -c %u "$h/.config" "$h/.config/5dive" "$h/.config/5dive/git-hooks" "$h/.config/5dive/git-hooks/prepare-commit-msg" | xargs)"

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
