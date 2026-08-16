#!/usr/bin/env bash
# DIVE-2766 isolated unit harness for agent_channels_binding (cmd_agent.sh) and
# for the `channels:`/`bound:` render program `agent info` prints from it.
#
# The property under test is NOT "does it spot a refused channel". It is: can
# this surface ever report a state a BOUND agent and an UNPROBED agent SHARE?
# That is the whole defect — `channels: telegram,dashboard (@bot)` printed beside
# `state: active` on a box where every channel had been refused, which sent the
# triage of four consecutive red telegram-roundtrip-openrouter runs at credential
# routing (community/wiki/the-channels-gate-is-inside-claude-code-not-our-plugin-staging.md).
# So the arms below deliberately include the three "nothing visibly wrong" shapes
# that must NOT collapse into each other: nothing-declared, probed-clean, and
# could-not-probe. A clean capture reporting anything but `unknown` rebuilds the
# ticket one layer down, and §3 is the arm that grades it.
#
# `sudo` and `tmux` are stubbed, so this runs with no root, no tmux and no agent.
# Run: bash tests/agent_info_channels_binding_unit.sh
#
# GRADED BY MUTATION on this box (control plane, not CI), 2026-08-16, against 38
# passing — nine mutations of src/cmd_agent.sh, each applied alone:
#   clean capture reports "bound" instead of unknown ....... 2 red
#   no-session branch reports "bound" ...................... 1 red
#   measured: true for every non-n/a state ................. 1 red
#   refusal grep pinned to one sentence, not the family .... 3 red
#   `Channels are not ` preference dropped (first match) ... 1 red
#   `|`-strip dropped from the evidence line ............... 1 red
#   DECLARED suffix dropped from the channels: line ........ 1 red
#   refused WARNING block dropped .......................... 1 red
#   n/a arm emits a bound: line ............................ 1 red
# TWO SURVIVORS on the first pass, both reported and both closed rather than
# papered over, because each named a real hole:
#   - `measured` survived §1-§5 entirely. A render-only harness cannot see the
#     object program that feeds it, so §6 was added.
#   - the `|`-strip survived an assertion that the evidence contained no `|`:
#     ${##*|} keeps the tail after the last separator, so a TRUNCATED banner
#     still parses clean. §2.3 now asserts the whole string.
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"
  fi
}
tc() {  # <desc> <needle> <haystack> — contains
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual:              $3"
  fi
}
tnc() { # <desc> <needle> <haystack> — does NOT contain
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual:                  $3"
  fi
}

# The probe under test, lifted out of cmd_agent.sh so no state/registry/systemd
# machinery has to boot. Extracted by name rather than pasted: a copy would grade
# the copy, which is the failure mode this comment exists to prevent.
fnsrc=$(sed -n '/^agent_channels_binding() {/,/^}/p' "$SRC/cmd_agent.sh")
[[ -n "$fnsrc" ]] || { echo "FAIL: could not extract agent_channels_binding from $SRC/cmd_agent.sh"; exit 1; }
eval "$fnsrc"

# Stubbed privilege + tmux. SESSION says whether has-session succeeds; PANE is
# what capture-pane emits. Every real caller of this function reaches tmux only
# through these two verbs.
SESSION=yes; PANE=""
sudo() {
  case "$*" in
    *has-session*)   [[ "$SESSION" == "yes" ]] ;;
    *capture-pane*)  printf '%s\n' "$PANE" ;;
    *)               return 1 ;;
  esac
}

st() { printf '%s' "${1%%|*}"; }                       # state field
de() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }    # detail field
ev() { printf '%s' "${1##*|}"; }                       # evidence field

# ---- §1 refused: positive evidence, every branch of the gate ---------------
# The binary picks between several `Channels are not …` endings and gained a new
# one between 2.1.222 and 2.1.233, so the arms cover the FAMILY. A probe pinned
# to one sentence goes quietly blind on a coding-CLI upgrade, and quiet is the
# entire complaint on this ticket.
SESSION=yes
PANE=$'boot\n ▎ --channels ignored (plugin:telegram@5dive-plugins, plugin:dashboard@5dive-plugins)\n ▎ Channels are not currently available\n> '
r=$(agent_channels_binding smoke-rt-or telegram,dashboard)
t  "1.1 the DIVE-2765 pane is refused"            "refused" "$(st "$r")"
tc "1.2 evidence names the BRANCH, not the ignore" "Channels are not currently available" "$(ev "$r")"

PANE=$'Channels are not enabled for your org (policy)'
t "1.3 org-policy branch is refused"      "refused" "$(st "$(agent_channels_binding x telegram)")"
PANE=$'Channels are not available on third-party providers'
t "1.4 third-party branch is refused"     "refused" "$(st "$(agent_channels_binding x telegram)")"
PANE=$'Channels are not available on Bedrock, Vertex, or Foundry'
t "1.5 provider branch is refused"        "refused" "$(st "$(agent_channels_binding x telegram)")"
# Only the ignore line, no second line: still a refusal, and the evidence has to
# fall back to it rather than reporting nothing.
PANE=$'--channels ignored (plugin:telegram@5dive-plugins)'
r=$(agent_channels_binding x telegram)
t  "1.6 ignore line alone is refused"     "refused" "$(st "$r")"
tc "1.7 falls back to the ignore line"    "--channels ignored" "$(ev "$r")"

# ---- §2 the field separator cannot be smuggled in from the pane -----------
# The three fields ride one `|`-delimited line, and the pane is attacker-shaped
# input in the weak sense that it is arbitrary terminal output. A banner
# containing `|` must not shift evidence into detail.
PANE='Channels are not currently available | tail | more'
r=$(agent_channels_binding x telegram)
t  "2.1 pipe-bearing banner still refused"     "refused" "$(st "$r")"
t  "2.2 detail field is not displaced"         "the session announced the channel gate" "$(de "$r")"
# Asserting only "the evidence contains no |" is NOT enough and the mutation pass
# proved it: without the substitution the last field still parses clean, because
# ${##*|} silently keeps the tail after the final pipe. The banner has to arrive
# WHOLE, so the arm asserts the whole string.
t   "2.3 the banner arrives whole, separators neutralised" \
    "Channels are not currently available   tail   more" "$(ev "$r")"
tnc "2.4 and carries no bare separator"        "|" "$(ev "$r")"

# ---- §3 the three quiet shapes, which must NOT collapse -------------------
# 3.1 is the arm this harness exists for: a clean capture is NOT a green. The
# banner prints at session start and rolls off the scrollback, so "no banner in
# the last 2000 lines" is silence, not confirmation
# (community/wiki/a-skipped-job-is-silence-not-a-green.md).
PANE=$'just some ordinary agent output\nnothing about channels here\n'
r=$(agent_channels_binding x telegram)
t   "3.1 probed-clean is unknown, never bound"  "unknown" "$(st "$r")"
tnc "3.2 and never says bound"                  "bound"   "$(st "$r")"
tc  "3.3 and says WHY it is not evidence"       "rolls off" "$(de "$r")"

PANE=""
t "3.4 empty capture is unknown"  "unknown" "$(st "$(agent_channels_binding x telegram)")"
tc "3.5 empty capture says which" "capture-pane returned nothing" "$(de "$(agent_channels_binding x telegram)")"

SESSION=no
r=$(agent_channels_binding x telegram)
t  "3.6 no readable session is unknown"     "unknown" "$(st "$r")"
tc "3.7 names the two causes it cannot separate" "not running, or this caller cannot read it" "$(de "$r")"
# Cannot-probe and probed-clean are both `unknown` on purpose — neither is
# evidence — but they have different remedies, so the DETAIL must differ.
SESSION=yes; PANE=$'ordinary output\n'
a=$(de "$(agent_channels_binding x telegram)"); SESSION=no
b=$(de "$(agent_channels_binding x telegram)")
if [[ "$a" != "$b" ]]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: 3.8 probed-clean and cannot-probe share a detail string"
fi

# ---- §4 nothing declared is its own state --------------------------------
# An agent with no channels has nothing to bind, and printing `bound: unknown`
# at it would manufacture a doubt about a seat that is fine.
SESSION=yes; PANE=$'Channels are not currently available'
for d in "" none null; do
  t "4.x declared '${d:-<empty>}' is n/a" "n/a" "$(st "$(agent_channels_binding x "$d")")"
done

# ---- §5 the render, which is the half a human actually reads -------------
# Extracted from the source the same way the function was.
render=$(sed -n '/^      "name:        .(.name)",$/,/^    . <<<"\$obj"$/p' "$SRC/cmd_agent.sh" | sed '$d')
[[ -n "$render" ]] || { echo "FAIL: could not extract the info render program"; exit 1; }
rec() { # rec <state> <evidence>
  jq -nc --arg s "$1" --arg e "$2" '{
    name:"a", type:"claude", cliName:"claude", cliVersion:"1", model:null, effort:null,
    modelUnpinnedWithCreds:false, channels:"telegram,dashboard", channelsDeclared:"telegram,dashboard",
    channelsBinding:{state:$s, measured:($s=="refused"), detail:"d", evidence:(if $e=="" then null else $e end)},
    botUsername:"b", authProfile:null, workdir:"/w", isolation:"admin", isolationLabelled:true,
    sudo:{measured:true,grant:"g",scope:"s",runas:"r",extraEntries:false,diverges:false},
    supervisor:{stateNote:"n",note:"o",line:"l",verdict:null}, createdAt:"t"}'
}
out=$(rec refused "Channels are not currently available" | jq -r "$render")
tc "5.1 the channels line says DECLARED"      "— DECLARED (registry)" "$out"
tc "5.2 a refused seat prints bound: NO"      "bound:       NO — REFUSED at runtime" "$out"
tc "5.3 with the banner beside it"            "Channels are not currently available" "$out"
tc "5.4 and warns that other lines look fine" "WARNING: this agent DECLARES channels" "$out"
tc "5.5 and names where the gate is"          "inside the coding-CLI binary" "$out"

out=$(rec unknown "" | jq -r "$render")
tc  "5.6 an unprobed seat prints bound: unknown" "bound:       unknown" "$out"
tnc "5.7 and never the word REFUSED"             "REFUSED" "$out"
tnc "5.8 and raises no warning"                  "WARNING: this agent DECLARES" "$out"

out=$(rec "n/a" "" | jq -r "$render")
tnc "5.9 a channel-less seat gets no bound: line" "bound:" "$out"
tnc "5.10 and no DECLARED suffix"                 "DECLARED (registry)" "$out"

# ---- §6 the JSON record, which is what the dashboard reads ---------------
# §5 grades the printed lines and CANNOT see the object program that feeds them
# — the coverage hole quinn measured on the DIVE-3274 detector
# (community/wiki/a-detectors-tests-can-grade-the-branch-and-not-the-read.md),
# and the hole this harness fell into on its first mutation pass: flipping
# `measured` to true for every non-n/a state survived §1–§5 at full green.
# `measured` is the field a consumer keys on to decide whether a value is a
# MEASUREMENT, so a true on `unknown` hands the dashboard in JSON the same false
# confidence the printed line used to hand a human.
cbprog=$(sed -n '/^      channelsBinding: {$/,/^      },$/p' "$SRC/cmd_agent.sh" | sed '$s/,$//')
[[ -n "$cbprog" ]] || { echo "FAIL: could not extract the channelsBinding object program"; exit 1; }
cb() { # cb <state> <detail> <evidence>
  jq -nc --arg cbState "$1" --arg cbDetail "$2" --arg cbEvidence "$3" "{ $cbprog }"
}
t "6.1 refused is measured"          "true"  "$(cb refused d e | jq -r '.channelsBinding.measured')"
t "6.2 unknown is NOT measured"      "false" "$(cb unknown d ''  | jq -r '.channelsBinding.measured')"
t "6.3 n/a is NOT measured"          "false" "$(cb "n/a" "" ""   | jq -r '.channelsBinding.measured')"
t "6.4 empty detail is null, not ''" "null"  "$(cb "n/a" "" ""   | jq -r '.channelsBinding.detail')"
t "6.5 empty evidence is null"       "null"  "$(cb unknown d ""  | jq -r '.channelsBinding.evidence')"
t "6.6 state rides through verbatim" "unknown" "$(cb unknown d "" | jq -r '.channelsBinding.state')"

echo "-- $PASS passed, $FAIL failed --"
(( FAIL == 0 ))
