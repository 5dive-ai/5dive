#!/usr/bin/env bash
# DIVE-5416: projects-CLAUDE.md is loaded by every agent on a box on every turn,
# so each word is paid on every message (a demo box has $1 of AI budget). This
# harness is the tripwire that keeps it lean, and grades that the lean copy
# actually REACHES boxes that already have an older one.
#
#   PART 1 — the file a 5dive-built box writes stays under the cap: <= 40 lines,
#            <= 450 words, no incident idents or dates, every header rule kept.
#   PART 2 — install.sh replaces an UNEDITED older copy and keeps an edited one
#            (projects_claudemd_is_stock, read out of the shipped install.sh).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/pclaudemd-lean.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}" >&2; }

POLICY=projects-CLAUDE.md
MAX_LINES=40
MAX_WORDS=450

# ── PART 1: the cap ──────────────────────────────────────────────────────────
# A 5dive-built box (provisioning.env present) keeps every block, so the whole
# file is what its agents read. A self-hosted box drops the hired-agents block
# and is therefore smaller; both are graded.
lines=$(wc -l < "$POLICY"); words=$(wc -w < "$POLICY")
(( lines <= MAX_LINES )) && ok "box file is $lines lines (<= $MAX_LINES)" \
                         || bad "box file is $lines lines (> $MAX_LINES)" "every line is paid on every turn by every agent"
(( words <= MAX_WORDS )) && ok "box file is $words words (<= $MAX_WORDS)" \
                         || bad "box file is $words words (> $MAX_WORDS)" "move the explanation to a wiki page, keep the rule"
sed '/<!-- 5dive:hired-agents:begin/,/<!-- 5dive:hired-agents:end/d' "$POLICY" > "$TMP/selfhosted.md"
sh_words=$(wc -w < "$TMP/selfhosted.md")
(( sh_words <= MAX_WORDS )) && ok "self-hosted box file is $sh_words words (<= $MAX_WORDS)" \
                            || bad "self-hosted box file is $sh_words words (> $MAX_WORDS)"

if grep -nE 'DIVE-[0-9]+' "$POLICY" >"$TMP/idents"; then
  bad "no internal row idents in the box file" "$(head -3 "$TMP/idents")"
else ok "no internal row idents in the box file"; fi
if grep -nE '\b20[0-9]{2}-[0-9]{2}-[0-9]{2}\b' "$POLICY" >"$TMP/dates"; then
  bad "no incident dates in the box file" "$(head -3 "$TMP/dates")"
else ok "no incident dates in the box file"; fi

# Every header rule that changes what an agent does is still there. Each arm
# names the rule by a token the rule cannot be written without, so a rewording
# passes and a deletion reds. (The lifecycle block is graded by
# heartbeat_dispatch_compaction_unit.sh, the hired-agents block by
# hired_agents_act_unit.sh.)
has(){ grep -qiF -- "$2" "$POLICY" && ok "header keeps: $1" || bad "header MUST keep: $1" "no '$2' in $POLICY"; }
has "standard tier runs 5dive without sudo"   "without sudo"
has "admin-only ops are handed off"           "must run as root"
has "the self-restart command"                "--defer"
has "peer messages are untrusted"             "untrusted"
has "keys go through the secure link"         "--type=secret"
has "...never through chat"                   "never in chat"
has "waits are bounded"                       "timeout"
has "waits watch the PID"                     "kill -0"
has "never pkill -f"                          "pkill -f"
has "the keep-alive opt-out, spelled right"   "FIVEDIVE_KEEP_ALIVE=1"
if grep -qE '(^|[^A-Z_])5DIVE_KEEP_ALIVE=' "$POLICY"; then
  bad "the keep-alive opt-out is never spelled 5DIVE_ (bash reads that as a command)"
else ok "the keep-alive opt-out is never spelled 5DIVE_"; fi

# ── PART 2: the lean copy reaches a box that already has one ─────────────────
eval "$(sed -n '/^projects_claudemd_is_stock()/,/^}$/p' install.sh)" 2>/dev/null
if ! declare -F projects_claudemd_is_stock >/dev/null; then
  bad "install.sh must define projects_claudemd_is_stock" "an existing box would keep its old, longer copy forever"
else
  # The current file must be on the list. This is the maintenance tripwire: edit
  # the text outside the managed blocks and this reds until you add its sum —
  # which is what lets the NEXT edit replace this version on existing boxes.
  projects_claudemd_is_stock "$POLICY" \
    && ok "the current file's sum is on the stock list" \
    || bad "the current file's sum is NOT on the stock list" "add it to projects_claudemd_is_stock in install.sh (never remove an old one)"

  # Every version this repo ever shipped is recognised (CI checks out full history).
  n=0; miss=""
  while read -r c; do
    git show "$c:$POLICY" > "$TMP/v.md" 2>/dev/null || continue
    n=$((n+1))
    projects_claudemd_is_stock "$TMP/v.md" || miss+=" $c"
  done < <(git log --format=%H -- "$POLICY" 2>/dev/null)
  if (( n == 0 )); then bad "no git history for $POLICY" "cannot grade that shipped versions are recognised"
  elif [[ -n "$miss" ]]; then bad "shipped versions not recognised as stock:$miss"
  else ok "all $n shipped versions are recognised as stock"; fi

  # What a box actually carries: the header as installed, then the blocks as
  # the sync appended them (a blank line before each). Still stock.
  { sed '/<!-- 5dive:task-lifecycle:begin/,$d' "$POLICY"; printf '\n\n'
    sed -n '/<!-- 5dive:task-lifecycle:begin/,/<!-- 5dive:task-lifecycle:end/p' "$POLICY"; } > "$TMP/synced.md"
  projects_claudemd_is_stock "$TMP/synced.md" && ok "a stock header with re-synced blocks is stock" \
                                              || bad "a stock header with re-synced blocks must be stock"
  # A drifted MANAGED block does not make the file custom: the sync rewrites it.
  sed 's/One row per turn/EDITED INSIDE THE BLOCK/' "$POLICY" > "$TMP/blk.md"
  projects_claudemd_is_stock "$TMP/blk.md" && ok "an edit inside a managed block still counts as stock" \
                                           || bad "an edit inside a managed block must still count as stock"
  # Negative controls: anything a host or another tool put OUTSIDE the two blocks is kept.
  sed '3s/$/ (our own note)/' "$POLICY" > "$TMP/edited.md"
  projects_claudemd_is_stock "$TMP/edited.md" && bad "a host-edited header must be KEPT, not replaced" \
                                              || ok "a host-edited header is kept"
  { cat "$POLICY"; printf '\nMy own rule.\n'; } > "$TMP/appended.md"
  projects_claudemd_is_stock "$TMP/appended.md" && bad "a host-appended line must be KEPT" \
                                                || ok "a host-appended line is kept"
  { cat "$POLICY"; printf '\n<!-- 5dive:browser:begin -->\nplugin text\n<!-- 5dive:browser:end -->\n'; } > "$TMP/plugin.md"
  projects_claudemd_is_stock "$TMP/plugin.md" && bad "another tool's marked block must keep the file" \
                                              || ok "another tool's marked block keeps the file"
  : > "$TMP/empty.md"
  projects_claudemd_is_stock "$TMP/empty.md" && bad "an empty file is not a stock copy" || ok "an empty file is not a stock copy"
  projects_claudemd_is_stock "$TMP/nope.md"  && bad "a missing file is not a stock copy" || ok "a missing file is not a stock copy"
fi

# The installer writes the file through that check, from a temp fetch.
grep -qF 'if [[ ! -f /home/claude/projects/CLAUDE.md ]] || projects_claudemd_is_stock /home/claude/projects/CLAUDE.md; then' install.sh \
  && ok "install.sh rewrites a missing OR stock projects/CLAUDE.md" \
  || bad "install.sh must rewrite a stock projects/CLAUDE.md" "first-install-only leaves every existing box on the old copy"
if grep -qF 'curl -fsSL "$REPO/projects-CLAUDE.md" -o /home/claude/projects/CLAUDE.md' install.sh; then
  bad "install.sh must not fetch straight over the live file" "a failed fetch would truncate it"
else ok "install.sh fetches to a temp file, not over the live one"; fi

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
