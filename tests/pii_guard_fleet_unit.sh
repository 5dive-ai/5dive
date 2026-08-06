#!/usr/bin/env bash
# DIVE-2788 — the pre-push PII guard reaches repos that are NOT 5dive-ai/5dive.
#
# THE MEASURED DEFECT. scripts/install-pii-push-guard.sh called itself
# "fleet-wide" and refused every origin but one, because the only install mode
# was a RELATIVE core.hooksPath into the repo's own scripts/git-hooks. Twenty-two
# remotes on this host, one covered; the id reached current main of two PUBLIC
# repos and rendered as an <input placeholder> in the customer dashboard.
#
# WHAT THIS GRADES, and why each arm is here rather than a review:
#   1. the installer classifies by origin, and 5dive-ai/5dive-plugins is NOT
#      5dive-ai/5dive — the old `*5dive-ai/5dive*` glob matched it and would have
#      pointed a relative hooksPath at a directory that does not exist there.
#   2. the guard home really receives the scanner AND the denylist (a hook whose
#      payload never arrived reads exactly like an installed one).
#   3. THE MUTATION PROBE: a push carrying a denylisted value into a NON-5dive
#      remote is refused, and the value does not reach the remote. This is the
#      arm the row's ACCEPTANCE names.
#   4. a clean push still succeeds (a guard that blocks everything is removed).
#   5. a PURE-DELETION push is not blocked — DIVE-1935's regression, carried
#      across into the portable hook, where `grep '^+'` exiting 1 on no match
#      used to be indistinguishable from a denylist hit.
#   6. an existing $GIT_DIR/hooks/pre-push STILL RUNS. core.hooksPath REPLACES
#      the default hooks dir; lodar/5dive-frontend has such a hook, so a naive
#      install would have deleted a live control while reporting success.
#   7. the installer REFUSES a foreign hooksPath rather than clobbering it.
#   8. the fleet enumerator sees a NESTED checkout and a HIDDEN-directory
#      checkout — the two shapes `ls -d */` missed, which is how a live push
#      remote under marketing/.work stayed invisible during the row's own sweep.
#
# POSITIVE CONTROL FIRST (arm 0). Every arm below infers "the guard fired" from a
# non-zero push. A scanner that cannot run also exits non-zero, so the fixture
# denylist is proved to make the scanner exit 1 on the fixture value BEFORE any
# push arm is trusted.
#
# HERMETIC, and it never touches the real guard home: PII_GUARD_HOME points into
# a tempdir, the "remotes" are local bare repos, and the denylisted value is the
# reserved fake 1234567890 hashed into a FIXTURE denylist — the real
# .github/pii-denylist.txt hashes real identifiers and no test may depend on one.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
INSTALLER="$ROOT/scripts/install-pii-push-guard.sh"
FLEET="$ROOT/scripts/pii-guard-fleet.sh"
SCANNER="$ROOT/scripts/pii-scan.sh"

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
set +e

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
chk()    { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (expected '$2', got '$3')"; fi }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

FAKE_ID=1234567890                      # the reserved fake, per CLAUDE.md
GUARD_HOME="$TMP/guard-home"
export PII_GUARD_HOME="$GUARD_HOME"

# ── arm 0: positive control on the fixture denylist ───────────────────────────
FIXTURE_DENY="$TMP/fixture-denylist.txt"
printf '%s  # fixture — reserved fake, not a real id\n' \
  "$(printf '%s' "$FAKE_ID" | sha256sum | cut -d' ' -f1)" > "$FIXTURE_DENY"

PII_DENYLIST="$FIXTURE_DENY" bash "$SCANNER" <<<"nothing here" >/dev/null 2>&1
chk "arm0 positive control: fixture denylist passes clean text" 0 "$?"
PII_DENYLIST="$FIXTURE_DENY" bash "$SCANNER" <<<"id is $FAKE_ID" >/dev/null 2>&1
chk "arm0 positive control: fixture denylist REJECTS the fixture value" 1 "$?"

# ── fixture repos ─────────────────────────────────────────────────────────────
mk_remote() { git init -q --bare "$TMP/$1.git"; }
mk_clone() {  # $1 name, $2 fake origin url to advertise
  git init -q "$TMP/$1" && git -C "$TMP/$1" symbolic-ref HEAD refs/heads/main
  git -C "$TMP/$1" remote add origin "$TMP/$1.git"
  echo seed > "$TMP/$1/README.md"
  git -C "$TMP/$1" add -A && git -C "$TMP/$1" commit -qm "seed"
  git -C "$TMP/$1" push -q --no-verify origin main 2>/dev/null
}

mk_remote plugins && mk_clone plugins
REPO="$TMP/plugins"

# ── arm 1: classification ─────────────────────────────────────────────────────
git -C "$REPO" remote set-url origin "https://github.com/5dive-ai/5dive-plugins.git"
kind="$(bash "$INSTALLER" --status "$REPO" 2>/dev/null | awk -F'\t' '{print $2}')"
chk "arm1 5dive-ai/5dive-plugins classifies as portable (not in-repo)" portable "$kind"

git -C "$REPO" remote set-url origin "git@github.com:5dive-ai/5dive.git"
kind="$(bash "$INSTALLER" --status "$REPO" 2>/dev/null | awk -F'\t' '{print $2}')"
chk "arm1 5dive-ai/5dive (ssh, .git) classifies as in-repo" in-repo "$kind"

git -C "$REPO" remote set-url origin "$TMP/plugins.git"   # back to the pushable one

# ── arm 2: install materialises the payload ───────────────────────────────────
out="$(bash "$INSTALLER" "$REPO" 2>&1)"; irc=$?
chk "arm2 install exits 0 on a non-5dive repo" 0 "$irc"
case "$out" in *"portable mode"*) ok_t "arm2 install reports portable mode" ;;
  *) fail_t "arm2 install did not report portable mode (got: $out)" ;; esac
[[ -x "$GUARD_HOME/pre-push" ]] && ok_t "arm2 guard home has an executable pre-push" \
  || fail_t "arm2 guard home has no executable pre-push"
if cmp -s "$GUARD_HOME/pii-denylist.txt" "$ROOT/.github/pii-denylist.txt"; then
  ok_t "arm2 the REAL denylist is what gets copied to the guard home"
else
  fail_t "arm2 guard home denylist differs from .github/pii-denylist.txt"
fi
cmp -s "$GUARD_HOME/pii-scan.sh" "$ROOT/scripts/pii-scan.sh" \
  && ok_t "arm2 the scanner is copied verbatim (no forked scan logic)" \
  || fail_t "arm2 guard home scanner differs from scripts/pii-scan.sh"
grep -q '^source_sha=' "$GUARD_HOME/INSTALLED" 2>/dev/null \
  && ok_t "arm2 the install stamps its provenance (source_sha)" \
  || fail_t "arm2 INSTALLED stamp missing source_sha"

# The stamp must not name a sha that does not contain the bytes it just copied.
# Syncing from a dirty tree is the NORMAL case while a change is in review, so a
# bare sha there asserts provenance the payload does not have.
#
# Built by COPYING the working tree's scripts into a scratch repo, not by
# cloning $ROOT: a clone takes HEAD, so it would grade the last COMMITTED
# installer while the author is editing an uncommitted one — the harness would
# pass or fail on whether the fix happened to be committed yet, which is a claim
# about the git index, not about the code. Cost me one confusing red.
PROV="$TMP/prov"
mkdir -p "$PROV/scripts" "$PROV/.github"
cp -f "$ROOT/scripts/install-pii-push-guard.sh" "$ROOT/scripts/pii-scan.sh" "$PROV/scripts/"
mkdir -p "$PROV/scripts/git-hooks-portable"
cp -f "$ROOT/scripts/git-hooks-portable/pre-push" "$PROV/scripts/git-hooks-portable/"
cp -f "$ROOT/.github/pii-denylist.txt" "$PROV/.github/"
git init -q "$PROV" && git -C "$PROV" add -A && git -C "$PROV" commit -qm "fixture"
if [[ -d "$PROV/scripts" ]]; then
  PII_GUARD_HOME="$TMP/gh-clean" bash "$PROV/scripts/install-pii-push-guard.sh" --sync >/dev/null 2>&1
  s_clean="$(sed -n 's/^source_sha=//p' "$TMP/gh-clean/INSTALLED" 2>/dev/null)"
  case "$s_clean" in *+uncommitted) fail_t "arm2 a CLEAN tree was stamped +uncommitted ($s_clean)" ;;
    "") fail_t "arm2 no source_sha from the clean clone" ;;
    *)  ok_t "arm2 a clean source tree stamps a bare sha" ;; esac
  echo "# dirty" >> "$PROV/scripts/pii-scan.sh"
  PII_GUARD_HOME="$TMP/gh-dirty" bash "$PROV/scripts/install-pii-push-guard.sh" --sync >/dev/null 2>&1
  s_dirty="$(sed -n 's/^source_sha=//p' "$TMP/gh-dirty/INSTALLED" 2>/dev/null)"
  case "$s_dirty" in *+uncommitted) ok_t "arm2 a DIRTY source tree stamps sha+uncommitted, not a bare sha" ;;
    *) fail_t "arm2 dirty tree stamped a sha that does not contain the copied bytes ($s_dirty)" ;; esac
else
  fail_t "arm2 provenance arms could not run (fixture repo not built) — asserting nothing"
fi
chk "arm2 core.hooksPath points at the guard home" "$GUARD_HOME" \
  "$(git -C "$REPO" config --local --get core.hooksPath)"

# Swap in the fixture denylist for the firing arms. Propagation of the REAL one
# is already asserted above; no push arm may depend on a real identifier.
cp -f "$FIXTURE_DENY" "$GUARD_HOME/pii-denylist.txt"

# ── arm 3: THE MUTATION PROBE ─────────────────────────────────────────────────
git -C "$REPO" checkout -q -b mutation
printf 'contact id %s\n' "$FAKE_ID" > "$REPO/leak.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "add a contact file"
perr="$(timeout 30 git -C "$REPO" push origin mutation 2>&1)"; prc=$?
chk "arm3 MUTATION PROBE: push carrying a denylisted value is REFUSED" 1 "$prc"
case "$perr" in *"pii-push-guard"*) ok_t "arm3 the refusal names pii-push-guard" ;;
  *) fail_t "arm3 refusal did not name the guard (got: $(head -c 200 <<<"$perr"))" ;; esac
chk "arm3 the value did not reach the remote" "" \
  "$(git -C "$TMP/plugins.git" rev-parse --verify -q refs/heads/mutation 2>/dev/null)"

# ── arm 4: a clean push still lands ───────────────────────────────────────────
git -C "$REPO" checkout -q main
echo "no identifiers here" > "$REPO/clean.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "clean change"
timeout 30 git -C "$REPO" push -q origin main 2>/dev/null
chk "arm4 a clean push is NOT blocked" 0 "$?"

# ── arm 5: pure deletion is not misreported as a hit (DIVE-1935) ──────────────
git -C "$REPO" rm -q clean.txt && git -C "$REPO" commit -qm "remove it again"
derr="$(timeout 30 git -C "$REPO" push origin main 2>&1)"; drc=$?
chk "arm5 a pure-deletion push is NOT blocked" 0 "$drc"
case "$derr" in *"denylisted"*) fail_t "arm5 deletion push wrongly reported a denylist hit" ;;
  *) ok_t "arm5 deletion push reports no denylist hit" ;; esac

# ── arm 6: an existing $GIT_DIR/hooks/pre-push still runs ─────────────────────
#
# The repo's own hook is resolved from the git COMMON dir, NOT from
# `rev-parse --git-path hooks/pre-push`. That form HONOURS core.hooksPath, so
# once the guard is installed it hands back the guard's own hook — which is how
# the first version of chain() came to invoke itself, unbounded, on every push.
# A harness that located the hook the same wrong way would have planted its
# fixture INTO the guard home and quietly graded nothing.
own="$(git -C "$REPO" rev-parse --absolute-git-dir)/hooks/pre-push"
mkdir -p "$(dirname "$own")"
printf '#!/usr/bin/env bash\ntouch "%s/chained.marker"\nexit 0\n' "$TMP" > "$own"
chmod +x "$own"
rm -f "$TMP/chained.marker"
echo "still clean" > "$REPO/clean2.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "another clean change"
timeout 30 git -C "$REPO" push -q origin main 2>/dev/null
[[ -f "$TMP/chained.marker" ]] \
  && ok_t "arm6 the repo's own pre-push hook still ran (chained, not clobbered)" \
  || fail_t "arm6 core.hooksPath silently disabled the repo's own pre-push hook"

# A chained hook must also see the ref-update list, not an empty stdin.
printf '#!/usr/bin/env bash\nread -r a b c d || exit 3\n[[ -n "$b" ]] || exit 3\ntouch "%s/chained.stdin"\nexit 0\n' "$TMP" > "$own"
chmod +x "$own"
rm -f "$TMP/chained.stdin"
echo "clean three" > "$REPO/clean3.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "third clean change"
timeout 30 git -C "$REPO" push -q origin main 2>/dev/null
[[ -f "$TMP/chained.stdin" ]] \
  && ok_t "arm6 the chained hook receives the ref-update list on stdin" \
  || fail_t "arm6 the chained hook got an empty stdin (it would scan nothing and pass)"

# The self-chain regression, asserted directly and with a clock on it: plant a
# COPY OF THE GUARD ITSELF as the repo's own hook — the worst case — and require
# the push to terminate. Unbounded recursion has no failing assertion, only a
# hang, so a timeout is the only instrument that can report it.
cp -f "$GUARD_HOME/pre-push" "$own" && chmod +x "$own"
echo "clean four" > "$REPO/clean4.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "fourth clean change"
timeout 30 git -C "$REPO" push -q origin main >/dev/null 2>&1; trc=$?
if [[ $trc -eq 124 ]]; then
  fail_t "arm6 push did not terminate — the guard is chaining to itself (fork bomb)"
else
  ok_t "arm6 the guard does not chain to itself even when the repo's own hook IS the guard"
fi
rm -f "$own"

# ── arm 7: a foreign hooksPath is refused, not clobbered ──────────────────────
mk_remote foreign && mk_clone foreign
git -C "$TMP/foreign" config --local core.hooksPath /somebody/elses/hooks
out="$(bash "$INSTALLER" "$TMP/foreign" 2>&1)"; frc=$?
chk "arm7 installer exits 1 on a foreign hooksPath" 1 "$frc"
chk "arm7 the foreign hooksPath is left intact" "/somebody/elses/hooks" \
  "$(git -C "$TMP/foreign" config --local --get core.hooksPath)"
case "$out" in *REFUSING*) ok_t "arm7 the refusal says REFUSING" ;;
  *) fail_t "arm7 refusal not announced (got: $out)" ;; esac

# ── arm 8: the enumerator sees nested and hidden checkouts ────────────────────
FROOT="$TMP/fleet"
mkdir -p "$FROOT/plain" "$FROOT/not-a-repo/.work/nested" "$FROOT/.hidden-wt"
for d in plain not-a-repo/.work/nested .hidden-wt; do
  git init -q "$FROOT/$d"
  git -C "$FROOT/$d" remote add origin "https://github.com/5dive-ai/fixture-$(basename "$d").git"
done
# `gh` is STUBBED for these arms, and that is an assertion, not just hygiene.
# Without a stub, "visibility is UNKNOWN" passes for two different reasons — the
# tool correctly refusing to guess, or the network merely having failed — and a
# harness that cannot tell those apart is asserting nothing. It also makes the
# arm hermetic: a network-priced harness is what swings this corpus's budget
# (DIVE-2592 measured a 67s swing on one file), and the tier cap is spent in
# wall-clock.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"; chmod +x "$STUBBIN/gh"
frep="$(PATH="$STUBBIN:$PATH" bash "$FLEET" --root "$FROOT" 2>&1)"
got="$(sed -n 's/^checkouts found: *//p' <<<"$frep")"
chk "arm8 enumerator finds all three checkouts (nested + hidden included)" 3 "$got"
case "$frep" in *"roots walked:"*) ok_t "arm8 the report names the roots it walked" ;;
  *) fail_t "arm8 the report does not name its roots" ;; esac
case "$frep" in *"POPULATION, NOT A VERDICT"*) ok_t "arm8 the report states it is a population" ;;
  *) fail_t "arm8 the report omits the population caveat" ;; esac
case "$frep" in *"UNKNOWN"*) ok_t "arm8 unreadable visibility reports UNKNOWN (not private)" ;;
  *) fail_t "arm8 no UNKNOWN row — an unmeasured value was given a value" ;; esac

# POSITIVE CONTROL for the arm above: with a gh that ANSWERS, the report must
# carry the answer. Without this, "prints UNKNOWN" is equally satisfied by a
# tool that prints UNKNOWN unconditionally — which would pass the arm while
# reporting nothing, the failure mode this whole file is about.
printf '#!/bin/sh\ncase "$*" in *visibility*) echo PUBLIC;; *) exit 1;; esac\n' > "$STUBBIN/gh"
chmod +x "$STUBBIN/gh"
frep2="$(PATH="$STUBBIN:$PATH" bash "$FLEET" --root "$FROOT" 2>&1)"
case "$frep2" in *PUBLIC*) ok_t "arm8 positive control: a gh that ANSWERS is reported (UNKNOWN is not unconditional)" ;;
  *) fail_t "arm8 visibility is UNKNOWN even when gh answers — the column asserts nothing" ;; esac

# ── arms 9-12: PROVISIONING (DIVE-2803) ───────────────────────────────────────
#
# Merged into this file rather than filed as a new harness: the subject is
# identical (how far the PII guard actually reaches), the fixtures above are the
# ones these arms need, and the core tier is at ~96% of its cap — CLAUDE.md's
# first way out is "merge by subject", and this is that case exactly.
#
# THE DEFECT THESE GRADE. install.sh's PII block used to be a loop over
# PRE-EXISTING checkouts of this repo. install.sh never clones (`git clone`
# appears nowhere in it), so on a freshly provisioned box the loop iterated ZERO
# times and /usr/local/share/5dive/pii-guard was never created. The guard was
# "fleet-wide" on a census of boxes that already had a checkout, and absent on
# every box provisioning made after it — DIVE-1997's error one layer up.
#
# Executed, not grepped: the staging block is EXTRACTED VERBATIM from install.sh
# (the tests/install_monotonicity_unit.sh idiom) and run against a file:// $REPO,
# so a rewrite of that block that stops populating the guard home fails here.
# Hermetic — $LIB_DIR, $REPO and PII_GUARD_HOME are all inside $TMP, and the
# denylist is the FIXTURE one (reserved fake 1234567890), never the real file.
PGBLOCK="$(sed -n '/^  # >>> DIVE-2803 guard-home staging/,/^  # <<< DIVE-2803 guard-home staging/p' "$ROOT/install.sh")"
if [[ -z "$PGBLOCK" ]]; then
  fail_t "arm9 could not extract the DIVE-2803 staging block from install.sh (markers moved or removed)"
else
  ok_t "arm9 the DIVE-2803 staging block is extractable from install.sh"

  # A file:// $REPO standing in for the pinned release tree. Same four paths
  # install.sh fetches, same layout, so the extracted block is unmodified.
  PGREPO="$TMP/pgrepo"
  mkdir -p "$PGREPO/scripts/git-hooks-portable" "$PGREPO/.github"
  cp "$INSTALLER" "$PGREPO/scripts/install-pii-push-guard.sh"
  cp "$ROOT/scripts/git-hooks-portable/pre-push" "$PGREPO/scripts/git-hooks-portable/pre-push"
  cp "$SCANNER" "$PGREPO/scripts/pii-scan.sh"
  printf '%s\n' "$(printf '1234567890' | sha256sum | awk '{print $1}')" > "$PGREPO/.github/pii-denylist.txt"

  # Not a real commit and never was — a fixture sha, per the reserved-fakes rule.
  PGSHA=0123456789abcdef0123456789abcdef01234567

  run_pg_block() { # <lib-dir> <repo-url> <pinned-sha> <guard-home>
    LIB_DIR="$1" REPO="$2" GH_PINNED_SHA="$3" PII_GUARD_HOME="$4" \
      bash -c 'set -uo pipefail
export PII_GUARD_HOME
ok() { echo "  ok $*"; }
mkdir -p "$LIB_DIR"
'"$PGBLOCK"'' 2>&1
  }

  PGLIB="$TMP/pglib"; PGHOME="$TMP/pghome"
  out9="$(run_pg_block "$PGLIB" "file://$PGREPO" "$PGSHA" "$PGHOME")"

  # arm 9: the guard home is POPULATED on a box with no checkout of this repo.
  # All four files, because a hook whose payload never arrived reads exactly
  # like an installed one (the same reason arm 2 exists).
  miss=""
  for f in pre-push pii-scan.sh pii-denylist.txt INSTALLED; do
    [[ -s "$PGHOME/$f" ]] || miss="$miss $f"
  done
  if [[ -z "$miss" ]]; then
    ok_t "arm9 fresh box (no checkout): guard home populated with hook, scanner, denylist and stamp"
  else
    fail_t "arm9 guard home missing:$miss — output: $out9"
  fi
  [[ -x "$PGHOME/pre-push" ]] \
    && ok_t "arm9 the staged hook is executable (a non-exec hook is silently skipped by git)" \
    || fail_t "arm9 staged pre-push is not executable"

  # arm 10: the stamp NAMES THE COMMIT. The row's ACCEPTANCE says the INSTALLED
  # stamp on a provisioned box names a real commit; a staged tree has no .git,
  # so without PII_GUARD_SRC_SHA every provisioned box would stamp UNKNOWN.
  got_sha="$(sed -n 's/^source_sha=//p' "$PGHOME/INSTALLED" 2>/dev/null)"
  chk "arm10 INSTALLED names the pinned commit, not UNKNOWN" "${PGSHA:0:12}" "$got_sha"

  # NEGATIVE CONTROL for arm 10, and it is the arm that makes the one above mean
  # something: with no pinned sha the stamp must say UNKNOWN rather than invent a
  # value. Without this, "names a commit" is equally satisfied by a stamp that
  # always prints something.
  PGHOME2="$TMP/pghome2"
  run_pg_block "$TMP/pglib2" "file://$PGREPO" "" "$PGHOME2" >/dev/null 2>&1
  chk "arm10 negative control: no pinned sha stamps UNKNOWN (no value is invented)" \
      UNKNOWN "$(sed -n 's/^source_sha=//p' "$PGHOME2/INSTALLED" 2>/dev/null)"

  # SECOND NEGATIVE CONTROL: PII_GUARD_SRC_SHA must not be able to launder a git
  # tree's real state. Run the installer from THIS repo (a git tree) with the
  # fixture sha exported; the stamp must report the tree, never the variable.
  PGHOME3="$TMP/pghome3"
  PII_GUARD_HOME="$PGHOME3" PII_GUARD_SRC_SHA="$PGSHA" bash "$INSTALLER" --sync >/dev/null 2>&1
  case "$(sed -n 's/^source_sha=//p' "$PGHOME3/INSTALLED" 2>/dev/null)" in
    "${PGSHA:0:12}") fail_t "arm10 PII_GUARD_SRC_SHA overrode a real git tree — a dirty checkout could stamp itself clean" ;;
    "")              fail_t "arm10 no source_sha written when syncing from a git tree" ;;
    *)               ok_t "arm10 PII_GUARD_SRC_SHA is ignored when \$SRC_REPO is a git tree" ;;
  esac

  # arm 11: THE GATE DECISION, asserted on the code rather than left in a body.
  # DIVE-2803 was answered B: provisioning wires the guard home and the box's own
  # CLI checkout, and pii-guard-fleet.sh --install is NOT on that path, because
  # install.sh runs as ROOT where the tool's EPERM-by-owner bound cannot fire.
  # A future edit that "completes" the wiring by adding it is the exact change
  # that needs to come back to a human, so it fails here.
  case "$PGBLOCK" in
    *pii-guard-fleet*) fail_t "arm11 the provisioning path invokes pii-guard-fleet.sh — DIVE-2803 answered B: report-only, off this path" ;;
    *)                 ok_t "arm11 provisioning does not invoke pii-guard-fleet.sh (DIVE-2803 gate answer B holds)" ;;
  esac

  # arm 12: an offline/mirror $REPO that does not serve the payload must WARN and
  # leave the box alone — never fail the install, and never delete the staged
  # tree it already has. REPO=file:///opt/5dive-bundle is the documented offline
  # install path and it ships only the bundle, so this is a real shape.
  before="$(cat "$PGLIB/pii-guard-src/scripts/pii-scan.sh" 2>/dev/null | wc -c)"
  # Without this, "before == after" is satisfied by 0 == 0 — i.e. by a staging
  # step that never wrote anything, which is the failure arm12 exists to catch.
  [[ "$before" -gt 0 ]] \
    && ok_t "arm12 precondition: arm9 left a staged payload under \$LIB_DIR to survive" \
    || fail_t "arm12 precondition: no staged payload under \$LIB_DIR — the survival check would be vacuous"
  out12="$(run_pg_block "$PGLIB" "file://$TMP/nonexistent-mirror" "$PGSHA" "$PGHOME")"
  rc12=$?
  after="$(cat "$PGLIB/pii-guard-src/scripts/pii-scan.sh" 2>/dev/null | wc -c)"
  chk "arm12 a mirror that does not serve the payload does not fail the install" 0 "$rc12"
  case "$out12" in *warn:*) ok_t "arm12 the miss is announced, not silent" ;;
    *) fail_t "arm12 payload staging failed with no warning — a silent miss reads as installed" ;; esac
  chk "arm12 the previously staged payload survives a failed refresh" "$before" "$after"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
