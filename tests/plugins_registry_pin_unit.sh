#!/usr/bin/env bash
# DIVE-4754 — the plugins tree a required check grades must be PINNED, and the
# guard that says so must be scoped to the BEHAVIOUR, not to a directory.
#
# WHAT HAPPENED. 2026-09-21 05:49:52Z, 5dive-plugins#102 deleted plugins/browser.
# Two minutes later the required `test` context on 5dive-ai/5dive@main went 23
# pass / 5 fail on tests/plugin_bundled_install_unit.sh (run 35566195362) with
# ZERO commits in this repo, and every merge and release cut froze for ~20min
# (DIVE-4752). DIVE-4708 was the same class the day before.
#
# WHY THE GUARD THAT EXISTS FOR EXACTLY THIS WAS GREEN ON THE RED RUN. DIVE-4452's
# two arms are both rooted at `.github/workflows/`. The clone that resolved the
# subject of the failing arms lived in `scripts/run-harnesses.sh`, and its path
# carried a `-registry` suffix, so neither needle reached it. Two clones, two
# fates: $RUNNER_TEMP/5dive-plugins pinned, $RUNNER_TEMP/5dive-plugins-registry
# on main. A directory in a selector is a bet that the code will not move, and
# the de-duplication that removed six copies of this fetch is exactly the kind of
# cleanup that moves it. See
# community/wiki/a-pin-guard-that-greps-a-directory-is-scoped-to-a-location-not-a-behaviour.md
#
# SO THIS HARNESS GRADES TWO THINGS, and the split is deliberate:
#
#   T1..T8  BEHAVIOUR — it drives fivedive_resolve_plugin_registry itself with a
#           fake `git` on PATH and reads the ARGUMENTS the function passed. It
#           does not grep the source around the call, because a text arm reds as
#           plumbing the moment somebody reformats the line it reads.
#   T9..T13 CENSUS — repo-wide, allowlist-by-NAME, no directory in the selector.
#           These are the arms that would have fired on 2026-09-20: the offending
#           clone is a hit wherever in the tree it sits.
#
# A NOTE ON THE NEGATIVE ARMS. `main`, a tag, a short sha and the empty string
# are all refused by one test, and refusal is not a downgrade: the arms report
# NOT RUN, loudly, and the corpus still grades. A required check that is not a
# function of this tree alone is the defect being closed here, so "resolve
# something" is never preferable to "resolve the pin or nothing".
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"

TMP="$(mktemp -d)"
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

HELPER="$ROOT/scripts/lib/plugin-registry-pin.sh"
if [[ ! -f "$HELPER" ]]; then
  echo "FAIL: scripts/lib/plugin-registry-pin.sh is missing — the pinned resolver is the subject of this harness"
  echo; echo "PASS=0 FAIL=1"; exit 1
fi

PIN="$(printf '0123456789abcdef%.0s' 1 2)abcdef0123456789abcdef"   # 40 hex, fixed
PIN="${PIN:0:40}"

# A fake git that records every invocation and never touches the network. The
# `init` arm makes a real directory so the function's own -d test behaves.
mk_fake_git() {   # mk_fake_git <bindir> <logfile> <fetch_rc> [head_sha]
  local bin="$1" log="$2" frc="$3" head="${4:-}"
  mkdir -p "$bin"
  cat >"$bin/git" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [[ "\$1" == "-C" ]]; then sub="\$3"; shift 3; else sub="\$1"; shift; fi
case "\$sub" in
  init)      d=""; for a in "\$@"; do [[ "\$a" == --* ]] || d="\$a"; done; [[ -n "\$d" ]] && mkdir -p "\$d/.git" ;;
  fetch)     exit $frc ;;
  rev-parse) if [[ -n "$head" ]]; then printf '%s\n' "$head"; else exit 1; fi ;;
  *)         : ;;
esac
exit 0
FAKE
  chmod +x "$bin/git"
  : >"$log"
}

# drive <name> — run the resolver in a subshell with a fake git, a fresh
# RUNNER_TEMP and whatever environment the caller exported. Echoes rc, and
# leaves $OUT/$ERR/$GITLOG/$REGVAL for the arms.
OUT=""; ERR=""; RC=0; GITLOG=""; REGVAL=""
drive() {
  local case_dir="$TMP/$1"; shift
  rm -rf "$case_dir"; mkdir -p "$case_dir/runner" "$case_dir/bin"
  # PRECREATE=1 lays down an existing checkout so the idempotence shortcut is
  # REACHED — without it T7 would pass because the directory was simply absent,
  # which is a vacuous green about the arm it claims to grade.
  [[ "${PRECREATE:-0}" == 1 ]] && mkdir -p "$case_dir/runner/5dive-plugins-registry/.git"
  mk_fake_git "$case_dir/bin" "$case_dir/git.log" "${FETCH_RC:-0}" "${FAKE_HEAD:-}"
  local o="$case_dir/out" e="$case_dir/err" r="$case_dir/reg"
  (
    PATH="$case_dir/bin:$PATH"
    export RUNNER_TEMP="$case_dir/runner"
    # shellcheck source=/dev/null
    . "$HELPER"
    fivedive_resolve_plugin_registry
    printf '%s' "$?" > "$case_dir/rc"
    printf '%s' "${FIVEDIVE_PLUGIN_REGISTRY:-}" > "$r"
  ) >"$o" 2>"$e"
  RC="$(cat "$case_dir/rc" 2>/dev/null || echo 99)"
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  GITLOG="$(cat "$case_dir/git.log" 2>/dev/null || true)"
  REGVAL="$(cat "$r" 2>/dev/null || true)"
}

# ---------------------------------------------------------------- T1: the pin
# The happy path, and the only arm that says what "pinned" MEANS: the sha this
# job was configured with is the sha that reached the fetch.
export CI=1 PLUGINS_REF="$PIN"; unset FIVEDIVE_PLUGIN_REGISTRY; FETCH_RC=0; FAKE_HEAD=""
drive t1
t  "T1 resolver succeeded with a 40-hex pin"            "0" "$RC"
tc "T1 fetch carried the pin verbatim"                  "fetch --quiet --depth 1 origin $PIN" "$GITLOG"
tc "T1 registry exported to the -registry path"         "5dive-plugins-registry" "$REGVAL"
tc "T1 it says on stdout that it is pinned"             "PINNED" "$OUT"

# T1b — the spelling matters. `git clone` resolves a BRANCH; the repo-wide arms
# below forbid it, and this is the arm that says the resolver does not use it.
tn "T1b the resolver never invokes git clone"           "clone" "$GITLOG"

# ------------------------------------------- T2/T3/T4: every moving ref refused
# T3 is the root-cause arm: `main` is precisely what the old code used, so a
# resolver that accepts it has been reverted whatever else it does.
unset PLUGINS_REF; export CI=1; unset FIVEDIVE_PLUGIN_REGISTRY
drive t2
t  "T2 unset PLUGINS_REF is refused"                    "1" "$RC"
t  "T2 and nothing is exported"                         ""  "$REGVAL"
tn "T2 no network verb ran at all"                      "fetch" "$GITLOG"
tc "T2 it says UNRESOLVED on stderr"                    "UNRESOLVED" "$ERR"

export PLUGINS_REF=main
drive t3
t  "T3 PLUGINS_REF=main is refused (the 2026-09-21 defect)" "1" "$RC"
t  "T3 and nothing is exported"                         ""  "$REGVAL"
tn "T3 no network verb ran at all"                      "fetch" "$GITLOG"

export PLUGINS_REF=69f4557
drive t4
t  "T4 a short sha is refused"                          "1" "$RC"
export PLUGINS_REF="v0.31.0"
drive t4b
t  "T4b a tag is refused"                               "1" "$RC"
export PLUGINS_REF="${PIN^^}"
drive t4c
t  "T4c an UPPERCASE sha is refused (one spelling only)" "1" "$RC"

# ------------------------------------------------- T5/T6: the two no-op cases
# Local runs must be untouched: no CI, no fetch, no opinion.
unset CI; export PLUGINS_REF="$PIN"; unset FIVEDIVE_PLUGIN_REGISTRY
drive t5
t  "T5 off CI the resolver does nothing and succeeds"   "0" "$RC"
t  "T5 and exports nothing"                             ""  "$REGVAL"
t  "T5 and runs no git"                                 ""  "$GITLOG"

export CI=1 FIVEDIVE_PLUGIN_REGISTRY="/some/local/checkout" PLUGINS_REF="$PIN"
drive t6
t  "T6 an already-set registry is left alone"           "0" "$RC"
t  "T6 and runs no git"                                 ""  "$GITLOG"
unset FIVEDIVE_PLUGIN_REGISTRY

# -------------------------------- T7: an existing checkout is not self-evidence
# "the directory is there" is not a statement about its contents. A tree left at
# some other sha must be re-fetched to the pin, or the idempotence shortcut is a
# second unpinned path wearing a cache's shape.
export CI=1 PLUGINS_REF="$PIN"; FETCH_RC=0
PRECREATE=1 FAKE_HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" drive t7
tc "T7 a checkout at the wrong sha is re-fetched to the pin" "fetch --quiet --depth 1 origin $PIN" "$GITLOG"
# The control for T7, without which "it re-fetched" says nothing: at the RIGHT
# sha the shortcut must actually short-cut, or the arm above is just "it always
# fetches" and the idempotence it grades does not exist.
PRECREATE=1 FAKE_HEAD="$PIN" drive t7b
tn "T7b a checkout already at the pin is not re-fetched" "fetch" "$GITLOG"
t  "T7b and it is still exported"  "$TMP/t7b/runner/5dive-plugins-registry" "$REGVAL"

# ------------------------------------------------- T8: a failure is not fatal
export CI=1 PLUGINS_REF="$PIN"; FETCH_RC=1
drive t8
t  "T8 a failed fetch returns 1, it does not exit"      "1" "$RC"
t  "T8 and exports nothing"                             ""  "$REGVAL"
tc "T8 and says UNRESOLVED"                             "UNRESOLVED" "$ERR"
FETCH_RC=0
unset CI PLUGINS_REF

# ===========================================================================
# CENSUS — repo-wide, allowlisted BY NAME. No directory appears in a selector.
# ===========================================================================

# The named allowlist. Each entry is a file that is ALLOWED to name a live,
# unpinned 5dive-plugins fetch, with the reason it is allowed written beside it.
# T10 asserts every entry still exists, so a stale exemption cannot quietly
# widen the guard the way a directory scope quietly narrowed it.
ALLOW_CLONE=(
  # prose only: describes the PRODUCT's fallback for a customer, clones nothing.
  "tests/plugin_installs_scope_unit.sh"
  # this harness: the pattern is its subject.
  "tests/plugins_registry_pin_unit.sh"
  # the resolver: it is the pinned path, and it names the forbidden spelling in
  # a comment saying why it does not use it.
  "scripts/lib/plugin-registry-pin.sh"
)
# Files that deliberately read the LIVE registry (DIVE-4202): a pinned manifest
# would grade a file no customer reads.
ALLOW_LIVE=(
  ".github/workflows/install-smoke.yml"
  ".github/workflows/install-guard.yml"
)

# T9 — the arm that would have fired on 2026-09-20. Repo-wide; a clone in a
# script, a hook, a docker file or a skill is a hit exactly like one in a
# workflow. src/ is NOT exempt by directory: it is not matched because the
# product builds its URL rather than spelling `git clone`, and if it ever does
# spell it, this arm is the right place to have the argument.
pat='git clone .*5dive-'"plugins"
hits="$(grep -rlE "$pat" . --exclude-dir=.git 2>/dev/null | sed 's|^\./||' | sort || true)"
unexpected=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  ok=0
  for a in "${ALLOW_CLONE[@]}"; do [[ "$f" == "$a" ]] && ok=1 && break; done
  [[ "$ok" == 1 ]] || unexpected="$unexpected$f"$'\n'
done <<<"$hits"
t "T9 no un-allowlisted file clones 5dive-plugins (repo-wide)" "" "$(printf '%s' "$unexpected")"

# T10 — a stale allowlist is a hole. Every exemption must still be a real file.
missing=""
for a in "${ALLOW_CLONE[@]}" "${ALLOW_LIVE[@]}"; do
  [[ -f "$a" ]] || missing="$missing$a "
done
t "T10 every allowlist entry still exists" "" "${missing% }"

# T11 — the positive half, and the one DIVE-4452 could not state: every workflow
# that RUNS the harness corpus must declare a workflow-level 40-hex PLUGINS_REF,
# because scripts/run-harnesses.sh now reads exactly that variable. The selector
# is "does this file run the corpus", which is the behaviour, not a path.
runners=""; norefs=""; refs=""
for f in .github/workflows/*.yml; do
  grep -q 'run-harnesses\.sh' "$f" || continue
  runners="$runners$f "
  v="$(sed -n 's/^  PLUGINS_REF: \([0-9a-f]\{40\}\)$/\1/p' "$f")"
  if [[ -z "$v" ]]; then norefs="$norefs$f "; else refs="$refs$v"$'\n'; fi
done
t  "T11 every corpus-running workflow declares a 40-hex PLUGINS_REF" "" "${norefs% }"
tc "T11 unit-tests.yml is one of them"  "unit-tests.yml"  "$runners"
tc "T11 full-sweep.yml is one of them"  "full-sweep.yml"  "$runners"

# T12 — one pin, not several. Two workflows disagreeing means two subjects.
n="$(printf '%s' "$refs" | sort -u | grep -c . || true)"
t "T12 all workflow pins are the same sha" "1" "$n"

# T13 — the resolver is actually wired in. The census arms above grade the tree;
# this one grades that the tree's only fetch path goes through the pinned
# function, which is what makes T1..T8 evidence about CI and not about a file.
# The needles skip comment lines on purpose: M5 (delete the source line, leave
# the `# shellcheck source=` line behind) survived a naive `cat | grep`, which
# is the same "I matched the prose about the thing" mistake the old guard made.
wiring="$(grep -vE '^[[:space:]]*#' scripts/run-harnesses.sh)"
tc "T13 run-harnesses.sh sources the pinned resolver" \
   "lib/plugin-registry-pin.sh" "$wiring"
tc "T13 and calls it" \
   "fivedive_resolve_plugin_registry" "$wiring"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
