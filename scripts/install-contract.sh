#!/usr/bin/env bash
# DIVE-4141 — the INSTALL CONTRACT, graded on a freshly installed box.
#
# WHY THIS FILE EXISTS. Two v0.28.0 defects had the same shape: the artifact
# EXISTS and does not INSTALL or RUN.
#   * DIVE-4126 — the browser plugin shipped uninstallable. `plugin add browser`
#     refuses with "unknown grant 'browser-profiles'" because the grant the
#     manifest declares is not in PLUGIN_GRANTS. Nothing in CI ever ran
#     `plugin add` on a bundled plugin, so a plugin that cannot be installed
#     shipped green.
#   * #808 — the `distribution` team template was in team-templates/index.json
#     but not in install.sh's staging list, so `team import distribution`
#     resolved to nothing on a real box while every unit test passed.
# tests/plugin_contract_unit.sh set-compares install.sh's staged FILE list
# against what plugins/ contains. That is a filename comparison; it cannot see
# that the file it certifies as present refuses to install.
#
# WHAT GRADES IT. This harness does not read source and does not compare lists.
# It runs the real verbs on a container that install.sh has just installed into,
# as root, and asserts they exit 0. It is EXECUTION on the shipped artifact.
#
# ENUMERATED FROM THE MANIFESTS, NEVER A HAND LIST. Three enumerations, each
# from the thing that would drift:
#   * plugins   <- plugins/.claude-plugin/marketplace.json (the repo's manifest,
#                  mounted at $MANIFEST_DIR). A plugin added to the marketplace
#                  is covered the day it lands, with no edit here.
#   * templates <- team-templates/index.json (same).
#   * verbs     <- the INSTALLED BUNDLE's own dispatch table. Not src/main.sh:
#                  reading the artifact means a verb that exists in source but
#                  did not survive build.sh is a red, not a blind spot.
#
# THE SOURCE OF TRUTH IS THE REPO SIDE ON PURPOSE. The manifests are mounted
# from the checkout, not read out of $LIB_DIR. Reading the installed copy would
# make install.sh's staging list its own examiner: a template install.sh forgot
# to stage would simply not be enumerated, and #808 would pass again.
#
# WHY scripts/ AND NOT tests/. Every tests/*.sh is a corpus harness: CLAUDE.md
# makes it `core` tier by default and scripts/run-harnesses.sh globs the
# directory, so a file placed there is run in the unit-tests job — where there
# is no installed box and no container, and this harness would grade nothing
# while spending the 300s core budget. It is a container arm, and it lives with
# the other helpers the workflows shell out to. shellcheck -S error covers
# scripts/*.sh, so it is still linted.
#
# RUN IT:
#   docker run --rm -v $PWD/scripts/install-contract.sh:/contract.sh:ro \
#     -v $PWD/plugins/.claude-plugin/marketplace.json:/manifests/marketplace.json:ro \
#     -v $PWD/team-templates/index.json:/manifests/team-index.json:ro \
#     --entrypoint /bin/bash 5dive-smoke /contract.sh
set -uo pipefail

FIVE="${FIVE_BIN:-/usr/local/bin/5dive}"
LIB="${FIVE_LIB_DIR:-/usr/local/lib/5dive}"
MANIFEST_DIR="${MANIFEST_DIR:-/manifests}"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

# --- VERBS THIS HARNESS MUST NOT RUN ----------------------------------------
# Denied because `--help` is not a flag these verbs PARSE — they act, and as
# root in a container they would act successfully:
#   uninstall      fetches install.sh over the network and execs --uninstall
#   self-update/update  replaces the CLI under the harness that is testing it
#   paperclip-seed ignores argv entirely and runs the seed
#   fire           `agent rm` under another name
#   hire           `agent create` under another name
# Excluding these is not a coverage gap being papered over: asserting
# `--help` exit 0 on a verb that does not read flags asserts nothing. The
# launcher arm above covers the startup path; agent lifecycle is unit-covered.
DENY='uninstall self-update self_update update paperclip-seed fire hire'

# --- MEASURED BASELINE: verbs with no --help handling today ------------------
# Measured 2026-09-09 on 278c3879, as root: these 15 spellings answer `--help`
# with a usage ERROR (rc 2), not usage text. They are pre-existing defects, not
# regressions from this change, and fixing 15 argument parsers inside the PR
# that adds the check would make the check unreviewable. They are waived HERE,
# enumerated, and T5 makes the waiver SELF-RETIRING: a waived verb that starts
# answering --help correctly turns this harness RED until it is removed from
# this list, so the baseline can only shrink. A verb added to the CLI after
# today is asserted by T4 with no waiver available.
WAIVED='account activity buzz cost deploy doctor gate-proof host objective objectives project projects push trace usage'

in_list() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

# `5dive <verb> --help` with a bounded timeout, stdin closed (an interactive
# wizard that ignored --help would otherwise park the job until the workflow
# timeout, which reads as a hang rather than a red).
verb_help_rc() {
  timeout 30 "$FIVE" "$1" --help </dev/null >/dev/null 2>&1
  printf '%s' "$?"
}

echo "=== install contract: $($FIVE --version 2>&1 | head -1) ==="

# ---------------------------------------------------------------------------
# T1/T2 — every bundled plugin INSTALLS, and the verb it declares DISPATCHES
# ---------------------------------------------------------------------------
MARKET="$MANIFEST_DIR/marketplace.json"
if [[ ! -f "$MARKET" ]]; then
  bad_t "T1 preconditions" "marketplace manifest not mounted at $MARKET"
else
  mapfile -t PLUGINS < <(jq -r '.plugins[].name' "$MARKET")
  (( ${#PLUGINS[@]} > 0 )) || bad_t "T1 preconditions" "marketplace.json declares no plugins"
  for p in "${PLUGINS[@]}"; do
    # The staged manifest is asserted before `plugin add`, so "install.sh never
    # staged this plugin" reports as itself instead of as a confusing add
    # failure. This is the #808 shape on the plugin side.
    staged="$LIB/plugins/$p/.claude-plugin/plugin.json"
    if [[ -f "$staged" ]]; then
      ok_t "T1a $p: staged by install.sh at $staged"
    else
      bad_t "T1a $p: staged by install.sh" "no manifest at $staged — install.sh's per-file staging list does not carry this plugin, so it is in the marketplace and not on the box"
      continue
    fi

    out=$(timeout 120 "$FIVE" plugin add "$p" --yes </dev/null 2>&1); rc=$?
    if (( rc == 0 )); then
      ok_t "T1b $p: 5dive plugin add $p --yes"
    else
      bad_t "T1b $p: 5dive plugin add $p --yes" "rc=$rc — $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
      continue
    fi

    # A plugin declaring the `verb` capability adds a top-level command. Installed
    # but undispatchable is the same class of defect as uninstallable, so grade
    # the dispatch rather than trusting the install's exit code.
    mapfile -t pverbs < <(jq -r '.fivedive.verbs[]?.name // empty' "$staged")
    for v in "${pverbs[@]}"; do
      vrc=$(verb_help_rc "$v")
      if [[ "$vrc" == "0" ]]; then
        ok_t "T2 $p: 5dive $v --help dispatches (rc 0)"
      else
        bad_t "T2 $p: 5dive $v --help dispatches" "rc=$vrc — the plugin installed but its declared verb does not run"
      fi
    done
  done
fi

# ---------------------------------------------------------------------------
# T3 — every template in the registry RESOLVES on the box, with its own roster
# ---------------------------------------------------------------------------
# `team ps <slug>` is the read-only half of the import path: it runs the same
# _team_resolve_template + _compose_parse that `team import` runs, then reads
# state through ensure_state_ro. So it grades "the template is on the box and
# parses" without provisioning agents — which on a container would need a
# harness binary and a credential, and would grade the agent-create path this
# job already covers elsewhere.
INDEX="$MANIFEST_DIR/team-index.json"
if [[ ! -f "$INDEX" ]]; then
  bad_t "T3 preconditions" "team registry not mounted at $INDEX"
else
  mapfile -t SLUGS < <(jq -r '.companies[].slug' "$INDEX")
  (( ${#SLUGS[@]} > 0 )) || bad_t "T3 preconditions" "index.json declares no companies"
  for s in "${SLUGS[@]}"; do
    want=$(jq -r --arg s "$s" '.companies[] | select(.slug==$s) | (.roster | length)' "$INDEX")
    # TEAM_AUTH_PROFILE is supplied here for the reason cmd_team's slug-free
    # `ps` supplies it internally: the curated specs interpolate ${TEAM_AUTH_PROFILE}
    # and _compose_parse fails loudly on an unset var. The slug FORM of
    # `team ps` does not set it (measured 2026-09-09 on 278c3879: rc 3, "env
    # var 'TEAM_AUTH_PROFILE' referenced in spec is unset") — a real gap in
    # that verb, filed separately. Naming the profile here keeps this arm
    # grading the TEMPLATE rather than that gap.
    out=$(TEAM_AUTH_PROFILE=__install_contract__ timeout 60 "$FIVE" --json team ps "$s" </dev/null 2>&1); rc=$?
    if (( rc != 0 )); then
      bad_t "T3a $s: 5dive team ps $s" "rc=$rc — $(printf '%s' "$out" | tail -3 | tr '\n' ' ') (a slug in team-templates/index.json that install.sh did not stage looks exactly like this — #808)"
      continue
    fi
    ok_t "T3a $s: template resolves and parses on the installed box"
    got=$(printf '%s' "$out" | jq -r '.data.agents | length' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
      ok_t "T3b $s: roster is $got agents, matching the registry"
    else
      bad_t "T3b $s: roster matches the registry" "registry says $want agents, the staged spec parses to ${got:-<unparseable>} — the two halves of one template have drifted"
    fi
  done
fi

# ---------------------------------------------------------------------------
# T4 — every builtin verb answers --help
# ---------------------------------------------------------------------------
# Enumerated out of the INSTALLED bundle's dispatch table: the second
# `case "$top" in` in main() is the verb table, and it ends at its default arm.
# Hidden privileged primitives (_task_answer, _audit_append, _push_do, …) are
# skipped by the leading-underscore filter — they are reachable only through a
# scoped sudoers grant and are deliberately unadvertised.
mapfile -t VERBS < <(
  awk '/^  case "\$top" in$/{n++} n==2{ if ($0 ~ /^    \*\)/) exit; print }' "$FIVE" \
    | grep -oE '^    [a-z][a-z0-9|_-]*\)' | tr -d ' )' | tr '|' '\n' | sort -u
)
if (( ${#VERBS[@]} < 40 )); then
  bad_t "T4 preconditions" "extracted only ${#VERBS[@]} verbs from $FIVE — the dispatch table's shape changed and this enumeration has gone blind; fix the extractor, do not lower the floor"
else
  ok_t "T4 preconditions: ${#VERBS[@]} verbs enumerated from the installed bundle"
  for v in "${VERBS[@]}"; do
    # shellcheck disable=SC2086 # word-splitting the space-separated list IS the call
    in_list "$v" $DENY   && continue
    # shellcheck disable=SC2086
    in_list "$v" $WAIVED && continue
    vrc=$(verb_help_rc "$v")
    if [[ "$vrc" == "0" ]]; then
      ok_t "T4 5dive $v --help (rc 0)"
    elif [[ "$vrc" == "124" ]]; then
      bad_t "T4 5dive $v --help" "timed out after 30s — the verb ignores --help and blocks (an interactive prompt or a poll)"
    else
      bad_t "T4 5dive $v --help" "rc=$vrc — a shipped verb with no reachable usage text. If this verb never had one, add it; do not extend WAIVED, which is a frozen 2026-09-09 baseline."
    fi
  done
fi

# ---------------------------------------------------------------------------
# T5 — the waiver is self-retiring
# ---------------------------------------------------------------------------
# Without this, WAIVED is a place defects go to be forgotten: a verb fixed
# upstream would stay waived forever, and a verb DELETED would leave a stale
# entry that quietly excuses a future verb of the same name.
if (( ${#VERBS[@]} >= 40 )); then
  for v in $WAIVED; do
    if ! in_list "$v" "${VERBS[@]}"; then
      bad_t "T5 waiver $v is live" "'$v' is waived but is no longer a verb in the dispatch table — remove it from WAIVED"
      continue
    fi
    vrc=$(verb_help_rc "$v")
    if [[ "$vrc" == "0" ]]; then
      bad_t "T5 waiver $v is still needed" "'$v' now answers --help correctly — remove it from WAIVED so the fix is held"
    else
      ok_t "T5 waiver $v still describes a real gap (rc $vrc)"
    fi
  done
fi

echo
echo "install contract: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
exit 0
