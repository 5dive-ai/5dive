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
#   * #808 — the `distribution` team template was in the team index but not in
#     install.sh's staging list, so `team import distribution` resolved to
#     nothing on a real box while every unit test passed. (DIVE-4196 deleted
#     that staging list: templates now come from the registry. The arm below is
#     re-pointed at the registry and still grades the same question — every
#     advertised slug resolves on a fresh box.)
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
#   * plugins   <- the REGISTRY's .claude-plugin/marketplace.json
#                  (5dive-ai/5dive-plugins, mounted at $MANIFEST_DIR). DIVE-4202
#                  moved the last two plugins out of this repo, so the manifest
#                  that would drift is the registry's, not ours: a plugin
#                  PUBLISHED there is graded on a fresh box the day it lands,
#                  with no edit here and no CLI release.
#   * templates <- the LIVE registry index, <org>/5dive-marketplace teams/index.json,
#                  fetched inside the container (DIVE-4196). Same move, one repo
#                  over. It is FETCHED rather than mounted because the registry
#                  is now the only declaration there is: mounting a checkout copy
#                  would grade a file no customer reads. This arm is therefore
#                  ONLINE by design, and a fetch failure is a FAIL, never a skip
#                  — "could not ask" must not report as "clean".
#   * verbs     <- the INSTALLED BUNDLE's own dispatch table. Not src/main.sh:
#                  reading the artifact means a verb that exists in source but
#                  did not survive build.sh is a red, not a blind spot.
#
# THE SOURCE OF TRUTH IS THE PUBLISHER'S SIDE ON PURPOSE. The manifests are
# mounted from outside the box, never read out of $LIB_DIR or out of the clone
# the box made for itself. Reading the box's own copy would make the box its own
# examiner: a plugin the box failed to fetch would simply not be enumerated, and
# #808 would pass again. For plugins that outside copy is the registry's
# published manifest; for templates it is the registry index fetched over the
# network inside the container — neither is read out of $LIB_DIR.
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
#     -v $PWD/5dive-plugins-marketplace.json:/manifests/marketplace.json:ro \
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
# Measured 2026-09-09 on 278c3879, as root: these spellings answer `--help`
# with a usage ERROR (rc 2), not usage text. They are pre-existing defects, not
# regressions from this change, and fixing 15 argument parsers inside the PR
# that adds the check would make the check unreviewable. They are waived HERE,
# enumerated, and T5 makes the waiver SELF-RETIRING: a waived verb that starts
# answering --help correctly turns this harness RED until it is removed from
# this list, so the baseline can only shrink. A verb added to the CLI after
# today is asserted by T4 with no waiver available.
# `account` came off this list on 2026-09-19: `5dive account --help` had no help
# arm at all and answered "unknown account command: --help", and the change that
# gave `agent`/`account` subverbs their `--help` gave the surface one too. T5 is
# what required it to come off here in the same PR — which is the point of a
# self-retiring waiver.
WAIVED='activity buzz cost deploy doctor gate-proof host objective objectives project projects push trace usage'

in_list() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

# `5dive <verb> --help` with a bounded timeout, stdin closed (an interactive
# wizard that ignored --help would otherwise park the job until the workflow
# timeout, which reads as a hang rather than a red).
#
# DIVE-4430: stderr used to go to /dev/null, so in fourteen months this check
# has never once printed WHY a verb exits non-zero — only that it did. Two
# people then failed to reproduce it at a desk (rc 0 for both, as this user and
# as the container's root) and had nothing to go on but the number. The stderr
# is now captured to $HELP_ERR and its first lines are quoted back in the
# failure message.
#
# THIS IS ADDITIVE DIAGNOSTICS, NOT A RELAXED CHECK, and the distinction is the
# whole reason it is allowed to land in the PR it diagnoses: the assertion is
# byte-for-byte the same (rc 0 or the verb is red), the DENY list is unchanged,
# and WAIVED is still the frozen 2026-09-09 baseline with T5 still retiring it.
# Nothing that passed before passes now, and nothing that failed before passes.
HELP_ERR="${TMPDIR:-/tmp}/install-contract-help-err.$$"
verb_help_rc() {
  : >"$HELP_ERR" 2>/dev/null || HELP_ERR=/dev/null
  timeout 30 "$FIVE" "$1" --help </dev/null >/dev/null 2>"$HELP_ERR"
  printf '%s' "$?"
}

# shellcheck disable=SC2120 # the default IS the call; the arg is for a future caller
# The first $1 (default 6) lines of stderr from the LAST verb_help_rc call,
# flattened onto one line so it survives the summary formatting. Call it
# immediately after verb_help_rc — the next call truncates the file.
help_err_tail() {
  local n="${1:-6}"
  [[ -s "$HELP_ERR" ]] || { printf 'stderr: (empty — the verb exited quietly)'; return 0; }
  printf 'stderr: '
  head -n "$n" "$HELP_ERR" \
    | tr -d '\r' \
    | sed -e 's/[[:cntrl:]]/ /g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | cut -c1-400 \
    | awk 'NF{ printf "%s%s", (c++ ? " | " : ""), $0 } END{ if(!c) printf "(whitespace only)" }'
  local lines; lines=$(wc -l <"$HELP_ERR" 2>/dev/null || printf 0)
  (( lines > n )) && printf ' | …+%s more line(s)' "$(( lines - n ))"
  return 0
}

echo "=== install contract: $($FIVE --version 2>&1 | head -1) ==="

# ---------------------------------------------------------------------------
# T1/T2 — every plugin THE REGISTRY PUBLISHES installs, and its verb dispatches
# ---------------------------------------------------------------------------
# DIVE-4202: enumerated from 5dive-ai/5dive-plugins' marketplace.json. There is
# no longer a bundled plugin dir on the box to compare against — `5dive plugin`
# registers the registry itself on first use, so the precondition this asserts
# is "the box could reach the registry and it offers this plugin", which is the
# customer's actual first step.
MARKET="$MANIFEST_DIR/marketplace.json"
STATE="${FIVE_STATE_DIR:-/var/lib/5dive}"
if [[ ! -f "$MARKET" ]]; then
  bad_t "T1 preconditions" "registry manifest not mounted at $MARKET"
else
  mapfile -t PLUGINS < <(jq -r '.plugins[].name' "$MARKET")
  (( ${#PLUGINS[@]} > 0 )) || bad_t "T1 preconditions" "registry marketplace.json declares no plugins"

  # THE BUILT-IN CHANNEL PLUGINS ARE NOT BOX-INSTALLABLE, AND THAT IS BY DESIGN.
  #
  # DIVE-4202 iteration 2. The old bundled manifest was [voice, browser] and
  # held no channel plugin, so enumerating it and running `plugin add` on every
  # member was sound. The REGISTRY's manifest also publishes telegram, dashboard
  # and buzz — installed per AGENT, never per box — and `plugin add` refuses
  # them (cmd_plugin.sh _plugin_is_builtin_channel, rc E_USAGE). Repointing the
  # enumerator inherited the new source's population: T1b went red on three
  # members whose refusal is the product working.
  #
  # So the same filter the corpus harnesses apply is applied here, and it is
  # read from the CLI UNDER TEST rather than re-typed: the installed bundle's
  # own FIVEDIVE_CHANNEL_PLUGINS_JSON is the single place that set is declared
  # (header.sh says "never re-type the list"). A channel added there tomorrow
  # is filtered here with no edit to this file.
  #
  # Filtered OUT of T1b/T2, not dropped: T1c below asserts each one is REFUSED,
  # with the refusal's own reason, so "not installable per box" is graded rather
  # than assumed. And the surviving set is asserted non-empty, so this filter
  # can never turn the install arms vacuous — a registry that published nothing
  # but channels would fail here, loudly, instead of passing having run nothing.
  CHANNELS_JSON=$(sed -n "s/^readonly FIVEDIVE_CHANNEL_PLUGINS_JSON='\\(.*\\)'[[:space:]]*$/\\1/p" "$FIVE" | head -1)
  CHANNELS=()
  if [[ -n "$CHANNELS_JSON" ]] && jq -e . <<<"$CHANNELS_JSON" >/dev/null 2>&1; then
    mapfile -t CHANNELS < <(jq -r '.[].plugin' <<<"$CHANNELS_JSON")
  fi
  if (( ${#CHANNELS[@]} > 0 )); then
    ok_t "T1 preconditions: built-in channel set read from the installed CLI (${CHANNELS[*]})"
  else
    bad_t "T1 preconditions: built-in channel set read from the installed CLI" \
      "could not read FIVEDIVE_CHANNEL_PLUGINS_JSON out of $FIVE — without it the filter below is a no-op and T1b would grade plugins 'plugin add' refuses by design"
  fi

  INSTALLABLE=(); CHANNEL_MEMBERS=()
  for p in "${PLUGINS[@]}"; do
    if in_list "$p" "${CHANNELS[@]}"; then CHANNEL_MEMBERS+=("$p"); else INSTALLABLE+=("$p"); fi
  done
  if (( ${#INSTALLABLE[@]} > 0 )); then
    ok_t "T1 preconditions: ${#INSTALLABLE[@]} box-installable plugin(s) after the built-in channels are dropped (${INSTALLABLE[*]})"
  else
    bad_t "T1 preconditions: at least one box-installable plugin survives the filter" \
      "the registry publishes ${#PLUGINS[@]} plugin(s) and every one of them is a built-in channel — the T1b/T2 install arms below would run on nothing and pass vacuously"
  fi
  # One plugin verb first, so the registry is registered (and cloned) once
  # before the per-plugin arms read out of the clone.
  timeout 120 "$FIVE" plugin marketplace list </dev/null >/dev/null 2>&1
  # T1c — the filtered-out members, graded on the refusal rather than skipped.
  for p in "${CHANNEL_MEMBERS[@]}"; do
    out=$(timeout 120 "$FIVE" plugin add "$p" --yes </dev/null 2>&1); rc=$?
    if (( rc != 0 )) && printf '%s' "$out" | grep -qi "built-in channel"; then
      ok_t "T1c $p: 'plugin add' refuses a built-in channel plugin, per agent not per box (rc=$rc)"
    else
      bad_t "T1c $p: 'plugin add' refuses a built-in channel plugin" "rc=$rc — $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
  done

  # ------------------------------------------------------------------------
  # DIVE-4713 — SPLIT THE INSTALLABLE SET BY THE TIER EACH PLUGIN DECLARES
  # ------------------------------------------------------------------------
  # The loop below used to demand rc 0 from EVERY box-installable plugin the
  # registry publishes. That asserted an OUTCOME the registry decides, not a
  # property this repo owns: `_plugin_trust_gate` installs a plugin only if the
  # plugin's OWN manifest declares fivedive.trust.review == "official", and the
  # catalogue and that allowlist were equal by COINCIDENCE. When
  # 5dive-ai/5dive-plugins@a609407 published `mod` (2026-09-20T15:55:49Z) with
  # no `fivedive` block, T1b demanded an install the product is SUPPOSED to
  # refuse, and install-smoke went red on every branch of this repo — including
  # four whose whole diff was README text. The 15:04Z run was green; nothing
  # here changed between them. Same generator as DIVE-4708's two corpus
  # harnesses, third site; found while grading that row.
  #
  # The fix is DIVE-4708's, applied here: grade the RELATIONSHIP, not the
  # outcome. A box-installable plugin installs IF AND ONLY IF its own manifest
  # declares `official`. Publishing a plugin then moves a name between the two
  # buckets and can no longer move the verdict — plugin #7 is covered the day it
  # lands, whichever tier it carries, with no edit here.
  #
  # NOT a skip-list. `mod` is named nowhere below; it lands in UNREVIEWED
  # because of what its manifest says, and it is GRADED there — refused, with
  # the refusal's own wording, and with nothing left behind on disk. A name-
  # based skip would be the generator wearing a hat: it re-arms on the next
  # publish and it stops grading a plugin we ship.
  #
  # THE TIER IS READ FROM THE PUBLISHER, not from the box's clone, for the
  # reason at the top of this file: read the box's own copy and the box becomes
  # its own examiner. The marketplace manifest mounted at $MARKET does not carry
  # the tier (it carries name/source/description), so each plugin's own
  # manifest is fetched from the same publisher, over the network, inside the
  # container — exactly what T3 does with the team index, and for the same
  # reason a fetch failure there is a FAIL and never a skip. That also buys a
  # third fact for free: a box whose clone is stale relative to the publisher
  # now reads as a red on T1b/T1e rather than as agreement with itself.
  PUB_RAW="${FIVE_PLUGIN_MANIFEST_BASE:-https://raw.githubusercontent.com/${FIVE_GH_ORG:-5dive-ai}/5dive-plugins/main}"

  # <plugin> -> the directory its PUBLISHER declares it lives in. The index is
  # the only thing that says where a plugin is; $REGISTRY/plugins/<name> is a
  # guess that happens to be right today.
  _psrc() {
    local s; s=$(jq -r --arg p "$1" '.plugins[] | select(.name==$p) | .source // ""' "$MARKET" 2>/dev/null)
    s="${s#./}"; [[ -n "$s" ]] || s="plugins/$1"
    printf '%s' "$s"
  }

  OFFICIAL=(); UNREVIEWED=(); UNKNOWN_TIER=()
  for p in "${INSTALLABLE[@]}"; do
    pj=$(mktemp); purl="$PUB_RAW/$(_psrc "$p")/.claude-plugin/plugin.json"
    if curl -fsSL --max-time 30 "$purl" -o "$pj" 2>/dev/null && jq -e . "$pj" >/dev/null 2>&1; then
      tier=$(jq -r '.fivedive.trust.review // "unreviewed"' "$pj")
      ok_t "T1d $p: the publisher's own manifest declares review tier '$tier'"
      if [[ "$tier" == official ]]; then OFFICIAL+=("$p"); else UNREVIEWED+=("$p"); fi
    else
      UNKNOWN_TIER+=("$p")
      bad_t "T1d $p: read the publisher's own manifest for its review tier" \
        "could not fetch or parse $purl — NOT a skip: without the tier this harness cannot say what 'plugin add $p' is supposed to do, and assuming one is how the catalogue/allowlist coincidence came back"
    fi
    rm -f "$pj"
  done

  # Two floors, so neither half of the split can go quietly vacuous.
  if (( ${#OFFICIAL[@]} > 0 )); then
    ok_t "T1 preconditions: ${#OFFICIAL[@]} official plugin(s) to install (${OFFICIAL[*]}), ${#UNREVIEWED[@]} to refuse (${UNREVIEWED[*]:-none})"
  else
    bad_t "T1 preconditions: at least one box-installable plugin declares 'official'" \
      "every box-installable plugin the registry publishes is unreviewed — the T1b/T2 install arms would run on nothing and pass vacuously, which is what a registry-wide loss of the trust block looks like"
  fi
  if (( ${#OFFICIAL[@]} + ${#UNREVIEWED[@]} + ${#UNKNOWN_TIER[@]} == ${#INSTALLABLE[@]} )); then
    ok_t "T1 preconditions: every box-installable plugin landed in exactly one tier bucket (${#INSTALLABLE[@]})"
  else
    bad_t "T1 preconditions: every box-installable plugin landed in exactly one tier bucket" \
      "${#INSTALLABLE[@]} installable, $(( ${#OFFICIAL[@]} + ${#UNREVIEWED[@]} + ${#UNKNOWN_TIER[@]} )) bucketed — a plugin that falls out of both loops is ungraded, not passing"
  fi

  # What the box actually did, accumulated across BOTH loops and compared
  # against what the publishers declared, in T1e.
  _inst=(); _ref=()

  for p in "${OFFICIAL[@]}"; do
    # Resolve the plugin's directory inside the REGISTERED clone the same way
    # the CLI does: the manifest's own `source`, relative to the clone root.
    psrc=$(_psrc "$p")
    offered="$STATE/plugins/marketplaces/5dive-plugins/$psrc/.claude-plugin/plugin.json"
    if [[ -f "$offered" ]]; then
      ok_t "T1a $p: offered by the registry on the box at $offered"
    else
      bad_t "T1a $p: offered by the registry on the box" "no manifest at $offered — the box did not get this plugin from 5dive-ai/5dive-plugins, so it is published and not installable here"
      continue
    fi

    out=$(timeout 120 "$FIVE" plugin add "$p" --yes </dev/null 2>&1); rc=$?
    if (( rc == 0 )); then
      ok_t "T1b $p: 5dive plugin add $p --yes"
      _inst+=("$p")
    else
      bad_t "T1b $p: 5dive plugin add $p --yes" "rc=$rc — $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
      _ref+=("$p")
      continue
    fi

    # A plugin declaring the `verb` capability adds a top-level command. Installed
    # but undispatchable is the same class of defect as uninstallable, so grade
    # the dispatch rather than trusting the install's exit code.
    mapfile -t pverbs < <(jq -r '.fivedive.verbs[]?.name // empty' "$offered")
    for v in "${pverbs[@]}"; do
      vrc=$(verb_help_rc "$v")
      if [[ "$vrc" == "0" ]]; then
        ok_t "T2 $p: 5dive $v --help dispatches (rc 0)"
      else
        bad_t "T2 $p: 5dive $v --help dispatches" "rc=$vrc — the plugin installed but its declared verb does not run. $(help_err_tail)"
      fi
    done
  done

  # T1e/T1f — NEGATIVE CONTROL. Without these arms the split above reads as
  # "stop grading the plugins that fail", which is the forbidden shape: the
  # unreviewed half is still a population and its EXPECTED behaviour is still
  # graded. Vacuous while the registry publishes only official plugins, and that
  # is correct — there is then nothing to refuse.
  for p in "${UNREVIEWED[@]}"; do
    out=$(timeout 120 "$FIVE" plugin add "$p" --yes </dev/null 2>&1); rc=$?
    if (( rc != 0 )); then
      ok_t "T1e $p: 'plugin add' is REFUSED — the plugin declares no 'official' review (rc=$rc)"
      _ref+=("$p")
    else
      bad_t "T1e $p: 'plugin add' is REFUSED — the plugin declares no 'official' review" \
        "rc=0 — an unreviewed plugin installed on a fresh box. The trust gate is the only thing between a published plugin and root on a customer's box."
      _inst+=("$p")
    fi
    if printf '%s' "$out" | grep -q "installs only 'official'"; then
      ok_t "T1e2 $p: the refusal names the review tier, not something internal"
    else
      bad_t "T1e2 $p: the refusal names the review tier, not something internal" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
    # rc alone is not enough: a refusal that had already copied the tree would
    # pass T1e. Read the registry the dispatcher reads.
    inst_json="$STATE/plugins/installed.json"
    left=$(jq -r --arg p "$p" '[to_entries[] | select(.key == $p or (.key | startswith($p + "@"))) | .value.enabled // true] | any' "$inst_json" 2>/dev/null)
    if [[ "$left" == "false" || -z "$left" || "$left" == "null" ]]; then
      ok_t "T1f $p: the refused install left NO record behind in installed.json"
    else
      bad_t "T1f $p: the refused install left NO record behind in installed.json" "$inst_json records it as enabled — 'plugin add' refused and copied anyway"
    fi
  done

  # T1g — THE RELATIONSHIP ARM, and the one that actually disarms the generator.
  # Not "the catalogue installs" (a third repository decides that) but
  # "installing and being official are the same set" (this repository decides
  # that). It is also what stops the split above degenerating: "install
  # everything" and "refuse everything" are each red here, and a plugin that
  # fell out of both loops shows up as a missing name.
  #
  # A biconditional over an INCOMPLETE population is not a verdict: if any
  # plugin's tier could not be read, both sides can be empty and this arm would
  # agree with itself. Measured — with the publisher unreachable it read
  # `install=[] refuse=[]` and passed. So the unknowns fail it explicitly rather
  # than being quietly excluded from the claim.
  t1g_want="install=[${OFFICIAL[*]}] refuse=[${UNREVIEWED[*]}]"
  t1g_got="install=[${_inst[*]}] refuse=[${_ref[*]}]"
  if (( ${#UNKNOWN_TIER[@]} > 0 )); then
    bad_t "T1g a box-installable plugin installs IFF its own manifest declares 'official'" \
      "not graded — the publisher's tier is unknown for ${UNKNOWN_TIER[*]}, so this arm's population is incomplete and would agree with itself (see the T1d failure above)"
  elif [[ "$t1g_want" == "$t1g_got" ]]; then
    ok_t "T1g a box-installable plugin installs IFF its own manifest declares 'official' ($t1g_want)"
  else
    bad_t "T1g a box-installable plugin installs IFF its own manifest declares 'official'" \
      "publishers declare $t1g_want — the box did $t1g_got"
  fi
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
# DIVE-4196 — fetched, not mounted: the registry IS the source of truth now.
# TEAM_REGISTRY_INDEX is overridable so a fork or a test can point it elsewhere.
TEAM_REGISTRY_INDEX="${TEAM_REGISTRY_INDEX:-https://raw.githubusercontent.com/${FIVE_GH_ORG:-5dive-ai}/5dive-marketplace/main/teams/index.json}"
INDEX="$(mktemp)"
if ! curl -fsSL --max-time 30 "$TEAM_REGISTRY_INDEX" -o "$INDEX" \
   || ! jq -e '.companies | type == "array" and length > 0' "$INDEX" >/dev/null 2>&1; then
  rm -f "$INDEX"; INDEX="/nonexistent-registry-index"
fi
if [[ ! -f "$INDEX" ]]; then
  bad_t "T3 preconditions" "could not read the team registry index at $TEAM_REGISTRY_INDEX (fetch failed or malformed). NOT a skip: an unreadable registry is exactly what a customer's failed import looks like."
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
      bad_t "T3a $s: 5dive team ps $s" "rc=$rc — $(printf '%s' "$out" | tail -3 | tr '\n' ' ') (a slug the registry advertises that the installed CLI cannot resolve looks exactly like this — #808)"
      continue
    fi
    ok_t "T3a $s: template resolves and parses on the installed box"
    got=$(printf '%s' "$out" | jq -r '.data.agents | length' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
      ok_t "T3b $s: roster is $got agents, matching the registry"
    else
      bad_t "T3b $s: roster matches the registry" "registry says $want agents, the fetched spec parses to ${got:-<unparseable>} — the two halves of one template have drifted"
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
      bad_t "T4 5dive $v --help" "timed out after 30s — the verb ignores --help and blocks (an interactive prompt or a poll). $(help_err_tail)"
    else
      bad_t "T4 5dive $v --help" "rc=$vrc — a shipped verb with no reachable usage text. If this verb never had one, add it; do not extend WAIVED, which is a frozen 2026-09-09 baseline. $(help_err_tail)"
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

# ---------------------------------------------------------------------------
# T6 — DIVE-4128: the per-box shared team wiki, graded by EXECUTION
# ---------------------------------------------------------------------------
# The row's VERIFY section asks for a FRESH BOX: `memory add --store=wiki`
# succeeds, a SECOND SEAT can search what the first published, and the negative
# arm (no root anywhere -> the refusal says why). None of that is producible on
# our own fleet: `_memory_wiki_root`'s last fallback
# /home/claude/projects/5dive/community/wiki is hardcoded and EXISTS there, so a
# fleet box cannot make the absent-root state at all, and the 2775 root:claude
# modes need an installer running as root. This container is the fresh box —
# install.sh has just run against ubuntu:22.04 as root and there is no
# community/wiki checkout on it.
#
# The arms below therefore grade the two halves a unit suite structurally
# cannot: the REAL mode bits the installer produced, and two REAL unprivileged
# seats sharing knowledge through them.
#
# NOT covered here, stated rather than implied: `agent create
# --inherit-memory=wiki` seeding N>0 and printing N. Creating an agent needs a
# credential this container has none of. That path is graded by execution in
# tests/shared_wiki_root_unit.sh, which calls the real `_seed_wiki_memory`
# against populated / empty / absent roots and was mutation-graded (silencing
# the absent-root warn reds 2 arms).
WIKI_ROOT=/var/lib/5dive/wiki

if [[ ! -d "$WIKI_ROOT" ]]; then
  bad_t "T6a the installer provisioned the shared team wiki" \
        "$WIKI_ROOT is not a directory on a box install.sh has just run against — every seat's atoms stay private and 'memory add --store=wiki' refuses"
else
  ok_t "T6a the installer provisioned the shared team wiki at $WIKI_ROOT"

  # Exact bits, not an installer 'ok' line. setgid keeps a page written by any
  # seat in group claude; g+w is what makes every seat a PUBLISHER rather than
  # a reader; root:claude is the ownership the resolver's consumers assume.
  got=$(stat -c '%a %U:%G' "$WIKI_ROOT" 2>/dev/null || echo "unreadable")
  if [[ "$got" == "2775 root:claude" ]]; then
    ok_t "T6b $WIKI_ROOT is 2775 root:claude (setgid + group-writable)"
  else
    bad_t "T6b $WIKI_ROOT is 2775 root:claude" "stat says '$got' — expected '2775 root:claude'"
  fi

  # `memory add` deliberately never invents an index, so without this seed the
  # first page published on a fresh box is written and then never listed.
  if [[ -f "$WIKI_ROOT/index.md" ]]; then
    imode=$(stat -c '%a' "$WIKI_ROOT/index.md" 2>/dev/null || echo "?")
    if [[ "$imode" == "664" ]]; then
      ok_t "T6c the seeded index.md is present and group-writable (664)"
    else
      bad_t "T6c the seeded index.md is group-writable" "mode $imode — the second publisher's index append will be refused"
    fi
  else
    bad_t "T6c the installer seeded an index.md" "absent — the first page published here is never listed"
  fi

  # --- two REAL unprivileged seats, which is the whole point of a team wiki ---
  if ! getent group claude >/dev/null 2>&1; then
    bad_t "T6d group 'claude' exists" "absent — the shared wiki has no group to share through"
  else
    seat_rc=0
    id -u wikiseat_a >/dev/null 2>&1 || useradd -m -G claude wikiseat_a >/dev/null 2>&1 || seat_rc=1
    id -u wikiseat_b >/dev/null 2>&1 || useradd -m -G claude wikiseat_b >/dev/null 2>&1 || seat_rc=1
    if (( seat_rc != 0 )); then
      bad_t "T6d two unprivileged seats can be created" "useradd failed; the second-seat arms cannot run"
    else
      as_seat() { # <user> <command-string>  (body, if any, on stdin)
        su -s /bin/bash "$1" -c "$2"
      }

      # (1) fresh box -> `memory add --store=wiki` SUCCEEDS as a non-root seat.
      addout=$(printf 'A page published by the first seat, to be found by the second.\n' \
        | as_seat wikiseat_a "$FIVE memory add --store=wiki --name=contract-probe-seat-a \
            --description='install-contract probe: seat A publishes to the shared team wiki'" 2>&1)
      arc=$?
      if (( arc == 0 )) && [[ -f "$WIKI_ROOT/contract-probe-seat-a.md" ]]; then
        ok_t "T6d a non-root seat publishes to the shared wiki (memory add --store=wiki, rc 0)"
      else
        bad_t "T6d a non-root seat publishes to the shared wiki" "rc=$arc out=$(tr '\n' ' ' <<<"$addout" | cut -c1-300)"
      fi

      # setgid doing its job: the page seat A wrote carries the SHARED group,
      # not seat A's private one. Without it the wiki de-shares itself one page
      # at a time and the failure surfaces as a permission error on some later
      # seat's edit, which nobody connects back to here.
      if [[ -f "$WIKI_ROOT/contract-probe-seat-a.md" ]]; then
        pg=$(stat -c '%G' "$WIKI_ROOT/contract-probe-seat-a.md" 2>/dev/null || echo "?")
        if [[ "$pg" == "claude" ]]; then
          ok_t "T6e a page written by seat A keeps group 'claude' (setgid held)"
        else
          bad_t "T6e a page written by seat A keeps group 'claude'" "group is '$pg' — the wiki de-shares itself page by page"
        fi
      fi

      # (2) A SECOND SEAT CAN SEARCH IT. This is the row's headline claim and
      # the one thing no unit arm on a fleet box can stand in for.
      sout=$(as_seat wikiseat_b "$FIVE memory search --store=wiki 'install-contract probe seat A publishes'" 2>&1)
      src=$?
      if (( src == 0 )) && grep -q 'contract-probe-seat-a' <<<"$sout"; then
        ok_t "T6f a SECOND seat searches the wiki and finds what the first published"
      else
        bad_t "T6f a SECOND seat searches the wiki and finds what the first published" \
              "rc=$src out=$(tr '\n' ' ' <<<"$sout" | cut -c1-300)"
      fi

      # (3) The second writer. A shared wiki that is write-once per author is a
      # set of private pages in one directory: seat B must be able to append the
      # index seat A just wrote into.
      bout=$(printf 'A page published by the second seat.\n' \
        | as_seat wikiseat_b "$FIVE memory add --store=wiki --name=contract-probe-seat-b \
            --description='install-contract probe: seat B publishes after seat A'" 2>&1)
      brc=$?
      if (( brc == 0 )) && grep -q 'contract-probe-seat-b' "$WIKI_ROOT/index.md" 2>/dev/null; then
        ok_t "T6g seat B publishes too and its line reaches the index seat A wrote into"
      else
        bad_t "T6g seat B publishes too and its line reaches the shared index" "rc=$brc out=$(tr '\n' ' ' <<<"$bout" | cut -c1-300)"
      fi

      # (4) THE NEGATIVE ARM — the defect this row exists to remove. With no
      # wiki root anywhere, the old code refused with a path the operator could
      # not create, and the seeding path reported success. Producible only here:
      # a fleet box always has the hardcoded community/wiki fallback.
      mv "$WIKI_ROOT" "${WIKI_ROOT}.contract-off" 2>/dev/null || true
      nout=$(printf 'x\n' | as_seat wikiseat_a "$FIVE memory add --store=wiki --name=contract-probe-noroot \
            --description='install-contract probe: must be refused when no root exists'" 2>&1)
      nrc=$?
      mv "${WIKI_ROOT}.contract-off" "$WIKI_ROOT" 2>/dev/null || true
      if (( nrc != 0 )); then
        ok_t "T6h with no wiki root anywhere, 'memory add --store=wiki' REFUSES (rc $nrc)"
      else
        bad_t "T6h with no wiki root anywhere, 'memory add --store=wiki' refuses" "it exited 0 — a publish that went nowhere reported success"
      fi
      # The refusal must name the root the operator can actually get, and how to
      # get it. The pre-DIVE-4128 message named `community/wiki`, a path that
      # exists only on our fleet and that no customer can create.
      if grep -q '/var/lib/5dive/wiki' <<<"$nout" && grep -qi 'installer' <<<"$nout"; then
        ok_t "T6i the refusal names /var/lib/5dive/wiki and the installer as the fix"
      else
        bad_t "T6i the refusal names /var/lib/5dive/wiki and the installer as the fix" \
              "out=$(tr '\n' ' ' <<<"$nout" | cut -c1-300)"
      fi

      rm -f "$WIKI_ROOT/contract-probe-seat-a.md" "$WIKI_ROOT/contract-probe-seat-b.md"
    fi
  fi
fi

echo
echo "install contract: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
exit 0
