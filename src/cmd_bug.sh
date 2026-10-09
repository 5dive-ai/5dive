# cmd_bug — send a diagnostic bug report to 5dive's own API (DIVE-2323, DIVE-5926).
#
# WHY THIS EXISTS: .github/ISSUE_TEMPLATE/bug_report.md, feature_request.md,
# config.yml and CONTRIBUTING.md already describe how to file a bug — nothing in
# the CLI or the failure path ever pointed at them (measured 2026-07-29: the
# issues URL appears nowhere in src/ or README.md, no bug/report/feedback verb
# in the dispatch table). The gap was DISCOVERY, not surface.
#
# DIVE-5926 — WHERE IT GOES, AND WHO SAYS YES. This verb used to open a PUBLIC
# GitHub issue through the `5dive gh` wrapper. That had two failures: a box
# with no GitHub credential saved the report and nothing ever sent it, and a box
# with one opened a public issue in our org that its owner never agreed to (#526
# #553 #693 #694 #793, all as 5dive-bot, 2026-08-07..09-08). So:
#   * --file POSTs the payload to the 5dive API (/server/bug-reports) with the
#     box's own connectord token — the identity every box->API call already
#     uses. No GitHub route is left in this file.
#   * --file needs the OWNER's yes. On a TTY the y/N prompt is that yes; with
#     no TTY (an agent) it needs --owner-approved, and refuses without it. The
#     flag is a speed bump, not proof: its job is to stop filing on reflex.
#   * The owner is asked about one defect once. The preview records the ask in
#     a small ledger keyed by verb + exit code + normalised first line of --what,
#     and a repeat prints "already asked on <date>; don't ask again". At most one
#     ask per day.
#
# THE CONSTRAINT THAT DOMINATES THE DESIGN: the payload must never leak
# personal/user data. pii-guard (DIVE-1774) does not help here — it scans what
# the REPO contains, never what a runtime emitter GENERATES, and this verb is
# exactly such an emitter aimed off the box. See
# community/wiki/a-repo-scoped-pii-gate-cannot-see-what-the-repo-generates.md.
#
# So the payload is an ALLOWLIST, never a denylist: every field is named
# explicitly, one at a time, in _bug_render_payload — never produced by
# stripping fields off a richer object. `selfcheck --json`'s probes[] carry
# .reason and .detail, both free text where paths, hostnames, agent names and
# task idents land (measured 2026-07-29); only .probe and .verdict are ever
# read out of it. `doctor --json` is not used at all — it isn't part of the
# allowlist below and was never measured to be safe to fold in.
#
# NEVER AUTO-FILES. `5dive bug` alone only builds and PRINTS the payload —
# nothing is sent anywhere. Only `--file` sends it, and it re-prints the
# identical payload immediately before doing so: the confirmation IS seeing the
# exact bytes about to leave the box.
#
# DIVE-3136 — WHY --what IS MANDATORY TO FILE. The first two issues this verb
# ever opened on the PUBLIC repo (#526 2026-08-07, #553 2026-08-10) shipped with
# the "What happened" section still holding the template's own HTML comment. The
# template asked a human to finish it, but this verb is invoked FROM AN ERROR
# PATH, usually by an agent, non-interactively — the suggestion to run it is
# printed by the failure itself. A template that needs a human to finish it is
# guaranteed to ship unfinished on exactly the path it was built for. So the
# placeholder is GONE (nothing in this file can emit it) and the description is
# an argument: `--what="..."`, satisfiable non-interactively, prompted for on a
# TTY, and a hard refusal when absent. A bug report with no description is worth
# less than no bug report, because it consumes a reader.
#
# --what AND --argv ARE THE ONLY FREE TEXT, AND THEY ARE THE CALLER'S OWN BYTES.
# That is not a hole in the allowlist above, it is the allowlist gaining two
# named fields whose content the caller typed and then SAW re-printed verbatim
# before anything left the box. What stays banned is unchanged: no field of this
# payload is ever harvested from a richer object the caller never looked at.
# Two guards ride along because the text leaves the box —
# _bug_redact_argv (same sensitive-flag rule as audit_log, src/lib/audit.sh) and
# _bug_secret_scan, which REFUSES to file text carrying a token-shaped string.

# _bug_state_dir — the caller's own state dir. Never $STATE_DIR: the spool must
# not need root or a registry, since "everything privileged is down" is a case
# it exists for.
_bug_state_dir() { printf '%s/5dive' "${XDG_STATE_HOME:-$HOME/.local/state}"; }

# _bug_spool <payload-json> — DIVE-2792: a report that could not go out is
# WRITTEN DOWN instead of dropped, 0700/0600 (it carries --what/--argv). Only the
# payload is kept — the same allowlisted JSON the owner approved — so the next
# approved `--file` can send it as is (_bug_drain). Prints the path on success,
# nothing on failure: a spool that cannot be written must not itself become a
# second unexplained error on an already-failing path.
_bug_spool() {
  local payload="$1" dir f
  dir="$(_bug_state_dir)/bug-spool"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  # mktemp, not a pid: two reports spooled in one second must not share a name.
  f=$(mktemp --suffix=.json "$dir/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$payload" > "$f" 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null || true
  printf '%s' "$f"
}

# _bug_post <payload-json> — POST /server/bug-reports with the box token.
# 0 accepted · 2 refused (a 4xx other than 404/408/429 is an answer, not a blip) ·
# 1 not reached (no readable box token, network, 5xx, 404, 408, 429). 404 is
# "not reached" because a CLI released before the API that serves this route
# must keep its reports, not drop them. Sets _BUG_HTTP
# to the status seen and _BUG_ID to the API's report id. The bearer goes in on
# STDIN (`-H @-`), never argv — DIVE-5168's rule.
_BUG_HTTP=""; _BUG_ID=""
_bug_post() {
  local payload="$1" tok="" trc=0 out="" url
  _BUG_HTTP=""; _BUG_ID=""
  tok=$(_partner_box_token) || trc=$?
  (( trc == 0 )) || { _BUG_HTTP="no-token"; return 1; }
  url="$(_partner_api_base)/server/bug-reports"
  out=$(printf 'Authorization: Bearer %s\n' "$tok" \
          | curl -sS --max-time "${FIVE_BUG_POST_TIMEOUT:-20}" -X POST "$url" -H @- \
              -H 'Content-Type: application/json' --data-binary "$payload" \
              -w '\n%{http_code}' 2>/dev/null) || true
  _BUG_HTTP="${out##*$'\n'}"
  [[ "$_BUG_HTTP" =~ ^[0-9]{3}$ ]] || _BUG_HTTP="000"
  _BUG_ID=$(jq -r '.id // empty' <<<"${out%$'\n'*}" 2>/dev/null) || _BUG_ID=""
  case "$_BUG_HTTP" in
    2??) return 0 ;;
    404|408|429) return 1 ;;
    4??) return 2 ;;
  esac
  return 1
}

# _bug_drain — send what an earlier approved `--file` spooled while offline.
# Called only from an approved `--file` that just reached the API, so nothing is
# sent that its owner did not approve when it was written. Only *.json is read
# (the .md files the GitHub era spooled were written for a public issue and are
# left alone), and each is re-cut to the allowlist before it goes. Sent → removed;
# refused → renamed *.refused and never retried; not reached → stop, keep the rest.
# Prints the number sent.
_bug_drain() {
  local dir f p sent=0 rc
  dir="$(_bug_state_dir)/bug-spool"
  [[ -d "$dir" ]] || { printf '0'; return 0; }
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    p=$(jq -c 'select(type == "object") | {version, os, bash_version, install_method,
                verb, exit_code, what, invocation, probes}' "$f" 2>/dev/null) || p=""
    if [[ -z "$p" ]]; then mv -f "$f" "$f.refused" 2>/dev/null || true; continue; fi
    rc=0; _bug_post "$p" || rc=$?
    case "$rc" in
      0) rm -f "$f"; sent=$((sent + 1)) ;;
      2) mv -f "$f" "$f.refused" 2>/dev/null || true ;;
      *) break ;;
    esac
  done
  printf '%s' "$sent"
}

# ── the asked-ledger: never ask the owner twice about one defect ───────────────
# One line per ask: key<TAB>YYYY-MM-DD<TAB>verb<TAB>exit. Box-wide in
# $STATE_DIR/bug-asked.tsv when this seat can write it (0660 group claude, the
# a2a ledgers' pattern: whoever runs as root first creates it for everyone), else
# in the seat's own state dir. Both are read, so a box-wide record is honoured
# by a seat that can only write its own.
_bug_asked_ledgers() {
  printf '%s\n' "${FIVE_BUG_ASKED_LEDGER:-${STATE_DIR:-/var/lib/5dive}/bug-asked.tsv}" \
                "$(_bug_state_dir)/bug-asked.tsv"
}

# _bug_defect_key <verb> <exit> <what> — the same defect failing again maps to
# the same key: first line of --what, lowercased, every digit run folded to one
# '#' (pids, ports, counts, timestamps), whitespace collapsed.
_bug_defect_key() {
  local line="${3%%$'\n'*}"
  line=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | sed -E 's/[0-9]+/#/g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
  printf '%s|%s|%s' "$1" "$2" "${line:0:200}" | sha256sum | cut -c1-16
}

# _bug_asked_on <key> — the date this defect was first asked about; rc 1 if never.
_bug_asked_on() {
  local f k d ledgers
  ledgers=$(_bug_asked_ledgers)
  while IFS= read -r f; do
    [[ -r "$f" ]] || continue
    while IFS=$'\t' read -r k d _; do
      [[ "$k" == "$1" ]] && { printf '%s' "$d"; return 0; }
    done < "$f"
  done <<<"$ledgers"
  return 1
}

# _bug_asked_today — rc 0 when any ask is recorded for today (UTC).
_bug_asked_today() {
  local f today ledgers; today=$(date -u +%F)
  ledgers=$(_bug_asked_ledgers)
  while IFS= read -r f; do
    [[ -r "$f" ]] || continue
    grep -qxF "$today" <<<"$(cut -f2 "$f" 2>/dev/null)" && return 0
  done <<<"$ledgers"
  return 1
}

# _bug_asked_record <key> <verb> <exit> — best-effort: a ledger that cannot be
# written must not fail the report it describes.
_bug_asked_record() {
  local line f
  line=$(printf '%s\t%s\t%s\t%s' "$1" "$(date -u +%F)" "${2//$'\t'/ }" "$3")
  f=$(_bug_asked_ledgers | head -n 1)
  if [[ ! -e "$f" ]]; then
    ( umask 0117; : >> "$f" ) 2>/dev/null && { chgrp claude "$f" 2>/dev/null || true; }
  fi
  if [[ -w "$f" ]]; then
    printf '%s\n' "$line" >> "$f" 2>/dev/null && return 0
  fi
  f=$(_bug_asked_ledgers | sed -n 2p)
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$f" 2>/dev/null || true
  return 0
}

_bug_usage() {
  cat >&2 <<'EOF'
5dive bug --what=<text> [--verb=<name>] [--exit=<code>] [--argv=<line>]
          [--no-probes] [--file [--owner-approved]]

Preview (default): builds the diagnostic payload and prints it. Sends nothing.
Preview freely; send it only after your owner agrees.

  --what=<text>   REQUIRED to --file: what you were doing, what you expected,
                  what you saw. On a TTY you are prompted if you omit it; with
                  no TTY the report is REFUSED rather than sent empty.
  --verb=<name>   the 5dive verb that failed (e.g. "doctor"); default: unknown
  --exit=<code>   its exit code; default: unknown
  --argv=<line>   the failing invocation, e.g. --argv="gh pr view 51 --json st".
                  Sensitive =<value> flags (--token=, --api-key=, ...) are
                  redacted before it is shown or sent.
  --no-probes     skip the selfcheck probe summary entirely (probe name +
                  verdict only ever appear — never the free-text reason/detail
                  fields underneath them)

  --file          re-print the SAME payload, then send it to 5dive's API with
                  this box's own key. Nothing goes to GitHub or anywhere public.
  --owner-approved
                  required with --file when there is no TTY (an agent): ask
                  your owner in one line, naming what failed, and pass this
                  only on their yes. A TTY gets a y/N prompt instead.

The preview tells you whether to ask: a defect your owner was already asked
about prints "already asked on <date>; don't ask again", and the owner is asked
about at most one bug a day. If the API cannot be reached the report is saved
under ${XDG_STATE_HOME:-$HOME/.local/state}/5dive/bug-spool/ and the next
approved --file sends it.

The payload is a fixed allowlist: version, OS, bash version, install method,
the verb that failed, its exit code, selfcheck probe name+verdict pairs, and
the two fields you supply yourself — --what and --argv. Nothing else is
collected, and every byte is printed before it is sent.
EOF
}

# _bug_os — best-effort distro string. Never anything host-identifying (no
# hostname, no machine-id) — just what OS/version this is.
_bug_os() {
  if [[ -r /etc/os-release ]]; then
    ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-unknown} ${VERSION_ID:-}}" )
  else
    printf '%s %s' "$(uname -s)" "$(uname -r)"
  fi
}

# _bug_install_method — curl-install (single bundled file, the shipped path)
# vs git-checkout (this tree, or any dev clone) vs unknown (couldn't resolve
# the running bundle at all — see five_self_bundle in src/lib/self.sh).
_bug_install_method() {
  local self=""
  self=$(five_self_bundle 2>/dev/null) || self=""
  if [[ -z "$self" ]]; then
    printf 'unknown'
  elif git -C "$(dirname -- "$self")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'git-checkout'
  else
    printf 'curl-install'
  fi
}

# _bug_sanitize_verb <text> — bounds what --verb can carry. Not a free-text
# channel: strip control chars/newlines and cap length, so a pasted paragraph
# can't ride along disguised as "the verb name".
_bug_sanitize_verb() {
  local v="$1"
  v="${v//$'\n'/ }"
  v=$(printf '%s' "$v" | tr -d '\000-\010\013\014\016-\037')
  printf '%s' "${v:0:80}"
}

# _bug_sanitize_text <text> <max> — bounds a caller-supplied free-text field.
# Unlike _bug_sanitize_verb, newlines SURVIVE: --what is a paragraph and the
# issue body is markdown, so folding it to one line would damage the one field
# this whole ticket exists to make readable. Everything else in the C0 range is
# stripped (a terminal escape in a public issue body is nobody's friend) and the
# length is capped so a pasted logfile cannot ride in disguised as a summary.
_bug_sanitize_text() {
  local t="$1" max="${2:-2000}"
  t=$(printf '%s' "$t" | tr -d '\000-\010\013\014\016-\037')
  printf '%s' "${t:0:$max}"
}

# _bug_redact_argv <line> — the SAME sensitive-flag rule audit_log applies to
# every row it writes (src/lib/audit.sh), deliberately duplicated rather than
# shared: audit_log redacts an ARRAY of argv elements it was handed, this
# redacts one flat string a caller typed, and the two cannot take each other's
# input. Keep the flag list here in step with that one. --secret=/--password=
# are additions, not drift: this string is bound for a public issue, so the
# denylist is wider here than on a root-only logfile.
#
# A denylist is the wrong shape for harvested data and the right shape here:
# the caller wrote this line and re-reads it before filing. It removes the
# common accident, and _bug_secret_scan below is the backstop that REFUSES
# rather than silently rewriting when something token-shaped survives.
#
# DIVE-4297: the second expression is the mirror of audit_log's key-name rule.
# The first expression alone required a leading `--`, so a positional
# `telegram.token=<value>` — the exact shape that leaked into the audit log —
# was filed to a PUBLIC issue verbatim. Key names are matched case-insensitively
# and anywhere in the key, so `TELEGRAM.TOKEN=`, `api_key=` and `--auth-secret=`
# are all covered; the key is kept and only the value replaced.
_bug_redact_argv() {
  printf '%s' "$1" \
    | sed -E 's/(--(api-key|api_key|token|telegram-token|discord-token|code|password|secret|passwd)=)[^[:space:]]*/\1<redacted>/g' \
    | sed -E 's/([^[:space:]=]*(token|secret|key|password|passwd|credential)[^[:space:]=]*=)[^[:space:]]*/\1<redacted>/gI'
}

# _bug_secret_scan <text> — returns 0 when the text carries something
# token-SHAPED. Not a completeness claim: it cannot know every secret format,
# so it is a refusal trigger and never a licence to relax the rest of this
# file. Patterns are the prefixes that are unambiguous on sight.
_bug_secret_scan() {
  grep -qE 'gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{20,}' <<<"$1"
}

# _bug_collect_probes — the ONLY two fields ('probe', 'verdict') ever read out
# of `selfcheck --json`'s probes[], named explicitly. .reason/.detail/.asserts
# and the top-level .label (a host:uid string) are never asked for — the
# acceptance harness (tests/bug_report_pii_allowlist_unit.sh) plants a
# PII-shaped marker in a fixture's .reason/.detail and asserts it never reaches
# this function's output.
_bug_collect_probes() {
  local raw=""
  raw=$(cmd_selfcheck --json 2>/dev/null) || true
  [[ -n "$raw" ]] || { printf '[]'; return 0; }
  jq -c '[ .probes[]? | {probe: .probe, verdict: .verdict} ]' <<<"$raw" 2>/dev/null || printf '[]'
}

# _bug_render_payload <verb> <exit_code> <include_probes:0|1> — the entire
# allowlist. Every key is named on the jq template line below; adding a new
# field to the payload means editing this one line on purpose, never a
# passthrough of some richer object.
_bug_render_payload() {
  local verb="$1" exit_code="$2" include_probes="$3" what="${4:-}" argv="${5:-}"
  local v_san; v_san=$(_bug_sanitize_verb "$verb")
  [[ -n "$v_san" ]] || v_san="unknown"
  local probes_json='[]'
  (( include_probes )) && probes_json=$(_bug_collect_probes)
  local exit_json='null'
  [[ "$exit_code" =~ ^[0-9]+$ ]] && exit_json="$exit_code"
  # what/invocation render as JSON null when absent, never "" — the preview path
  # legitimately has no description yet, and an empty string would read as "the
  # caller described it as nothing" in exactly the artifact this ticket is
  # about. Absent-vs-empty stays distinguishable, same rule .exit_code follows.
  local what_json='null' argv_json='null'
  [[ -n "$what" ]] && what_json=$(jq -Rn --arg s "$(_bug_sanitize_text "$what" 2000)" '$s')
  [[ -n "$argv" ]] && argv_json=$(jq -Rn --arg s "$(_bug_sanitize_text "$(_bug_redact_argv "$argv")" 400)" '$s')
  jq -cn \
    --arg version "$FIVE_VERSION" \
    --arg os "$(_bug_os)" \
    --arg bash_version "${BASH_VERSION:-unknown}" \
    --arg install_method "$(_bug_install_method)" \
    --arg verb "$v_san" \
    --argjson exit_code "$exit_json" \
    --argjson what "$what_json" \
    --argjson invocation "$argv_json" \
    --argjson probes "$probes_json" \
    '{version:$version, os:$os, bash_version:$bash_version,
      install_method:$install_method, verb:$verb, exit_code:$exit_code,
      what:$what, invocation:$invocation, probes:$probes}'
}

cmd_bug() {
  local verb="" exit_code="" include_probes=1 do_file=0 owner_approved=0 what="" argv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verb=*)    verb="${1#--verb=}"; shift ;;
      --exit=*)    exit_code="${1#--exit=}"; shift ;;
      --what=*)    what="${1#--what=}"; shift ;;
      --argv=*)    argv="${1#--argv=}"; shift ;;
      --no-probes) include_probes=0; shift ;;
      --file)      do_file=1; shift ;;
      --owner-approved) owner_approved=1; shift ;;
      -h|--help)   _bug_usage; return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1 (see: 5dive bug --help)" ;;
    esac
  done
  [[ -n "$verb" ]] || verb="${CURRENT_VERB:-unknown}"

  # DIVE-3136: settle the description BEFORE the payload is rendered, so the
  # preview a caller reads is byte-identical to what --file then sends. The TTY
  # prompt is the whole reason the refusal below is not a regression for humans:
  # they are ASKED for the field instead of being told to re-run with a flag.
  if (( do_file )) && [[ -z "$what" ]] && [[ -t 0 ]]; then
    printf 'One or two lines — what were you doing, what did you expect, what did you see?\n> ' >&2
    read -r what || what=""
  fi
  # And this is the arm that closes the ticket: no description, no report.
  # Non-interactive is the path that filed #526 and #553, and it is the path
  # that must be satisfiable without a human — hence --what, named in the error.
  if (( do_file )) && [[ -z "${what//[[:space:]]/}" ]]; then
    fail "$E_USAGE" "refusing to file a bug report with no description. Re-run with --what=\"what you were doing, what you expected, what you saw\" (an empty report costs a reader more than it is worth). Everything else is collected for you."
  fi
  # DIVE-5926: the owner says yes first. A TTY is asked below; an agent has no
  # TTY and must say it asked. This is what stops filing on reflex from the
  # failure hint — the path that opened #693 #694 #793 with nobody asked.
  if (( do_file && ! owner_approved )) && [[ ! -t 0 ]]; then
    fail "$E_USAGE" "refusing to send a bug report your owner has not agreed to. Ask them in one line, naming what failed (e.g. \"5dive ${verb} failed with exit ${exit_code:-?}: ${what%%$'\n'*}. May I send 5dive a bug report with the details shown by '5dive bug'?\"), and re-run with --owner-approved only on their yes. If '5dive bug' says they were already asked, don't ask again."
  fi
  # A token-shaped string in text about to leave the box is a mistake no rewrite
  # can make safe, because the caller would not learn they had made it.
  #
  # Scanned AFTER redaction, deliberately. --argv is the field a caller pastes
  # their real command line into, and `--token=ghp_...` is precisely what
  # _bug_redact_argv exists to absorb; scanning the RAW string made the two
  # guards fight and the refusal always won, which left the redaction unable to
  # fire on the one shape it was written for and handed the caller a dead end
  # where the design promised a fix. So redaction goes first and the scan grades
  # what actually SURVIVED it — a bare token with no flag around it.
  if (( do_file )) && _bug_secret_scan "$what$(_bug_redact_argv "$argv")"; then
    fail "$E_USAGE" "refusing to file: --what/--argv carries a token-shaped string, and this sends it off the box. Remove it and re-run."
  fi

  local payload key asked_on="" ask_owner=0
  payload=$(_bug_render_payload "$verb" "$exit_code" "$include_probes" "$what" "$argv")
  key=$(_bug_defect_key "$verb" "$exit_code" "$what")

  if (( ! do_file )); then
    # The ask is recorded HERE, at the moment this verb tells the caller to ask:
    # a "no" never reaches --file, and must still stop the next ask.
    if asked_on=$(_bug_asked_on "$key"); then
      :
    elif _bug_asked_today; then
      asked_on="today"
    else
      ask_owner=1
      _bug_asked_record "$key" "$verb" "$exit_code"
    fi
    if (( JSON_MODE )); then
      ok "" '{filed:false, payload:$p, ask_owner:$a, owner_already_asked:(if $d == "" then null else $d end)}' \
        --argjson p "$payload" --argjson a "$( (( ask_owner )) && echo true || echo false)" \
        --arg d "$asked_on"
    else
      echo "The following is the ENTIRE payload — nothing else leaves this box:" >&2
      jq '.' <<<"$payload" >&2
      echo >&2
      echo "Nothing sent." >&2
      if [[ "$asked_on" == "today" ]]; then
        echo "Your owner was already asked about a 5dive bug today; don't ask again today. If this still fails tomorrow, preview it again." >&2
      elif [[ -n "$asked_on" ]]; then
        echo "Your owner was already asked about this on ${asked_on}; don't ask again. If they said yes, send it with --file --owner-approved." >&2
      else
        echo "To send it to 5dive: ask your owner in one line, naming what failed, and only on their yes re-run with --file --owner-approved. It goes to 5dive's own API, never to a public page." >&2
      fi
    fi
    return 0
  fi

  # --file: show the exact payload regardless of --json — this line is the
  # confirmation, not decoration, so it is never conditional on output mode.
  echo "Sending the following payload to 5dive — nothing else leaves this box:" >&2
  jq '.' <<<"$payload" >&2

  if [[ -t 0 ]]; then
    printf 'Send this report to 5dive as shown above? [y/N] ' >&2
    local reply=""; read -r reply || reply=""
    case "$reply" in
      y|Y|yes|Yes|YES) ;;
      *) fail "$E_USAGE" "aborted — nothing sent" ;;
    esac
  fi
  _bug_asked_on "$key" >/dev/null || _bug_asked_record "$key" "$verb" "$exit_code"

  local rc=0 spooled="" drained=0
  _bug_post "$payload" || rc=$?
  case "$rc" in
    0)
      drained=$(_bug_drain) || drained=0
      ok "bug report sent to 5dive${_BUG_ID:+ (report $_BUG_ID)}$( (( drained )) && printf '; also sent %s saved earlier' "$drained")" \
        '{filed:true, id:$i, drained:$n}' --arg i "$_BUG_ID" --argjson n "${drained:-0}"
      ;;
    2)
      fail "$( [[ "$_BUG_HTTP" == 40[13] ]] && echo "$E_AUTH_REQUIRED" || echo "$E_VALIDATION")" \
        "5dive's API refused the report (HTTP ${_BUG_HTTP}) — nothing was sent, and it is not saved for retry. The payload printed above is the only copy."
      ;;
    *)
      local why="could not reach 5dive's API (HTTP ${_BUG_HTTP})"
      [[ "$_BUG_HTTP" == "no-token" ]] && why="this seat cannot read the box's key ($(_partner_connectord_env))"
      spooled=$(_bug_spool "$payload") || spooled=""
      if [[ -n "$spooled" ]]; then
        fail "$E_TIMEOUT" "${why} — the report was NOT sent, but it is saved at ${spooled}; the next approved '5dive bug --file' sends it. Your owner already said yes, so don't ask them again."
      fi
      fail "$E_TIMEOUT" "${why} — and the local spool could not be written either, so the payload printed above is the only copy."
      ;;
  esac
}
