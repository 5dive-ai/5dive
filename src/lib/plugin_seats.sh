# ---------------------------------------------------------------------------
# DIVE-4522: a box-level plugin install is not a seat-level one
# ---------------------------------------------------------------------------
# `5dive plugin add browser@5dive-plugins` enables a plugin for the BOX:
# $STATE_DIR/plugins/enabled/<key> points at the version-keyed cache dir and
# installed.json records what was declared. Nothing in that sequence touches an
# agent seat, and a `skill` plugin is only real when the seat's harness LOADS it.
#
# Measured 2026-09-14 on lodar's canary (exact-swallow, 4 seats): browser had
# been enabled at the box level since the Sep 11 provision, shipped
# skills/connect-site, and every seat's ~/.claude/plugins/installed_plugins.json
# listed telegram + dashboard ONLY. Four agents, one browser they could not see.
# Per-seat registration ran exactly once, at agent create, and only for the
# seat's CHANNEL plugins — so a plugin added after a seat exists reached nobody,
# and `plugin add` printed "registers: channel,verb,skill" while registering the
# skill half with no one.
#
# This file is the walker that closes that: at `plugin add`, at `plugin
# upgrade`, at agent create, and in reverse at `plugin remove`.
#
# THE TRAP, and it is why every call here is a NON-LOGIN shell with
# CLAUDE_CONFIG_DIR unset. /etc/profile.d/5dive-shared-configs.sh exports
# CLAUDE_CONFIG_DIR=/home/claude/.claude for every login shell on the box, so
# `sudo -u agent-x bash -lc 'claude plugin install browser@5dive-plugins'` reads
# CLAUDE's config, finds no 5dive-plugins marketplace there, and fails with
# "Plugin 'browser' not found in marketplace '5dive-plugins'" — a message that
# names the wrong cause and cost 10 minutes on the canary. install_channel_
# plugin_for_agent already avoids it the same way; this is the second caller,
# not a new discovery.

# The capabilities that make a plugin SEAT-FACING. A plugin declaring neither
# registers with nobody — that is the line-339 warning in cmd_plugin.sh staying
# true, and it is what the mutant arm in the unit suite grades. `channel` is
# deliberately NOT here: channel plugins are installed per seat by
# install_channel_for_agent, which also npm-installs deps and patches the start
# script, and running this walker over them would half-install a service.
PLUGIN_SEAT_CAPS="${PLUGIN_SEAT_CAPS:-skill mcp}"

# plugin_seat_is_seat_facing <space-separated-caps> -> 0 when a seat must learn
# about this plugin.
plugin_seat_is_seat_facing() {
  local caps=" ${1:-} " c
  for c in $PLUGIN_SEAT_CAPS; do
    [[ "$caps" == *" $c "* ]] && return 0
  done
  return 1
}

# The seat's HOME. PERSONA_HOME_ROOT is the seam persona_target() already uses,
# so the unit suite exercises the real writers against a temp tree rather than
# asserting on greps — same seam, same reason.
_plugin_seat_home() { printf '%s/agent-%s\n' "${PERSONA_HOME_ROOT:-/home}" "${1:-}"; }
_plugin_seat_installed_json() { printf '%s/.claude/plugins/installed_plugins.json\n' "$(_plugin_seat_home "${1:-}")"; }

# A registry row whose home directory is gone is NOT a seat anything can be
# installed into. One predicate, used by the walker and by the report, because
# when they disagreed the report named a seat the walk had skipped and the fix it
# printed — re-run the walk — skipped it again. A warning whose stated remedy is
# a no-op is a hold nobody can lift, so the two must read the same seat set.
plugin_seat_home_exists() { [[ -d "$(_plugin_seat_home "${1:-}")" ]]; }

# plugin_seat_rows -> "<name>\t<type>" for every registered agent.
# Reads the registry and nothing else; stubbed in tests by stubbing registry_read.
plugin_seat_rows() {
  local reg; reg=$(registry_read 2>/dev/null || echo '{}')
  jq -r '(.agents // {}) | to_entries[] | [.key, (.value.type // "claude")] | @tsv' <<<"$reg" 2>/dev/null || true
}

# plugin_seat_registered <name> <plugin> <marketplace> -> 0 when that seat's
# claude already carries the plugin. This is the state that was invisible: it
# reads the SEAT's file, never the box's installed.json.
plugin_seat_registered() {
  local f; f=$(_plugin_seat_installed_json "${1:-}")
  [[ -f "$f" ]] || return 1
  jq -e --arg k "${2:-}@${3:-}" '((.plugins // {})[$k] // []) | length > 0' "$f" >/dev/null 2>&1
}

# The clone URL a SEAT can use for a marketplace this box has registered.
# A `local` marketplace deliberately returns non-zero: the seat cannot clone a
# path that only root can read, and pretending otherwise would produce a seat
# whose marketplace entry points at a directory it gets EACCES on.
_plugin_seat_mkt_repo() {
  local mkt="${1:-}" src kind mj; mj="$(_plugin_mkt_json)"
  [[ -f "$mj" ]] || return 1
  src=$(jq -r --arg n "$mkt" '.[$n].source // ""' "$mj" 2>/dev/null)
  kind=$(jq -r --arg n "$mkt" '.[$n].kind // ""' "$mj" 2>/dev/null)
  [[ "$kind" == "git" && -n "$src" ]] || return 1
  case "$src" in
    *://*|*@*:*) printf '%s\n' "$src" ;;
    */*)         printf 'https://github.com/%s.git\n' "${src%@*}" ;;
    *)           return 1 ;;
  esac
}

# The one place that drops privilege to a seat. A function rather than an inline
# `sudo` so the unit suite can replace it: everything above it is then graded for
# real, and only the privilege drop is stubbed.
plugin_seat_run_as() { # plugin_seat_run_as <user> [VAR=VAL ...]  (script on stdin)
  local user="$1"; shift
  sudo -u "$user" -H env "$@" bash -s
}

# Register one plugin with one CLAUDE seat. Idempotent; 0 = registered (now or
# already), non-zero = it is not registered and the caller must say so.
plugin_seat_register_claude() { # <name> <plugin> <marketplace>
  local name="${1:-}" plugin="${2:-}" mkt="${3:-}" user="agent-${1:-}" repo
  if ! repo=$(_plugin_seat_mkt_repo "$mkt"); then
    warn "[$name] marketplace '$mkt' has no URL a seat can clone (local source?) — $plugin NOT registered for this seat"
    return 2
  fi
  plugin_seat_run_as "$user" PLUGIN="$plugin" MARKETPLACE="$mkt" MKT_REPO="$repo" \
    >&2 <<'SEAT_PLUGIN_REGISTER' || true
set -uo pipefail
# NOT a login shell, and this unset is the whole reason (see the header).
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
CLAUDE="${CLAUDE_BIN:-/home/claude/.local/bin/claude}"
[ -x "$CLAUDE" ] || CLAUDE="$(command -v claude 2>/dev/null || echo "$CLAUDE")"

# Same pre-registration as install_channel_plugin_for_agent, same cause:
# `claude plugin marketplace add` crashes headless for a user that has never run
# a session (DIVE-248), while `marketplace update` works headless once the
# marketplace is on disk. So clone + record, then let `update` take it.
MKT_DIR="$HOME/.claude/plugins/marketplaces/$MARKETPLACE"
if [ ! -d "$MKT_DIR/.git" ]; then
  mkdir -p "$HOME/.claude/plugins/marketplaces"
  rm -rf "$MKT_DIR"
  git clone -q --depth 1 "$MKT_REPO" "$MKT_DIR" || true
fi
MKT_SLUG=$(printf '%s' "$MKT_REPO" | sed -e 's#^https://github.com/##' -e 's#\.git$##')
KM_FILE="$HOME/.claude/plugins/known_marketplaces.json" \
  MKT_NAME="$MARKETPLACE" MKT_SLUG="$MKT_SLUG" MKT_DIR="$MKT_DIR" python3 <<'PREREG' || true
import json, os, datetime
km = os.environ["KM_FILE"]
d = {}
if os.path.exists(km):
    try:
        d = json.load(open(km))
    except Exception:
        d = {}
d.setdefault(os.environ["MKT_NAME"], {
    "source": {"source": "github", "repo": os.environ["MKT_SLUG"]},
    "installLocation": os.environ["MKT_DIR"],
    "lastUpdated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
})
json.dump(d, open(km, "w"), indent=2)
PREREG

"$CLAUDE" plugin marketplace update "$MARKETPLACE" >/dev/null 2>&1 \
  || "$CLAUDE" plugin marketplace add "$MKT_REPO" >/dev/null 2>&1 || true
yes | "$CLAUDE" plugin install "${PLUGIN}@${MARKETPLACE}" >/dev/null 2>&1 || true
SEAT_PLUGIN_REGISTER
  plugin_seat_registered "$name" "$plugin" "$mkt"
}

# Reverse. `claude plugin uninstall` is the verb; the seat's own cache dir goes
# with it, which is the point — `plugin remove` promises the code is gone.
plugin_seat_unregister_claude() { # <name> <plugin> <marketplace>
  local name="${1:-}" plugin="${2:-}" mkt="${3:-}" user="agent-${1:-}"
  plugin_seat_registered "$name" "$plugin" "$mkt" || return 0
  plugin_seat_run_as "$user" PLUGIN="$plugin" MARKETPLACE="$mkt" \
    >&2 <<'SEAT_PLUGIN_UNREGISTER' || true
set -uo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
CLAUDE="${CLAUDE_BIN:-/home/claude/.local/bin/claude}"
[ -x "$CLAUDE" ] || CLAUDE="$(command -v claude 2>/dev/null || echo "$CLAUDE")"
yes | "$CLAUDE" plugin uninstall "${PLUGIN}@${MARKETPLACE}" >/dev/null 2>&1 || true
SEAT_PLUGIN_UNREGISTER
  ! plugin_seat_registered "$name" "$plugin" "$mkt"
}

# ---------------------------------------------------------------------------
# Non-claude harnesses
# ---------------------------------------------------------------------------
# A codex/pi/opencode/grok seat has no plugin system to register with, and that
# is not the same as having nothing to give it. A plugin that ships an AGENTS.md
# section is shipping the SAME workflow its Claude skill carries, written for any
# harness (browser's own file says so in its first paragraph). So the section is
# installed into the seat's instructions file.
#
# THROUGH persona_target(), never a hardcoded `.claude/…`: TYPE_PERSONA_FILE is
# the map that knows a codex seat reads ~/.codex/AGENTS.md and a pi seat reads
# ~/.pi/agent/AGENTS.md, and cmd_selfupdate.sh's header records what happens when
# a payload path is re-literaled instead of derived — five of thirteen seats,
# 27 skill dirs, invisible and silently skipped every night.
plugin_seat_doc_begin() { printf '<!-- 5dive:%s:begin -->' "${1:-}"; }
plugin_seat_doc_end()   { printf '<!-- 5dive:%s:end -->' "${1:-}"; }

# The section to install, read from the plugin's own directory. A plugin that
# already delimits its AGENTS.md (browser does) has the DELIMITED REGION taken
# verbatim, so what lands on the seat is byte-identical to what the publisher
# wrote between its own markers; one that does not is wrapped, because the
# markers are what makes removal exact.
#
# ONLY the region, never the whole file, and the reason is plugin_seat_doc_install
# below: it replaces the begin..end region of the seat's file with whatever this
# returns. Return the whole file and every byte OUTSIDE the markers — a heading, a
# licence footer, a maintainer note — is re-inserted INSIDE them on every run, so
# `plugin add`, `plugin upgrade` and the agent-create backfill each append another
# copy to the file the agent reads every turn. Measured 1/2/3 copies over three
# installs before this returned the region. browser's AGENTS.md puts its markers
# on the first and last line, which is exactly why the whole-file form looked
# correct: for that one file the two are the same string.
#
# The extraction is the same first-match, non-greedy span doc_install's regex
# takes: shortest prefix up to the first begin marker, shortest suffix from the
# first end marker after it.
_plugin_seat_doc_region() { # <body> <begin-marker> <end-marker>
  local body="${1:-}" b="${2:-}" e="${3:-}" rest
  rest="${body#*"$b"}"
  printf '%s%s%s\n' "$b" "${rest%%"$e"*}" "$e"
}

plugin_seat_doc_block() { # <plugin> <plugin-dir>
  local plugin="${1:-}" dir="${2:-}" f="${2:-}/AGENTS.md" body b e
  [[ -f "$f" ]] || return 1
  body=$(cat "$f") || return 1
  [[ -n "$body" ]] || return 1
  b=$(plugin_seat_doc_begin "$plugin"); e=$(plugin_seat_doc_end "$plugin")
  if [[ "$body" == *"$b"*"$e"* ]]; then
    _plugin_seat_doc_region "$body" "$b" "$e"
  else
    printf '%s\n%s\n%s\n' "$b" "$body" "$e"
  fi
}

# Install (or refresh) the marker-delimited section in one seat's instructions
# file. Replaces an existing block rather than appending a second copy, so the
# nightly and a re-run of `plugin add` converge instead of accreting.
plugin_seat_doc_install() { # <name> <type> <plugin> <plugin-dir>
  local name="${1:-}" type="${2:-}" plugin="${3:-}" dir="${4:-}" md block user="agent-${1:-}"
  block=$(plugin_seat_doc_block "$plugin" "$dir") || return 1
  md=$(persona_target "$name" "$type") || return 1
  _persona_ensure_dir "$user" "$md"
  MD="$md" BLOCK="$block" BEGIN="$(plugin_seat_doc_begin "$plugin")" \
    END="$(plugin_seat_doc_end "$plugin")" python3 <<'DOCPY' || return 1
import os, re
md, block = os.environ["MD"], os.environ["BLOCK"].rstrip("\n")
b, e = os.environ["BEGIN"], os.environ["END"]
cur = ""
if os.path.exists(md):
    with open(md) as f:
        cur = f.read()
pat = re.compile(re.escape(b) + r".*?" + re.escape(e), re.S)
if pat.search(cur):
    new = pat.sub(lambda _m: block, cur, count=1)
else:
    new = (cur.rstrip("\n") + "\n\n" if cur.strip() else "") + block + "\n"
if new != cur:
    os.makedirs(os.path.dirname(md), exist_ok=True)
    with open(md, "w") as f:
        f.write(new)
DOCPY
  chown "$user":"$user" "$md" 2>/dev/null || true
  grep -qF "$(plugin_seat_doc_begin "$plugin")" "$md" 2>/dev/null
}

plugin_seat_doc_remove() { # <name> <type> <plugin>
  local name="${1:-}" type="${2:-}" plugin="${3:-}" md
  md=$(persona_target "$name" "$type") || return 1
  [[ -f "$md" ]] || return 0
  MD="$md" BEGIN="$(plugin_seat_doc_begin "$plugin")" END="$(plugin_seat_doc_end "$plugin")" \
    python3 <<'DOCPY' || return 1
import os, re
md = os.environ["MD"]
b, e = os.environ["BEGIN"], os.environ["END"]
with open(md) as f:
    cur = f.read()
new = re.sub(re.escape(b) + r".*?" + re.escape(e) + r"\n?", "", cur, count=1, flags=re.S)
if new != cur:
    with open(md, "w") as f:
        f.write(new.rstrip("\n") + ("\n" if new.strip() else ""))
DOCPY
  ! grep -qF "$(plugin_seat_doc_begin "$plugin")" "$md" 2>/dev/null
}

# plugin_seat_doc_installed <name> <type> <plugin> -> 0 when that seat's
# instructions file already carries the plugin's section. The non-claude
# counterpart of plugin_seat_registered, and what lets the report grade a codex
# seat at all instead of counting it and looking away.
plugin_seat_doc_installed() { # <name> <type> <plugin>
  local md; md=$(persona_target "${1:-}" "${2:-}") || return 1
  [[ -f "$md" ]] || return 1
  grep -qF "$(plugin_seat_doc_begin "${3:-}")" "$md" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The walkers
# ---------------------------------------------------------------------------
# plugin_seat_apply <plugin> <marketplace> <caps> <register|unregister> [dir]
#
# One line of report per seat, on stderr, because a silent walk is the state this
# row was filed to remove: `plugin add` used to print "registers: skill" and the
# operator had no way to learn that it registered with nobody.
plugin_seat_apply() {
  local plugin="${1:-}" mkt="${2:-}" caps="${3:-}" action="${4:-register}" dir="${5:-}"
  plugin_seat_is_seat_facing "$caps" || return 0
  local key="${plugin}@${mkt}" name type n_ok=0 n_skip=0 n_fail=0
  [[ -n "$dir" ]] || dir="$(_plugin_enabled_dir)/$key"

  while IFS=$'\t' read -r name type; do
    [[ -n "$name" ]] || continue
    plugin_seat_home_exists "$name" || { n_skip=$((n_skip+1)); continue; }
    case "$type" in
      claude)
        if [[ "$action" == register ]]; then
          if plugin_seat_register_claude "$name" "$plugin" "$mkt"; then
            echo "  $name (claude): $key registered" >&2; n_ok=$((n_ok+1))
          else
            echo "  $name (claude): $key NOT registered — run 'sudo 5dive doctor' " >&2; n_fail=$((n_fail+1))
          fi
        else
          if plugin_seat_unregister_claude "$name" "$plugin" "$mkt"; then
            echo "  $name (claude): $key unregistered" >&2; n_ok=$((n_ok+1))
          else
            echo "  $name (claude): $key could NOT be unregistered" >&2; n_fail=$((n_fail+1))
          fi
        fi ;;
      *)
        # No plugin system on this harness — the AGENTS.md section is the whole
        # of what we can give it, and a plugin that ships none gets skipped
        # rather than warned about: not every plugin has a non-claude story.
        if [[ "$action" == register ]]; then
          if plugin_seat_doc_block "$plugin" "$dir" >/dev/null 2>&1; then
            if plugin_seat_doc_install "$name" "$type" "$plugin" "$dir"; then
              echo "  $name ($type): $plugin instructions installed" >&2; n_ok=$((n_ok+1))
            else
              echo "  $name ($type): $plugin instructions NOT installed" >&2; n_fail=$((n_fail+1))
            fi
          else
            n_skip=$((n_skip+1))
          fi
        else
          plugin_seat_doc_remove "$name" "$type" "$plugin" >/dev/null 2>&1 \
            && { echo "  $name ($type): $plugin instructions removed" >&2; n_ok=$((n_ok+1)); } \
            || n_skip=$((n_skip+1))
        fi ;;
    esac
  done < <(plugin_seat_rows)

  if (( n_ok || n_fail )); then
    echo "  seats: $n_ok ok, $n_fail failed, $n_skip skipped" >&2
  fi
  (( n_fail == 0 ))
}

# The other direction, for agent create: give a BRAND-NEW seat every seat-facing
# plugin the box already has enabled. Without this, a seat created after
# `plugin add` is as blind as the four on the canary were — the same defect from
# the other end, and the reason this is a separate verb rather than a flag.
plugin_seat_backfill() { # <name> <type>
  local name="${1:-}" type="${2:-}" key plugin mkt caps ij
  ij="$(_plugin_installed_json)"
  [[ -f "$ij" ]] || return 0
  while IFS=$'\t' read -r key plugin mkt caps; do
    [[ -n "$key" ]] || continue
    plugin_seat_is_seat_facing "$caps" || continue
    if [[ "$type" == claude ]]; then
      plugin_seat_register_claude "$name" "$plugin" "$mkt" \
        && echo "  $name: $key registered" >&2 \
        || echo "  $name: $key NOT registered" >&2
    else
      local dir; dir="$(_plugin_enabled_dir)/$key"
      plugin_seat_doc_block "$plugin" "$dir" >/dev/null 2>&1 || continue
      plugin_seat_doc_install "$name" "$type" "$plugin" "$dir" \
        && echo "  $name: $plugin instructions installed" >&2 \
        || echo "  $name: $plugin instructions NOT installed" >&2
    fi
  done < <(jq -r 'to_entries[] | select(.value.enabled)
                  | [.key, .value.plugin, .value.marketplace,
                     ((.value.capabilities // []) | join(" "))] | @tsv' "$ij" 2>/dev/null || true)
}

# plugin_seat_graded_rows -> "<name>\t<type>" for the seats this report and the
# walker BOTH act on: every registry row whose home still exists. Exported as its
# own verb so `doctor` counts exactly the seats it graded — a green line reading
# "registered with all 3 seat(s)" while two were measured is this row's own defect
# one layer out, and this row exists because a surface said "registers: skill"
# about a box while it was false about every agent on it.
plugin_seat_graded_rows() {
  local name type
  while IFS=$'\t' read -r name type; do
    [[ -n "$name" ]] || continue
    plugin_seat_home_exists "$name" || continue
    printf '%s\t%s\n' "$name" "$type"
  done < <(plugin_seat_rows)
}

# plugin_seat_unregistered_rows -> "<seat>\t<type>\t<key>" for every ENABLED
# seat-facing plugin a seat does not carry. This is the report `doctor` prints,
# and it is the exact state that was invisible on 2026-09-14: four seats, one
# enabled skill plugin, nothing anywhere that would have said so.
#
# EVERY harness is graded, each by what "carried" means for it: a claude seat by
# its own installed_plugins.json, any other by the plugin's section in the file
# that harness reads. Grading claude only would have left the half of the fix that
# serves codex/pi/opencode seats with no surface at all — a section hand-deleted
# from a codex seat's AGENTS.md would have read green, by name-count, as covered.
plugin_seat_unregistered_rows() {
  local ij; ij="$(_plugin_installed_json)"
  [[ -f "$ij" ]] || return 0
  local -a keys=() plugins=() mkts=() dirs=()
  local key plugin mkt caps name type i
  while IFS=$'\t' read -r key plugin mkt caps; do
    [[ -n "$key" ]] || continue
    plugin_seat_is_seat_facing "$caps" || continue
    keys+=("$key"); plugins+=("$plugin"); mkts+=("$mkt")
    dirs+=("$(_plugin_enabled_dir)/$key")
  done < <(jq -r 'to_entries[] | select(.value.enabled)
                  | [.key, .value.plugin, .value.marketplace,
                     ((.value.capabilities // []) | join(" "))] | @tsv' "$ij" 2>/dev/null || true)
  (( ${#keys[@]} )) || return 0
  while IFS=$'\t' read -r name type; do
    [[ -n "$name" ]] || continue
    for i in "${!keys[@]}"; do
      if [[ "$type" == claude ]]; then
        plugin_seat_registered "$name" "${plugins[$i]}" "${mkts[$i]}" \
          || printf '%s\t%s\t%s\n' "$name" "$type" "${keys[$i]}"
      else
        # A plugin shipping no AGENTS.md has nothing to give this harness, and
        # the walker skips it rather than failing — so it is not a finding here
        # either. Same predicate, same seat set, in both directions.
        plugin_seat_doc_block "${plugins[$i]}" "${dirs[$i]}" >/dev/null 2>&1 || continue
        plugin_seat_doc_installed "$name" "$type" "${plugins[$i]}" \
          || printf '%s\t%s\t%s\n' "$name" "$type" "${keys[$i]}"
      fi
    done
  done < <(plugin_seat_graded_rows)
}

# ---------------------------------------------------------------------------
# DIVE-4730 — traverse-only access to the box plugin record, for a seat that is
# outside the shared group ON PURPOSE.
#
# DIVE-4709 established that a seat which cannot READ $STATE_DIR/plugins/
# installed.json loses every enabled plugin verb, and prescribed
# `gpasswd -a agent-<seat> claude`. Reading two customer boxes (DIVE-4727)
# showed the prescription is wrong for the only population it ever fires on.
# On both boxes the record itself was already 0644 and every directory below
# $STATE_DIR was already 2755: the single refusing component was $STATE_DIR
# (2750 root:claude), and the single seat outside the group was the blind one.
# Box 11's was the box's ONLY `isolation: sandboxed` seat, and DIVE-1033 takes
# sandboxed seats out of that group deliberately — the group is what the box's
# shared credentials are scoped to. Adding the seat back does not repair the
# sandbox, it dissolves it.
#
# The create path already solved this exact shape one directory over: a
# traverse-only ACL on /home/claude. Its own comment carries the argument, and
# it applies unchanged here — `--x` on a NAMED principal is smaller in
# permission bits AND smaller in principals than `chmod o+x`, which would hand
# traversal to every uid on the box, and smaller than group membership, which
# hands over the credentials group itself.
#
# THE GRANT IS SIZED BY WHAT REFUSES, not by the whole path. Only a component
# with no o+x bit is touched: on both measured boxes that is exactly one
# directory. Opening a directory makes every mode inside it load-bearing, so
# the narrower the set, the smaller the residual (on box 11: the o+r files
# directly under $STATE_DIR become reachable BY KNOWN PATH — pace-usage.json,
# account-usage.json, cli-target.json, digest.json, usage-budgets.json,
# browser-stack.status, the stamps. No secret is among them; `voice/config`'s
# one credential-shaped line is a comment pointing at /etc. Re-run that read
# before widening this to a path it was not sized against).

# plugin_root_traverse_components <path> — the ancestors of <path>, INCLUSIVE,
# that a uid in none of their groups cannot traverse today, top-down.
#
# Top-down and `-e`-guarded for the same reason _plugin_record_blocker_path is:
# a stat below an untraversable parent fails for the parent's reason, so a
# bottom-up walk cannot tell "absent" from "hidden". Stops at the first absent
# component and emits nothing further — there is nothing to grant on a path
# that does not exist yet.
#
# The test is the o+x bit and only that bit. A 2755 directory is already
# traversable by every uid, so granting there would be a no-op ACL that makes
# the next reader think the mode matters. `stat -c %a` prints 4 digits on a
# setgid directory (2750), which is why this reads the LAST character rather
# than masking a whole number.
plugin_root_traverse_components() {
  local target="${1:-}" p="" rest comp mode
  [[ "$target" == /* ]] || return 0
  rest="${target#/}"
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    [[ -n "$comp" ]] || continue
    p="$p/$comp"
    [[ -e "$p" ]] || return 0
    mode=$(stat -c '%a' "$p" 2>/dev/null) || return 0
    (( ${mode: -1} & 1 )) || printf '%s\n' "$p"
  done
}

# plugin_root_traverse_grant <user> <path> — setfacl -m u:<user>:--x on each of
# those components. Prints every path it granted; returns 1 (and prints the
# failures to stderr) if any setfacl refused, so a caller can warn precisely
# instead of guessing which half landed.
#
# IDEMPOTENT by construction: `setfacl -m` on an entry that already exists is a
# no-op, which is what lets the same helper serve the create path and the retro
# pass for seats minted before it.
plugin_root_traverse_grant() {
  local user="${1:-}" target="${2:-}" p rc=0
  [[ -n "$user" && -n "$target" ]] || return 0
  command -v setfacl >/dev/null 2>&1 || { printf 'setfacl not installed\n' >&2; return 1; }
  while read -r p; do
    [[ -n "$p" ]] || continue
    if setfacl -m "u:${user}:--x" "$p" 2>/dev/null; then
      printf '%s\n' "$p"
    else
      printf '%s\n' "$p" >&2
      rc=1
    fi
  done < <(plugin_root_traverse_components "$target")
  return "$rc"
}
