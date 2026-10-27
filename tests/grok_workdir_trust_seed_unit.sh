#!/usr/bin/env bash
# TIER: core — pure bash + awk + stubs, no tmux, no agent, no network (<1s measured).
# DIVE-7083 unit: grok's workdir folder-trust seed and the boot-time trust-prompt
# watch in `5dive-agent-start`.
#
# The defect: grok >= 1.0 asks "Do you trust the contents of this directory?" at
# startup in any folder carrying trust-gated content (AGENTS.md, CLAUDE.md,
# .claude/), and --always-approve does not answer it. A Grok hire parked on that
# dialog on a live self-hosted box (grok 1.0.70, 2026-10-27) and the owner's
# first message was lost. The store is ~/.grok/trusted_folders.toml.
#
# Runs the REAL block, extracted from the real script by its exact guard line,
# against a fake $HOME. Pure: no root, no network, no grok binary.
# Optional live arm: GROK_BIN=<grok >= 1.0 binary> also asks grok itself
# (`grok inspect` → "Project trusted:") before and after the seed.
#   bash tests/grok_workdir_trust_seed_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
START=bin/5dive-agent-start
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grok-trust-seed-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-3247: one EXIT trap carries both the cleanup and HARNESS-RC.

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }

MARKER='if [[ "$TYPE" == "grok" && -n "${WORKDIR:-}" ]]; then'

# --- non-vacuity, first ------------------------------------------------------
extract() { awk -v m="$MARKER" '$0 == m {on=1} on {print} on && $0 == "fi" {exit}' "$1"; }
BLOCK="$(extract "$START")"
check "marker present in $START exactly once" "$(grep -cFx "$MARKER" "$START")" "1"
check "extracted block is non-empty and closed" \
  "$([[ -n "$BLOCK" && "$(tail -1 <<<"$BLOCK")" == "fi" ]] && echo yes || echo no)" "yes"
check "extracted block writes grok's trust store" \
  "$(grep -q 'trusted_folders.toml' <<<"$BLOCK" && echo yes || echo no)" "yes"

WD="$TMP/projects/agent-wd"; mkdir -p "$WD"
OTHER="$TMP/projects/other"; mkdir -p "$OTHER"
hdr() { printf '[folders."%s"]' "$1"; }

# run <case> <TYPE> <workdir> [initial-store|__none__] [block] -> echoes the fake $HOME
run() {
  local case="$1" type="$2" wd="$3" initial="${4:-__none__}" blk="${5:-$BLOCK}"
  local home="$TMP/$case"
  mkdir -p "$home"
  if [[ "$initial" != "__none__" ]]; then
    mkdir -p "$home/.grok"; printf '%s' "$initial" > "$home/.grok/trusted_folders.toml"
  fi
  (
    set -euo pipefail   # the real script runs under set -e: a seed failure must never abort the launch
    HOME="$home"; NAME="probe"; TYPE="$type"; WORKDIR="$wd"
    eval "$blk"
  ) 2>"$home/.stderr"
  echo "$?" > "$home/.rc"
  printf '%s' "$home"
}
store() { cat "$1/.grok/trusted_folders.toml" 2>/dev/null; }
# trusted <home> <dir>: "true"/"false"/"absent" for that folder's table
trusted() {
  awk -v h="$(hdr "$2")" '
    $0 == h { on = 1; seen = 1; next }
    on && /^\[/ { on = 0 }
    on && /^trusted *= */ { v = $3 }
    END { print (seen ? (v == "" ? "absent" : v) : "absent") }' "$1/.grok/trusted_folders.toml" 2>/dev/null
}
tables_for() { grep -cFx "$(hdr "$2")" "$1/.grok/trusted_folders.toml" 2>/dev/null; }

# --- 1. the reported case: no store at all ----------------------------------
H=$(run fresh grok "$WD")
check "fresh: workdir is TRUSTED"            "$(trusted "$H" "$WD")" "true"
check "fresh: exactly one table for it"      "$(tables_for "$H" "$WD")" "1"
check "fresh: decided_at is stamped"         "$(store "$H" | grep -cE '^decided_at = [0-9]+$')" "1"
check "fresh: store is mode 600"             "$(stat -c '%a' "$H/.grok/trusted_folders.toml")" "600"
check "fresh: ~/.grok is mode 700"           "$(stat -c '%a' "$H/.grok")" "700"
check "fresh: exits 0 under set -e"          "$(cat "$H/.rc")" "0"
check "fresh: announces the seed"            "$(grep -c "trusted workdir $WD" "$H/.stderr")" "1"

# --- 2. grok's own decisions for other folders survive -----------------------
OTHERS="$(hdr "$OTHER")
trusted = true
decided_at = 1793086967
"
H=$(run merge grok "$WD" "$OTHERS")
check "merge: workdir is TRUSTED"            "$(trusted "$H" "$WD")" "true"
check "merge: the other folder survives"     "$(trusted "$H" "$OTHER")" "true"
check "merge: its decided_at survives"       "$(store "$H" | grep -c '^decided_at = 1793086967$')" "1"

# --- 3. a "No" left at the dialog is overturned, never duplicated ------------
DENIED="$(hdr "$WD")
trusted = false
decided_at = 1
$OTHERS"
H=$(run denied grok "$WD" "$DENIED")
check "denied: workdir is now TRUSTED"       "$(trusted "$H" "$WD")" "true"
check "denied: still ONE table (a duplicate TOML table breaks the whole store)" "$(tables_for "$H" "$WD")" "1"
check "denied: the other folder survives"    "$(trusted "$H" "$OTHER")" "true"
check "denied: the old decided_at is gone"   "$(store "$H" | grep -c '^decided_at = 1$')" "0"

# --- 4. already trusted: byte-for-byte untouched ------------------------------
OK="$(hdr "$WD")
trusted = true
decided_at = 1793000000
"
H=$(run already grok "$WD" "$OK")
check "already trusted: store is untouched"  "$([[ "$(store "$H")" == "${OK%$'\n'}" ]] && echo same || echo changed)" "same"
check "already trusted: says so"             "$(grep -c 'already trusted' "$H/.stderr")" "1"

# --- 5. idempotent across restarts ------------------------------------------
H=$(run twice grok "$WD")
( set -euo pipefail; HOME="$H"; NAME=probe; TYPE=grok; WORKDIR="$WD"; eval "$BLOCK" ) 2>/dev/null
check "two boots: still one table"           "$(tables_for "$H" "$WD")" "1"

# --- 6. symlinked workdir: the CANONICAL path is what grok matches -----------
ln -s "$WD" "$TMP/wd-link"
H=$(run symlink grok "$TMP/wd-link")
check "symlink: canonical path is TRUSTED"   "$(trusted "$H" "$WD")" "true"
check "symlink: link spelling is not keyed"  "$(trusted "$H" "$TMP/wd-link")" "absent"

# --- 7. other forks are not touched ------------------------------------------
H=$(run claude claude "$WD")
check "claude agent: no grok store written"  "$([[ -e "$H/.grok/trusted_folders.toml" ]] && echo written || echo none)" "none"

# --- 8. a home the seed cannot write never stops the launch -----------------
# The HOME itself, not ~/.grok: the agent owns ~/.grok, so `install -d -m 700`
# just re-modes a read-only one, which is the right outcome and no fixture.
mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
if [[ -w "$TMP/ro" ]]; then
  echo "skip: unwritable home (running as root, mode bits do not bind)"
else
  ( set -euo pipefail; HOME="$TMP/ro"; NAME=probe; TYPE=grok; WORKDIR="$WD"; eval "$BLOCK" ) 2>"$TMP/ro.stderr"
  check "unwritable: exits 0 under set -e"   "$?" "0"
  check "unwritable: says WARN"              "$(grep -c 'WARN' "$TMP/ro.stderr")" "1"
fi
chmod 700 "$TMP/ro"

# --- 9. the trust-prompt watch (stubbed tmux) ---------------------------------
WATCH="$(sed -n '/^TRUST_PROMPT_RE=/p; /^trust_prompt_breadcrumb_path()/p; /^trust_prompt_watch()/,/^}/p' "$START" \
  | sed 's#/usr/bin/tmux#tmux#g')"
check "watch: extracted with its pattern and function" \
  "$(grep -c 'TRUST_PROMPT_RE=\|^trust_prompt_watch()' <<<"$WATCH")" "2"
check "watch: launched for every fork at boot" \
  "$(grep -cFx '( trust_prompt_watch "$SESSION" "$TYPE" || true ) &' "$START")" "1"
# watch <case> <type> <pane-file...>: each tick reads the next pane file (the last repeats)
watch() {
  local case="$1" type="$2"; shift 2
  local d="$TMP/w-$case"; mkdir -p "$d"
  printf '%s\n' "$@" > "$d/panes"
  (
    HOME="$d"; TRUST_PROMPT_WATCH_TICKS=3; TRUST_PROMPT_WATCH_SLEEP=0
    tmux() {
      case "$1" in
        capture-pane) local n; n=$(cat "$d/n" 2>/dev/null || echo 1)
                      cat "$(sed -n "${n}p" "$d/panes")" 2>/dev/null || cat "$(tail -1 "$d/panes")"
                      echo $((n + 1)) > "$d/n" ;;
        send-keys)    shift; echo "$*" >> "$d/keys" ;;
      esac
    }
    eval "$WATCH"
    trust_prompt_watch S "$type"; echo "$?" > "$d/rc"
  ) 2>"$d/stderr"
  printf '%s' "$d"
}
P="$TMP/panes"; mkdir -p "$P"
printf 'Do you trust the contents of this directory?\ny  Yes, proceed\n' > "$P/grok-dialog"
printf '  New worktree\n  Resume session\n  Quit\n' > "$P/grok-launcher"
printf 'Do you trust the files in this folder?\n' > "$P/claude-dialog"
printf '> ready\n' > "$P/clean"

D=$(watch grok-answered grok "$P/grok-dialog" "$P/grok-launcher")
check "watch grok: answers its dialog with y, once" "$(cat "$D/keys" 2>/dev/null)" "-t S y"
check "watch grok: cleared, so no breadcrumb"       "$([[ -e "$D/.5dive-trust-prompt-parked" ]] && echo yes || echo no)" "no"
check "watch grok: rc 0"                            "$(cat "$D/rc")" "0"

D=$(watch claude-parked claude "$P/claude-dialog")
check "watch parked: breadcrumb names the stall"    "$(grep -c 'PARKED on a folder-trust prompt' "$D/.5dive-trust-prompt-parked" 2>/dev/null)" "1"
check "watch parked: journal WARN"                  "$(grep -c 'PARKED on a folder-trust prompt' "$D/stderr")" "1"
check "watch parked: never types into claude's dialog" "$([[ -e "$D/keys" ]] && echo typed || echo none)" "none"
check "watch parked: rc 1"                          "$(cat "$D/rc")" "1"

D=$(watch clean codex "$P/clean")
touch "$D/.5dive-trust-prompt-parked"   # stale from an earlier boot …
D=$(watch clean codex "$P/clean")       # … is cleared by a clean one
check "watch clean: stale breadcrumb cleared"       "$([[ -e "$D/.5dive-trust-prompt-parked" ]] && echo yes || echo no)" "no"

# --- 10. mutations: each must go RED ------------------------------------------
mut_red() { # <label> <mutant> <case> <initial> <dir> <want-trusted>
  local h; h=$(run "$3" grok "$WD" "$4" "$2")
  check "mutant really differs: $1" "$([[ "$2" != "$BLOCK" ]] && echo differs || echo identical)" "differs"
  check "mutant parses: $1" "$(bash -n <(printf '%s\n' "$2") 2>/dev/null && echo parses || echo broken)" "parses"
  if [[ "$(trusted "$h" "$5")" == "$6" && "$(tables_for "$h" "$5")" == "1" ]]; then
    echo "FAIL: mutant stayed green: $1"; fail=1
  else
    echo "ok: mutant goes red: $1"
  fi
}
M1="${BLOCK//_gtr_dir=\$(cd \"\$WORKDIR\" 2>\/dev\/null \&\& pwd -P) || _gtr_dir=\"\"/_gtr_dir=\"\"}"
check "M1 is a real substitution" "$([[ "$M1" != "$BLOCK" ]] && echo yes || echo no)" "yes"
M2="${BLOCK//\$0 == h \{ skip = 1; next \}/}"              # forget to drop the old table
M3="${BLOCK//trusted = true\\n/trusted = false\\n}"          # write the wrong value
# M1 keys the literal (non-canonical) WORKDIR: run through the symlink to see it.
h=$(run m1 grok "$TMP/wd-link" __none__ "$M1")
if [[ "$(trusted "$h" "$WD")" == "true" ]]; then echo "FAIL: mutant stayed green: non-canonical key"; fail=1
else echo "ok: mutant goes red: non-canonical key"; fi
mut_red "old table not dropped (duplicate TOML table)" "$M2" m2 "$DENIED" "$WD" "true"
mut_red "seeds trusted = false"                         "$M3" m3 __none__  "$WD" "true"

# --- 11. optional: ask grok itself -------------------------------------------
if [[ -n "${GROK_BIN:-}" && -x "${GROK_BIN:-}" ]]; then
  LWD="$TMP/live-wd"; mkdir -p "$LWD"; echo "be helpful" > "$LWD/AGENTS.md"
  gtrust() { (cd "$LWD" && HOME="$1" timeout 30 "$GROK_BIN" inspect 2>&1 | grep -o 'Project trusted: [a-z]*'); }
  mkdir -p "$TMP/live-before"
  check "live grok: workdir with AGENTS.md is untrusted before the seed" "$(gtrust "$TMP/live-before")" "Project trusted: no"
  H=$(run live grok "$LWD" "$OTHERS")
  check "live grok: trusted after the seed" "$(gtrust "$H")" "Project trusted: yes"
else
  echo "skip: live grok arm (set GROK_BIN to a grok >= 1.0 binary)"
fi

echo
if (( fail )); then echo "RESULT: FAIL"; else echo "RESULT: PASS"; fi
[[ "$fail" -eq 0 ]]
