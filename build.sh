#!/usr/bin/env bash
# Concatenate src/ into the single-file `5dive` binary the installer fetches.
#
# Why a build step: the installed artifact is a single file (curl install.5dive.com
# | sudo bash drops one binary into /usr/local/bin). The source repo is split for
# readability — see CONTRIBUTING in README.md. CI runs ./build.sh && git diff
# --exit-code 5dive on every push to catch "edited the bundle, forgot to edit
# src/" drift in either direction.
#
# Order matters: header.sh has `set -euo pipefail` + every global / declare -A
# map, so it must come first. main.sh has the EXIT trap and `main "$@"`, so it
# must come last. The middle is grouped by concern (lib/ helpers → cmd_*
# subcommands). state.sh / audit.sh / registry.sh look interleaved because the
# original script's audit block sat between ensure_state and with_registry_lock;
# keeping that order makes the bundle byte-identical with the pre-refactor file.
set -euo pipefail

cd "$(dirname "$0")"

# Output path is overridable (BUILD_OUT) so tests can build a throwaway binary to a
# temp dir without dirtying the tracked ./5dive artifact. Defaults to the repo ./5dive.
OUT="${BUILD_OUT:-5dive}"

# DIVE-2603: FIVE_VERSION is assigned only when a release tag is cut, so a
# working-tree bundle permanently says 0.0.0-dev. Carry the source identity as
# a separate fact that remains meaningful both before and after tag time. A
# dirty tree is deliberately stamped <sha>-dirty: the artifact contains bytes
# HEAD does not, so install.sh must reject the stamp as ancestry evidence and
# fall back to the version path instead of trusting a false identity.
BUILD_SHA="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || {
  echo "error: cannot resolve the source commit for $OUT" >&2
  exit 1
}
if [[ ! "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: source commit is not a full git sha: $BUILD_SHA" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  BUILD_SHA="${BUILD_SHA}-dirty"
fi

# DIVE-2681: BUILD_OUT may name the bundle ANYTHING, and .gitignore only knows
# about `/5dive` + `/5dive.sha256` (DIVE-2091). So `BUILD_OUT=./5dive-fix` builds
# a 3.3MB bundle that git happily tracks, and one `git add -A` puts it on main —
# which is exactly what happened in #434. The ignore rule was never wrong; the
# output name walked around it.
#
# Refuse rather than widen the glob: a name list only ever covers the names
# someone already used, and `5dive-agent-start` / `5dive-refresh-*.sh` are real
# tracked files, so `/5dive-*` would be worse than the disease. Build inside the
# tree ONLY as the ignored ./5dive; anywhere else, build outside it.
_out_abs=$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")
_repo_abs=$(pwd)
if [[ "$_out_abs" == "$_repo_abs"/* && "$(basename "$OUT")" != "5dive" ]]; then
  printf 'build.sh: refusing to write %s inside the repo.\n' "$(basename "$OUT")" >&2
  printf '  Only ./5dive is gitignored here (DIVE-2091); any other in-tree name is TRACKED\n' >&2
  printf '  and a `git add -A` will commit a multi-megabyte bundle (DIVE-2681, PR #434).\n' >&2
  printf '  Build to a path outside the repo instead: BUILD_OUT=/tmp/5dive-test ./build.sh\n' >&2
  exit 2
fi
unset _out_abs _repo_abs

# ---------------------------------------------------------------------------
# THE TWO REGIONS (DIVE-4087). CORE_FILES are parsed on every single invocation;
# LAZY_FILES sit after a top-level `exit` as unparsed text and are read back with
# sed only when something calls into them. Moving a file between the two lists is
# the only knob here — see scripts/lib/lazy-dispatch.sh for why it works, and
# tests/lazy_dispatch_unit.sh for what stops it going wrong.
#
# Order inside each list still matters. header.sh has `set -euo pipefail` + every
# global, so it is first. main.sh has the EXIT trap and `main "$@"`, so it closes
# the core. Within LAZY_FILES the order is the old cat order, because sed replays
# ranges in file order and a handful of src/task/*.sh files open with top-level
# assignments a later one reads.
# ---------------------------------------------------------------------------
CORE_FILES=(
  src/header.sh
  src/lib/error_codes.sh
  src/lib/marketplace.sh
  src/lib/self.sh
  src/lib/output.sh
  src/lib/validation.sh
  src/lib/models.sh
  src/lib/agent_setup.sh
  src/lib/state.sh
  src/lib/env_overrides.sh
  src/lib/capability.sh
  src/lib/broker.sh
  src/lib/durable.sh
  src/lib/disk.sh
  src/lib/audit.sh
  src/lib/reap.sh
  src/lib/registry.sh
  src/lib/quota_wall.sh
  src/lib/agent_env.sh
  src/lib/verify_policy.sh
  src/lib/tasks_db.sh
  src/lib/runs.sh
  src/lib/actor.sh
  src/lib/routing_receipt.sh
  src/lib/a2a_rounds.sh
)

LAZY_FILES=(
  src/cmd_auth.sh
  src/cmd_account.sh
  src/cmd_agent.sh
  src/cmd_agent_create.sh
  src/cmd_agent_lifecycle.sh
  src/cmd_agent_config.sh
  src/cmd_agent_buzz.sh
  src/cmd_agent_buzz_join.sh
  src/cmd_agent_buzz_whois.sh
  src/cmd_agent_buzz_pair.sh
  src/cmd_buzz.sh
  src/cmd_agent_buzz_bridge.sh
  src/cmd_agent_telegram.sh
  src/cmd_agent_teambot.sh
  src/cmd_agent_pairing.sh
  src/cmd_agent_runtime.sh
  src/cmd_cos.sh
  src/cmd_acp.sh
  src/cmd_skill.sh
  src/cmd_init.sh
  src/cmd_doctor.sh
  src/cmd_host.sh
  src/cmd_watch.sh
  src/cmd_compose.sh
  src/cmd_whoami.sh
  src/cmd_box_config.sh
  src/task/dispatch.sh
  src/task/routing.sh
  src/task/crud.sh
  src/task/gate_evidence.sh
  src/task/status.sh
  src/task/grader_pool.sh
  src/task/delivery.sh
  src/task/loops.sh
  src/task/need.sh
  src/task/notify.sh
  src/task/inbox.sh
  src/task/answer.sh
  src/task/doctor.sh
  src/cmd_task.sh
  src/cmd_trigger.sh
  src/cmd_trace.sh
  src/cmd_run.sh
  src/cmd_org.sh
  src/cmd_human.sh
  src/cmd_ui.sh
  src/cmd_hire.sh
  src/cmd_project.sh
  src/cmd_goal.sh
  src/cmd_objective.sh
  src/cmd_company.sh
  src/cmd_council.sh
  src/cmd_constitution.sh
  src/cmd_loop.sh
  src/cmd_loop_pack.sh
  src/cmd_crew.sh
  src/cmd_heartbeat.sh
  src/cmd_supervisor.sh
  src/cmd_a2a.sh
  src/cmd_liveness.sh
  src/cmd_fleet.sh
  src/cmd_usage.sh
  src/cmd_digest.sh
  src/cmd_proof.sh
  src/cmd_selfcheck.sh
  src/cmd_push.sh
  src/cmd_deploy.sh
  src/cmd_gh.sh
  src/cmd_bug.sh
  src/cmd_memory.sh
  src/cmd_pack.sh
  src/cmd_plugin.sh
  src/cmd_secret.sh
  src/cmd_selfupdate.sh
)

# main.sh closes the core: it installs the EXIT trap and calls `main "$@"`.
CORE_TAIL=src/main.sh

# Every file must end in a newline or concatenation silently welds two lines
# together and every line number after it is off by one. Cheap to assert, and
# the line numbers in __MOD are now load-bearing rather than cosmetic.
for _f in "${CORE_FILES[@]}" "$CORE_TAIL" "${LAZY_FILES[@]}"; do
  if [[ -n "$(tail -c1 "$_f")" ]]; then
    echo "error: $_f does not end with a newline — __MOD line ranges would shift" >&2
    exit 1
  fi
done

# The build recipe is TWO files now. Say so by name, because the bare
# "No such file or directory" this replaces is what a harness that copies
# src/ + build.sh into a temp tree sees, and it reads as a broken build rather
# than a missing input (it cost two red harnesses on DIVE-4087: see
# tests/install_monotonicity_unit.sh and tests/selfcheck_mutation_e2e.sh).
if [[ ! -r scripts/lib/lazy-dispatch.sh ]]; then
  echo "build.sh: scripts/lib/lazy-dispatch.sh is missing — it generates the lazy" >&2
  echo "  dispatch index (DIVE-4087) and the build recipe is BOTH files. If you are" >&2
  echo "  assembling a tree to build in, copy scripts/ alongside src/ and build.sh." >&2
  exit 1
fi
# shellcheck source=scripts/lib/lazy-dispatch.sh
. scripts/lib/lazy-dispatch.sh

_lazywork="$(mktemp -d)"
trap 'rm -rf "$_lazywork"' EXIT

# --- the trailing payload, and where each module lives inside it -------------
: >"$_lazywork/payload"
: >"$_lazywork/index"
_rel=0
for _f in "${LAZY_FILES[@]}"; do
  # Frame every module with its own name. The line index below is the fast path;
  # these two comment lines are what lets _load_module tell "I read module X"
  # from "I read 48 lines of something else because a harness rewrote the file
  # above me" — see scripts/lib/lazy-dispatch.sh.
  _mod="$(lazy_mod_name "$_f")"
  printf '#@MOD %s\n' "$_mod" >>"$_lazywork/payload"
  _n=$(( $(wc -l <"$_f") + 2 ))
  cat "$_f" >>"$_lazywork/payload"
  printf '#@ENDMOD %s\n' "$_mod" >>"$_lazywork/payload"
  # src/cmd_task.sh is a LOADER, not a module: in the split tree it sources
  # src/task/*.sh, and in the bundle every guard it holds is already satisfied
  # so it does nothing (see the header of that file). It defines no function, so
  # nothing can reach it — keep its bytes in the payload so the bundle is still
  # the whole of src/, but give it no index entry to be loaded through.
  if [[ "$_f" != "src/cmd_task.sh" ]]; then
    printf '%s %s %s %s\n' "$_mod" "$((_rel + 1))" "$((_rel + _n))" "$_f" \
      >>"$_lazywork/index"
  fi
  _rel=$((_rel + _n))
done

lazy_core_names "${CORE_FILES[@]}" "$CORE_TAIL" | sort -u >"$_lazywork/corenames"
lazy_build_index "$_lazywork/index" "$_lazywork/corenames" "$_lazywork"

# --- assemble ---------------------------------------------------------------
# Two passes, because the payload's absolute line numbers depend on how long the
# core is and the core contains those numbers. Only ONE line of the generated
# block carries the offset, and it is one line at either value, so pass 2 lands
# on the same core length as pass 1 — asserted rather than assumed.
_assemble() { # <offset> <out>
  {
    cat "${CORE_FILES[@]}"
    lazy_emit "$_lazywork/index" "$_lazywork" "$1"
    cat "$CORE_TAIL"
    # `main "$@"` above either exits inside itself or falls through to here.
    # Either way bash never reads a byte past this line, which is the entire
    # trick: everything below is text, not code, until sed hands a slice of it
    # back to _load_module.
    printf '%s\n' 'exit $?' '# ==== 5dive lazy payload — unparsed below this line (DIVE-4087) ===='
  } >"$2"
}

_assemble 0 "$_lazywork/core.pass1"
_offset=$(wc -l <"$_lazywork/core.pass1")
_assemble "$_offset" "$_lazywork/core.pass2"
if [[ "$(wc -l <"$_lazywork/core.pass2")" != "$_offset" ]]; then
  echo "error: core length changed between build passes ($_offset -> $(wc -l <"$_lazywork/core.pass2"))" >&2
  exit 1
fi

cat "$_lazywork/core.pass2" "$_lazywork/payload" \
  | sed -E "s/^readonly FIVE_BUILD_SHA=\"[^\"]*\"/readonly FIVE_BUILD_SHA=\"$BUILD_SHA\"/" \
  > "$OUT"

# DIVE-1261: publish a sha256 of the bundle so the installer can verify the fetched binary before
# swapping it in. Regenerated on every build and committed alongside the bundle; CI's build+diff
# drift check keeps the two in sync.
#
# CNCL-23 regression: generate the sha IMMEDIATELY after writing the bundle, BEFORE any step that
# could abort under `set -e` (the chmod below, the FIVE_VERSION check) — otherwise the bundle and
# its committed sha can DRIFT. A `chmod: Operation not permitted` (building a claude-owned worktree
# as another user) once aborted right before the old sha line, shipping a 0.12.7 bundle carrying
# 0.12.6's sha (PR #95 — CI drift-gate RED, host-roll refused on the mismatch). Order now
# guarantees: whenever $OUT exists on disk post-build, $OUT.sha256 matches it.
sha256sum "$OUT" | awk '{print $1}' > "$OUT.sha256"

# +x is a local convenience (the installer re-chmods the fetched binary); a cross-user perms
# failure must NOT abort the build and re-open the sha-drift window above.
chmod +x "$OUT" 2>/dev/null || true

# Sanity-check the version line landed in the bundle. CI's bundle-drift check
# already catches missing src→bundle plumbing, but this gives a tighter error
# when someone empties out FIVE_VERSION by accident.
if ! grep -qE '^readonly FIVE_VERSION="[^"]+"' "$OUT"; then
  echo "error: $OUT is missing FIVE_VERSION — check src/header.sh" >&2
  exit 1
fi
if ! grep -qE "^readonly FIVE_BUILD_SHA=\"${BUILD_SHA}\"$" "$OUT"; then
  echo "error: $OUT is missing FIVE_BUILD_SHA=$BUILD_SHA — check src/header.sh" >&2
  exit 1
fi

# DIVE-2097: src/lib/self.sh must precede every five_self_bundle consumer in the cat
# list above. Each consumer opens with `declare -F five_self_bundle ||
# source ".../lib/self.sh"` — dead code in the bundle, load-bearing in the split tree
# (see src/lib/self.sh and community/wiki/command-v-answers-the-wrong-question.md
# rule 5). That property only held because the cat list ABOVE was hand-ordered with a
# prose comment ("Order matters: ... lib/ helpers -> cmd_*"); nothing enforced it. If a
# future consumer ever lands ahead of lib/self.sh in the list, the guard fires inside
# the bundle where dirname "$BASH_SOURCE" is the INSTALL dir and lib/self.sh does not
# exist — the source fails, and `set -euo pipefail` (src/header.sh) takes the whole CLI
# down. Checked on the built artifact rather than the cat list text so this also catches
# a future refactor that stops concatenating from a fixed file list.
def_line="$(grep -n '^five_self_bundle() {' "$OUT" | head -1 | cut -d: -f1)"
if [[ -z "$def_line" ]]; then
  echo "error: $OUT has no five_self_bundle definition — check src/lib/self.sh" >&2
  exit 1
fi
guard_line="$(grep -n 'declare -F five_self_bundle' "$OUT" | head -1 | cut -d: -f1)"
if [[ -n "$guard_line" && "$def_line" -gt "$guard_line" ]]; then
  echo "error: $OUT defines five_self_bundle at line $def_line, AFTER the first" >&2
  echo "  consumer guard at line $guard_line. src/lib/self.sh must be cat'd before" >&2
  echo "  every five_self_bundle consumer — fix the file order in build.sh." >&2
  exit 1
fi

echo "built $OUT ($(wc -l < "$OUT") lines, $(grep -oE '^readonly FIVE_VERSION="[^"]+"' "$OUT" | cut -d'"' -f2) at ${BUILD_SHA:0:12}) + $OUT.sha256 ($(cut -c1-16 "$OUT.sha256")…)"
