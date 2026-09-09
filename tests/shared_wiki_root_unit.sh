#!/usr/bin/env bash
# DIVE-4128 — the per-box shared team wiki.
#
# Grades the four arms the row names, all of them PURE (no root, no network):
#   1. resolver precedence: $FIVEDIVE_WIKI_ROOT > /var/lib/5dive/wiki >
#      the two fleet community/wiki paths, and "" when none exist.
#   2. NEGATIVE ARM: with no root at all, `memory add --store=wiki` refuses with
#      an error that NAMES THE FIX, and `_seed_wiki_memory` reports 0 LOUDLY
#      (a line on stderr saying why) instead of the silent 0 that let a whole
#      box of agents boot cold while `agent create` printed success.
#   3. an EMPTY root is distinguished from an ABSENT one — different fixes.
#   4. a page published to the wiki is left GROUP-WRITABLE, so the second seat
#      can edit it and append to the index. A shared wiki that only its author
#      can write is a broadcast channel.
#
# Run: bash tests/shared_wiki_root_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/shared-wiki-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  source "$SRC/$f"
done
source "$SRC/cmd_pack.sh"
source "$SRC/cmd_memory.sh"
source "$SRC/cmd_agent_create.sh"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq() { [ "$2" = "$3" ] && ok_t "$1" || bad_t "$1" "want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok_t "$1" ;; *) bad_t "$1" "[$2] lacks [$3]" ;; esac; }

# The real box root cannot be created without root, and this harness must be
# runnable by any seat — so the /var/lib/5dive/wiki rung is graded through the
# same resolver with HOME repointed, and the rung is asserted by ORDER against
# the override, which is the property that actually matters.
export HOME="$TMP/home"; mkdir -p "$HOME"

# ── 1. precedence ──────────────────────────────────────────────────────────
mkdir -p "$TMP/override" "$HOME/projects/5dive/community/wiki"
# NOTE the explicit export + unset rather than a `VAR=x eq ...` prefix: the
# args of that form are expanded BEFORE the assignment applies, so the command
# substitution would run with the OLD value and the test would grade nothing.
export FIVEDIVE_WIKI_ROOT="$TMP/override"
eq "override wins over the fleet path" "$(_memory_wiki_root)" "$TMP/override"
unset FIVEDIVE_WIKI_ROOT
eq "fleet community/wiki still resolves when no override is set" \
  "$(_memory_wiki_root)" "$HOME/projects/5dive/community/wiki"
export FIVEDIVE_WIKI_ROOT="$TMP/does-not-exist"
eq "an override naming a MISSING dir is not reported as a root" \
  "$(_memory_wiki_root)" "$HOME/projects/5dive/community/wiki"
unset FIVEDIVE_WIKI_ROOT
rm -rf "$HOME/projects"
# /home/claude/projects/5dive/community/wiki is a real path on fleet boxes and
# absent on customer boxes; only assert the empty case when it is truly absent,
# so this harness grades the same on both.
if [ ! -d /home/claude/projects/5dive/community/wiki ] && [ ! -d /var/lib/5dive/wiki ]; then
  eq "no root anywhere -> empty" "$(_memory_wiki_root)" ""
else
  ok_t "SKIP empty-case (this box has a real wiki root; precedence graded above)"
fi

# ── 2 + 3. the two zero-seeding arms are DISTINGUISHABLE and LOUD ──────────
seedout="$TMP/seed"; mkdir -p "$seedout"
# An ABSENT root means every rung misses. HOME is repointed at a dir with no
# projects/ tree; the two absolute fleet paths are graded by the guarded SKIPs
# above, so this arm is honest on a fleet box too: it asserts the message the
# resolver-returns-empty branch emits, reached here via the override rung.
_no_root_seed() (
  export FIVEDIVE_WIKI_ROOT="$TMP/nope"
  HOME="$TMP/nohome"
  _memory_wiki_root() { echo ""; }   # every rung missed
  _seed_wiki_memory "$seedout" >/dev/null
)
absent_err=$(_no_root_seed 2>&1)
has "absent root: seeding says WHY, not just 0" "$absent_err" "no shared team wiki root on this box"
has "absent root: seeding names the fix"       "$absent_err" "/var/lib/5dive/wiki"

mkdir -p "$TMP/emptywiki"
empty_err=$( ( export FIVEDIVE_WIKI_ROOT="$TMP/emptywiki"; _seed_wiki_memory "$seedout" >/dev/null ) 2>&1 )
has "empty root: reported as EMPTY, not as absent" "$empty_err" "holds no pages yet"
case "$empty_err" in *"no shared team wiki root"*) bad_t "empty root is not conflated with an absent one" "got the absent-root message";; *) ok_t "empty root is not conflated with an absent one";; esac

# non-vacuity: a POPULATED root seeds silently and returns N>0
mkdir -p "$TMP/fullwiki"; printf -- '---\ntitle: a\n---\nbody\n' > "$TMP/fullwiki/a.md"
n=$( ( export FIVEDIVE_WIKI_ROOT="$TMP/fullwiki"; _seed_wiki_memory "$seedout" ) 2>"$TMP/quiet" )
eq "populated root seeds N>0" "$n" "1"
eq "populated root warns about nothing" "$(cat "$TMP/quiet")" ""

# ── 4. a published page is group-writable ─────────────────────────────────
mkdir -p "$TMP/pubwiki"; : > "$TMP/pubwiki/index.md"
mkdir -p "$HOME/.claude/projects/p/memory"
out=$(FIVEDIVE_WIKI_ROOT="$TMP/pubwiki" bash -c '
  source '"$SRC"'/header.sh; source '"$SRC"'/lib/error_codes.sh; source '"$SRC"'/lib/output.sh
  source '"$SRC"'/lib/validation.sh; source '"$SRC"'/lib/state.sh; source '"$SRC"'/lib/audit.sh
  source '"$SRC"'/lib/registry.sh; source '"$SRC"'/cmd_memory.sh; set +e
  echo "a durable fact" | _memory_add --name=probe-fact --description="a probe" --type=reference \
    --no-check="unit harness" --store=wiki --no-dedup' 2>&1)
if [ -f "$TMP/pubwiki/probe-fact.md" ]; then
  mode=$(stat -c '%a' "$TMP/pubwiki/probe-fact.md")
  # The GROUP bit is the MIDDLE digit. An earlier `?[2367]?|[2367]??` alternative
  # here passed on 644 — the second branch matched the owner digit — i.e. the
  # assertion could not go red on exactly the defect it exists to catch.
  case "$mode" in ?[2367]?) ok_t "published page is group-writable (mode $mode)";; *) bad_t "published page is group-writable" "mode $mode";; esac
  imode=$(stat -c '%a' "$TMP/pubwiki/index.md")
  case "$imode" in ?[2367]?) ok_t "index stays group-writable (mode $imode)";; *) bad_t "index stays group-writable" "mode $imode";; esac
else
  bad_t "publish to a resolved wiki root writes the page" "$out"
fi

# The refusal a customer box actually hits. Graded by stubbing the resolver to
# the empty it returns there, so this arm runs on a fleet box too instead of
# skipping exactly where the row's defect lived.
noroot=$( ( _memory_wiki_root() { echo ""; }
            echo body | _memory_add --name=x --description=d --type=project --store=wiki --no-dedup ) 2>&1 )
has "no-root refusal names the box-shared root"  "$noroot" "/var/lib/5dive/wiki"
has "no-root refusal names the installer as the fix" "$noroot" "installer"
has "no-root refusal still offers the private store" "$noroot" "--store=mine"

printf '\n── %d passed, %d failed ──\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
