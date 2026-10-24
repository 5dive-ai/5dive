#!/usr/bin/env bash
# DIVE-6635: every claude seat is told how to reach its team, that its role is
# the one its instructions give it, that its owner has no terminal, that it may
# tell its owner its rules, and that a "can't" is checked twice before it is
# remembered. A lead with none of this used Claude Code's own ListAgents, saw
# nobody, saved "a teammate with no channel is unreachable" and worked alone.
#
#   (a) team-CLAUDE.md is one managed block and keeps each rule, including
#       DIVE-6639's: a 5dive failure that blocks work is offered to the owner
#       as a bug report, sent only on their yes;
#   (b) the reworded model-tiering file is the old one with exactly the two lines
#       the migration rewrites, so a migrated seat matches a new one;
#   (c) sync_seat_claudemd (read out of install.sh) appends the block once,
#       migrates the heading, replaces a drifted block in place, keeps every byte
#       outside it, writes through the seat's user, and never follows a symlink;
#   (d) create appends the block and install runs the sync over claude seats.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/team-block.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}" >&2; }
TEAM=prompts/team-CLAUDE.md

echo "# (a) the block"
[[ $(grep -c '^<!-- 5dive:team:begin' "$TEAM") == 1 && $(grep -c '^<!-- 5dive:team:end -->' "$TEAM") == 1 ]] \
  && ok "a1 one begin and one end marker" || bad "a1 markers" "$(grep -n '<!--' "$TEAM")"
has(){ grep -qF -- "$2" "$TEAM" && ok "a2 keeps: $1" || bad "a2 MUST keep: $1" "no '$2' in $TEAM"; }
has "teammates are listed by the CLI"         '`5dive agent list`'
has "teammates are reached by the CLI"        '`5dive agent send <name>'
has "no channel is no obstacle"               'no Telegram channel too'
has "CC's own tools are not the team"         'ListAgents, SendMessage'
has "role is not switched off by the model"   'on any model'
has "owner has no terminal"                   'owner has no terminal'
has "...so never hand them sudo"              '`sudo`'
has "rules are told on request"               'Asked how you work?'
has "...secrets never"                        'Never show a key, token or password'
has "a can't is checked twice"                'only after a second, different check'
has "a blocking 5dive failure is a bug"     'When 5dive itself blocks your work'
has "...offered, sent only on a yes"        '--file --owner-approved`; never send without it'
has "...never for cosmetic issues"          'Skip cosmetic issues'
if grep -nE 'DIVE-[0-9]+|\b20[0-9]{2}-[0-9]{2}-[0-9]{2}\b' "$TEAM" >"$TMP/x"; then bad "a3 no idents or dates in model-facing text" "$(head -2 "$TMP/x")"
else ok "a3 no idents or dates in model-facing text"; fi

echo "# (b) model tiering"
OLD_HEAD='# Model tiering (orchestrator + minions)'
OLD_LINE='Fable acts as the orchestrator: plan, decide'
grep -qF "orchestrator" prompts/model-tiering-CLAUDE.md && bad "b1 the new text never says orchestrator" "$(grep -n orchestrator prompts/model-tiering-CLAUDE.md)" \
  || ok "b1 the new text never says orchestrator"

eval "$(sed -n '/^sync_managed_block()/,/^}$/p; /^sync_seat_claudemd()/,/^}$/p' install.sh)" 2>/dev/null
declare -F sync_seat_claudemd >/dev/null && declare -F sync_managed_block >/dev/null \
  || { bad "install.sh must define sync_seat_claudemd and sync_managed_block"; printf '\n%d passed, %d failed\n' "$P" "$F"; exit 1; }
SUDO_LOG="$TMP/sudo.log"; : > "$SUDO_LOG"
sudo(){ [[ "$1" == -u ]] || return 9; printf '%s\n' "$2" >> "$SUDO_LOG"; shift 2; "$@"; }

# An old seat file: the telegram fragment, the OLD model-tiering text, comms.
OLDMT="$TMP/old-mt.md"
sed -e "s/^# Subagent model choice (Fable sessions only)\$/$OLD_HEAD/" \
    -e "s/^On Fable, plan, decide/$OLD_LINE/" prompts/model-tiering-CLAUDE.md > "$OLDMT"
grep -qxF "$OLD_HEAD" "$OLDMT" && grep -qF "$OLD_LINE" "$OLDMT" \
  || bad "b2 fixture" "the current file no longer carries the two lines the migration targets"
SEAT="$TMP/seat.md"
{ printf '# Telegram-paired agent\n\nReply every turn.\n\n'; cat "$OLDMT"; printf '\n# Working comms\n\nLead with the answer.\n'; } > "$SEAT"
cp "$SEAT" "$TMP/seat.orig"
sync_seat_claudemd "$SEAT" agent-maya "$TEAM"; rc=$?
(( rc == 0 )) && ok "b2 the sync succeeds on an old seat file" || bad "b2 sync rc=$rc"
grep -qF "$(cat prompts/model-tiering-CLAUDE.md)" "$SEAT" && ! grep -qF "orchestrator" "$SEAT" \
  && ok "b3 the migrated text equals the new model-tiering file byte for byte" \
  || bad "b3 migrated text differs from model-tiering-CLAUDE.md" "$(grep -n 'Model\|orchestrator\|Fable' "$SEAT" | head -4)"

echo "# (c) the seat sync"
[[ $(grep -c '^<!-- 5dive:team:begin' "$SEAT") == 1 ]] && grep -qF "$(cat "$TEAM")" "$SEAT" \
  && ok "c1 the block is appended once, whole" || bad "c1 block not appended" "$(tail -3 "$SEAT")"
grep -qx 'agent-maya' "$SUDO_LOG" && ok "c2 the write goes through the seat's own user" || bad "c2 write not via sudo -u agent-maya" "$(cat "$SUDO_LOG")"
grep -qF 'Reply every turn.' <<<"$(head -3 "$SEAT")" && grep -qF 'Lead with the answer.' "$SEAT" \
  && ok "c3 text outside the block is kept" || bad "c3 outside text lost"
cp "$SEAT" "$TMP/once"; : > "$SUDO_LOG"
sync_seat_claudemd "$SEAT" agent-maya "$TEAM"
cmp -s "$SEAT" "$TMP/once" && [[ ! -s "$SUDO_LOG" ]] && ok "c4 a second run changes nothing and writes nothing" \
  || bad "c4 not idempotent" "$(diff "$TMP/once" "$SEAT" | head -4)"
sed -i 's/only after a second, different check/whenever you like/' "$SEAT"; printf 'Own note after.\n' >> "$SEAT"
sync_seat_claudemd "$SEAT" agent-maya "$TEAM"
grep -qF 'only after a second, different check' "$SEAT" && ! grep -qF 'whenever you like' "$SEAT" \
  && [[ $(grep -c '^<!-- 5dive:team:begin' "$SEAT") == 1 ]] && grep -qx 'Own note after.' <<<"$(tail -1 "$SEAT")" \
  && ok "c5 a drifted block is replaced in place; a seat's own line after it is kept" || bad "c5 drift" "$(tail -4 "$SEAT")"
printf 'precious\n' > "$TMP/target"; ln -s "$TMP/target" "$TMP/link.md"
sync_seat_claudemd "$TMP/link.md" agent-maya "$TEAM" && bad "c6 a symlinked seat file must be refused" \
  || { [[ $(cat "$TMP/target") == precious ]] && ok "c6 a symlink is refused and its target untouched" || bad "c6 symlink target written"; }
sync_seat_claudemd "$TMP/missing.md" agent-maya "$TEAM" && bad "c7 a missing file must return 1" || ok "c7 a missing file returns 1, nothing created"
[[ ! -e "$TMP/missing.md" ]] || bad "c7b a missing file was created"
cp "$TMP/seat.orig" "$TMP/s2.md"
sync_seat_claudemd "$TMP/s2.md" agent-maya "$TMP/no-such-source" && bad "c8 an unreadable source must return 1" \
  || { cmp -s "$TMP/s2.md" "$TMP/seat.orig" && ok "c8 an unreadable source changes nothing" || bad "c8 file changed on a failed source"; }

echo "# (d) wiring"
grep -qF 'cat "$TEAM_CLAUDE_MD"; } \' src/lib/agent_setup.sh && grep -qF 'TEAM_CLAUDE_MD="/usr/local/lib/5dive/team-CLAUDE.md"' src/lib/agent_setup.sh \
  && ok "d1 create appends the team block" || bad "d1 agent_setup.sh does not append TEAM_CLAUDE_MD"
grep -qF 'curl -fsSL "$REPO/${PIN_PROMPTS}team-CLAUDE.md" -o "$LIB_DIR/team-CLAUDE.md"' install.sh \
  && grep -qF 'sync_seat_claudemd "/home/agent-${_team_seat}/.claude/CLAUDE.md" "agent-${_team_seat}" "$LIB_DIR/team-CLAUDE.md"' install.sh \
  && ok "d2 install stages the block and syncs it over claude seats" || bad "d2 install wiring missing"
grep -qF '_switch_strip_block 5dive:team' src/cmd_agent_switch.sh \
  && ok "d3 a harness switch does not carry the Claude-only block" || bad "d3 switch carries the block"

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
