#!/usr/bin/env bash
# DIVE-2223: every persona was written to ~/.claude/CLAUDE.md regardless of the
# agent's harness type. On a codex / opencode / pi / antigravity seat that is a
# write into a path with no consumer: `tee` returns 0, `chmod` returns 0, the
# warn branch never fires, the operator sees a clean create — and the model is
# never told who it is. Four of seven council seats ran bare that way while the
# roster claimed a persona for each.
#
# The fix is TYPE_PERSONA_FILE (src/header.sh) + persona_target /
# persona_append_block / persona_install_doc (src/lib/agent_setup.sh). This test
# runs the REAL writers against a temp home root (PERSONA_HOME_ROOT) rather than
# grepping for the map, so it observes where the bytes actually land.
#
# Three dimensions:
#   (1) ROUTING     — each harness's block lands on its own path, and the claude
#                     path stays ABSENT for a non-claude seat (the bug is a file
#                     that exists, so only its absence disproves it).
#   (2) REFUSAL     — an unmapped type returns non-zero and installs NOTHING;
#                     it must not quietly degrade to the claude path.
#   (3) PRESERVATION— a codex seat already holds the DIVE-1410 return-channel doc
#                     at ~/.codex/AGENTS.md; installing a persona must PREPEND so
#                     both halves survive.
# Plus a wiring check that the two production call sites go through these
# functions, so the unit can't pass against a tree whose writers are still bare.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER="$ROOT/src/header.sh"
SETUP="$ROOT/src/lib/agent_setup.sh"

fails=0
# No spaces inside the arithmetic (tests/meta/harness-verdict-probe.sh).
bad() { echo "FAIL: $*" >&2; fails=$((fails+1)); }
note() { echo "  .. $*"; }

# --- load the real map + the real writers -----------------------------------
# Pre-declared empty so a tree WITHOUT the fix reports a clean vacuity failure
# instead of dying on `TYPE_PERSONA_FILE[claude]` being read as an arithmetic index.
declare -A TYPE_PERSONA_FILE=()
eval "$(sed -n '/^declare -A TYPE_PERSONA_FILE=(/,/^)/p' "$HEADER")"
eval "$(sed -n '/^persona_target() {/,/^}/p;/^_persona_ensure_dir() {/,/^}/p;/^persona_append_block() {/,/^}/p;/^persona_install_doc() {/,/^}/p' "$SETUP")"

# Vacuity guards: an extraction that silently produced nothing would let every
# assertion below "pass" against a tree with no fix in it.
[[ -n "${TYPE_PERSONA_FILE[claude]:-}" ]] || bad "could not load TYPE_PERSONA_FILE from header.sh (test would be vacuous)"
for fn in persona_target _persona_ensure_dir persona_append_block persona_install_doc; do
  declare -F "$fn" >/dev/null || bad "could not load $fn() from src/lib/agent_setup.sh (test would be vacuous)"
done
(( fails == 0 )) || { echo "FAILED: $fails persona-path violation(s)" >&2; exit 1; }

# --- stubs: strip privilege, keep the real file operations -------------------
WARNLOG=""
warn() { echo "warn: $*" >>"$WARNLOG"; }
step() { :; }
sudo() { [[ "${1:-}" == "-u" ]] && shift 2; "$@"; }
install() {
  local -a a=()
  while [[ $# -gt 0 ]]; do
    case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac
  done
  command install "${a[@]}"
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PERSONA_HOME_ROOT="$TMP/home"
WARNLOG="$TMP/warn.log"; : >"$WARNLOG"

# --- (1) routing: the documented path, per harness ---------------------------
#
# The expected column is the MEASURED table from
# community/wiki/per-harness-persona-file-paths.md — each row was established by
# a before/after role probe on a live seat, not read from a vendor doc.
check_target() { # check_target <type> <expected-relative-path>
  local type="$1" want="$2" got
  got=$(persona_target "seat-$type" "$type") \
    || { bad "persona_target refused a mapped type '$type'"; return; }
  if [[ "$got" == "$PERSONA_HOME_ROOT/agent-seat-$type/$want" ]]; then
    note "$type -> \$HOME/$want"
  else
    bad "$type resolved to '$got', expected \$HOME/$want"
  fi
}
check_target claude      ".claude/CLAUDE.md"
check_target grok        ".claude/CLAUDE.md"
check_target codex       ".codex/AGENTS.md"
check_target opencode    ".config/opencode/AGENTS.md"
check_target pi          ".pi/agent/AGENTS.md"
check_target antigravity ".gemini/GEMINI.md"

# The write itself, on a pi seat — and the ABSENCE of the old claude write. A
# persona that also lands in ~/.claude/CLAUDE.md would still pass a "did the new
# file appear" assertion, which is exactly how the bug survived a file census.
mkdir -p "$PERSONA_HOME_ROOT/agent-piseat"
persona_append_block piseat pi $'\n## Role: Founding Engineer\n' \
  || bad "persona_append_block failed on a pi seat"
if grep -q "Founding Engineer" "$PERSONA_HOME_ROOT/agent-piseat/.pi/agent/AGENTS.md" 2>/dev/null; then
  note "pi block landed in ~/.pi/agent/AGENTS.md"
else
  bad "pi role block did NOT land in ~/.pi/agent/AGENTS.md"
fi
if [[ -e "$PERSONA_HOME_ROOT/agent-piseat/.claude/CLAUDE.md" ]]; then
  bad "pi seat ALSO got ~/.claude/CLAUDE.md — the write into a path with no consumer is still happening"
else
  note "pi seat has no ~/.claude/CLAUDE.md (the old silent write is gone)"
fi

# --- (2) refusal: an unmapped type is loud, and writes nothing ---------------
#
# hermes and openclaw are unmapped on purpose (never probe-verified); newtype is
# the state a contributor lands in mid-registration. All three must refuse.
for t in hermes openclaw newtype; do
  : >"$WARNLOG"
  mkdir -p "$PERSONA_HOME_ROOT/agent-un-$t"
  out=$(persona_target "un-$t" "$t") && rc=0 || rc=$?
  if (( rc == 0 )); then
    bad "persona_target ACCEPTED unmapped type '$t' (returned '$out') — a silent default is the bug"
  elif [[ -n "$out" ]]; then
    bad "persona_target refused '$t' but still printed a path: '$out'"
  elif ! grep -q "\.claude/CLAUDE\.md" "$WARNLOG"; then
    bad "refusal for '$t' does not name the claude path it is refusing to fall back to"
  elif ! grep -q "TYPE_PERSONA_FILE" "$WARNLOG"; then
    bad "refusal for '$t' does not tell the operator how to map the type"
  else
    note "$t -> refused loudly (rc=$rc, $(wc -l <"$WARNLOG") warn lines)"
  fi
  persona_append_block "un-$t" "$t" "## Role: ghost" >/dev/null 2>&1
  if [[ -n "$(find "$PERSONA_HOME_ROOT/agent-un-$t" -type f 2>/dev/null)" ]]; then
    bad "unmapped type '$t' still wrote a file: $(find "$PERSONA_HOME_ROOT/agent-un-$t" -type f)"
  fi
done

# --- (3) preservation: prepend above the pre-existing standing instructions ---
#
# preseed_codex_return_channel() drops the DIVE-1410 doc at ~/.codex/AGENTS.md
# during create, so by persona time the file is NOT empty. An `install` over the
# top would delete operational plumbing to install an identity.
SENTINEL="RETURN CHANNEL: 5dive agent send back to the requester (DIVE-1410)"
mkdir -p "$PERSONA_HOME_ROOT/agent-codexseat/.codex"
printf '%s\n' "$SENTINEL" >"$PERSONA_HOME_ROOT/agent-codexseat/.codex/AGENTS.md"
printf '# Don, VP Marketing\nYou are Don.\n' >"$TMP/persona.md"
persona_install_doc codexseat codex "$TMP/persona.md" \
  || bad "persona_install_doc failed on a codex seat"
CODEXMD="$PERSONA_HOME_ROOT/agent-codexseat/.codex/AGENTS.md"
if ! grep -q "You are Don" "$CODEXMD" 2>/dev/null; then
  bad "codex persona was not installed at ~/.codex/AGENTS.md"
elif ! grep -qF "$SENTINEL" "$CODEXMD"; then
  bad "installing the persona CLOBBERED the pre-existing DIVE-1410 return-channel doc"
else
  p_line=$(grep -n "You are Don" "$CODEXMD" | head -1 | cut -d: -f1)
  s_line=$(grep -nF "$SENTINEL" "$CODEXMD" | head -1 | cut -d: -f1)
  if (( p_line < s_line )); then
    note "codex: persona prepended (line $p_line) above the return-channel doc (line $s_line) — both halves survive"
  else
    bad "codex: persona landed BELOW the pre-existing doc (persona line $p_line, sentinel line $s_line) — expected a prepend"
  fi
fi

# --- (4) wiring: the production call sites actually route through this --------
#
# Without this the unit could pass while cmd_compose.sh / cmd_pack.sh still hold
# their own hardcoded ~/.claude/CLAUDE.md write.
grep -q 'persona_append_block "\$name" "\$type" "\$block"' "$ROOT/src/cmd_compose.sh" \
  || bad "_compose_write_role_md does not route through persona_append_block"
grep -qE 'md="\$home/\.claude/CLAUDE\.md"' "$ROOT/src/cmd_compose.sh" \
  && bad "cmd_compose.sh still hardcodes the claude persona path"
grep -q 'persona_install_doc "\$as" "\$type" "\$stage/CLAUDE.md"' "$ROOT/src/cmd_pack.sh" \
  || bad "pack install does not route the identity doc through persona_install_doc"
grep -q 'install -o "agent-\${as}" -g "agent-\${as}" -m 644 "\$stage/CLAUDE.md" "\$cdir/CLAUDE.md"' "$ROOT/src/cmd_pack.sh" \
  && bad "cmd_pack.sh still installs the identity doc straight into ~/.claude/CLAUDE.md"

# --- verdict ----------------------------------------------------------------
if (( fails )); then
  echo "FAILED: $fails persona-path violation(s)" >&2
else
  echo "PASS: personas route to the file each harness reads, unmapped types refuse loudly, and a codex seat keeps its return-channel doc"
fi
[[ "$fails" -eq 0 ]]
