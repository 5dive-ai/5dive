# cmd_bug — file a diagnostic bug report against 5dive-ai/5dive (DIVE-2323).
#
# WHY THIS EXISTS: .github/ISSUE_TEMPLATE/bug_report.md, feature_request.md,
# config.yml and CONTRIBUTING.md already describe how to file a bug — nothing in
# the CLI or the failure path ever pointed at them (measured 2026-07-29: the
# issues URL appears nowhere in src/ or README.md, no bug/report/feedback verb
# in the dispatch table). The gap was DISCOVERY, not surface.
#
# THE CONSTRAINT THAT DOMINATES THE DESIGN: the payload must never leak
# personal/user data. pii-guard (DIVE-1774) does not help here — it scans what
# the REPO contains, never what a runtime emitter GENERATES, and this verb is
# exactly such an emitter aimed at a PUBLIC issue. See
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
# nothing is sent anywhere. Only `--file` opens the issue, and it re-prints the
# identical payload immediately before doing so: the confirmation IS seeing the
# exact bytes about to leave the box. A TTY additionally gets an interactive
# y/N. There is no separate unattended path: an agent takes the exact same
# --file flag a human types, because an unreviewed report filed at 3am is
# precisely the failure mode this refuses to build.
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
# Two guards ride along because the destination is a public issue —
# _bug_redact_argv (same sensitive-flag rule as audit_log, src/lib/audit.sh) and
# _bug_secret_scan, which REFUSES to file text carrying a token-shaped string.

_bug_usage() {
  local _org; _org=$(gh_org)
  cat >&2 <<EOF
5dive bug --what=<text> [--verb=<name>] [--exit=<code>] [--argv=<line>]
          [--no-probes] [--file]

Preview (default): builds the diagnostic payload and prints it. Files nothing.
  --what=<text>   REQUIRED to --file: what you were doing, what you expected,
                  what you saw. On a TTY you are prompted if you omit it; with
                  no TTY the report is REFUSED rather than filed empty.
  --verb=<name>   the 5dive verb that failed (e.g. "doctor"); default: unknown
  --exit=<code>   its exit code; default: unknown
  --argv=<line>   the failing invocation, e.g. --argv="gh pr view 51 --json st".
                  Sensitive =<value> flags (--token=, --api-key=, ...) are
                  redacted before it is shown or filed.
  --no-probes     skip the selfcheck probe summary entirely (probe name +
                  verdict only ever appear — never the free-text reason/detail
                  fields underneath them)

  --file          re-print the SAME payload, then open it as a GitHub issue
                  against ${_org}/5dive (via '5dive gh issue create', so it
                  files as 5dive-bot when this account can write). A TTY also
                  gets an interactive y/N; nothing is ever filed by default.

The payload is a fixed allowlist: version, OS, bash version, install method,
the verb that failed, its exit code, selfcheck probe name+verdict pairs, and
the two fields you supply yourself — --what and --argv. Nothing else is
collected, and every byte is printed before it is filed.
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
_bug_redact_argv() {
  printf '%s' "$1" | sed -E 's/(--(api-key|api_key|token|telegram-token|discord-token|code|password|secret|passwd)=)[^[:space:]]*/\1<redacted>/g'
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

# _bug_body_markdown <payload-json> — renders the issue body from the
# ALREADY-ALLOWLISTED payload only (never re-reads selfcheck itself), matching
# the Environment/Logs sections of .github/ISSUE_TEMPLATE/bug_report.md.
_bug_body_markdown() {
  local payload="$1"
  local version os bash_version install_method verb exit_code probes_table what invocation
  version=$(jq -r '.version' <<<"$payload")
  os=$(jq -r '.os' <<<"$payload")
  bash_version=$(jq -r '.bash_version' <<<"$payload")
  install_method=$(jq -r '.install_method' <<<"$payload")
  verb=$(jq -r '.verb' <<<"$payload")
  exit_code=$(jq -r '.exit_code // "unknown"' <<<"$payload")
  what=$(jq -r '.what // ""' <<<"$payload")
  invocation=$(jq -r '.invocation // ""' <<<"$payload")
  probes_table=$(jq -r '.probes[]? | "- \(.probe): \(.verdict)"' <<<"$payload")
  [[ -n "$probes_table" ]] || probes_table="(skipped — re-run without --no-probes to include)"
  # DIVE-3136: the description is the caller's --what, rendered here verbatim.
  # There is deliberately NO template comment to fall back to — cmd_bug refuses
  # to --file without a description, so the only way to reach this line empty is
  # the local preview path, and it says so in words a reader can act on rather
  # than in a comment that renders invisible on github.com.
  [[ -n "$what" ]] || what="_(preview: no --what supplied — 5dive bug refuses to file without one)_"
  local invocation_block=""
  [[ -n "$invocation" ]] && invocation_block=$(printf '\n## Failing invocation\n\n```\n5dive %s\n```\n' "$invocation")
  cat <<EOF
## What happened

${what}

Filed via \`5dive bug\` after \`5dive ${verb}\` exited ${exit_code}.
${invocation_block}
## Environment

- \`5dive --version\`: ${version}
- OS / distro: ${os}
- bash: ${bash_version}
- Install method: ${install_method}

## Diagnostics (selfcheck probe name + verdict only — no free text)

${probes_table}
EOF
}

cmd_bug() {
  local verb="" exit_code="" include_probes=1 do_file=0 what="" argv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verb=*)    verb="${1#--verb=}"; shift ;;
      --exit=*)    exit_code="${1#--exit=}"; shift ;;
      --what=*)    what="${1#--what=}"; shift ;;
      --argv=*)    argv="${1#--argv=}"; shift ;;
      --no-probes) include_probes=0; shift ;;
      --file)      do_file=1; shift ;;
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
  # And this is the arm that closes the ticket: no description, no public issue.
  # Non-interactive is the path that filed #526 and #553, and it is the path
  # that must be satisfiable without a human — hence --what, named in the error.
  if (( do_file )) && [[ -z "${what//[[:space:]]/}" ]]; then
    fail "$E_USAGE" "refusing to file a bug report with no description. Re-run with --what=\"what you were doing, what you expected, what you saw\" (an empty report costs a reader more than it is worth). Everything else is collected for you."
  fi
  # The public destination is what makes this a refusal and not a redaction: a
  # token-shaped string in text the caller is about to publish is a mistake no
  # rewrite can make safe, because they would not learn they had made it.
  #
  # Scanned AFTER redaction, deliberately. --argv is the field a caller pastes
  # their real command line into, and `--token=ghp_...` is precisely what
  # _bug_redact_argv exists to absorb; scanning the RAW string made the two
  # guards fight and the refusal always won, which left the redaction unable to
  # fire on the one shape it was written for and handed the caller a dead end
  # where the design promised a fix. So redaction goes first and the scan grades
  # what actually SURVIVED it — a bare token with no flag around it.
  if (( do_file )) && _bug_secret_scan "$what$(_bug_redact_argv "$argv")"; then
    fail "$E_USAGE" "refusing to file: --what/--argv carries a token-shaped string, and this opens a PUBLIC issue. Remove it and re-run."
  fi

  local payload
  payload=$(_bug_render_payload "$verb" "$exit_code" "$include_probes" "$what" "$argv")

  if (( ! do_file )); then
    if (( JSON_MODE )); then
      ok "" '{filed:false, payload:$p}' --argjson p "$payload"
    else
      echo "The following is the ENTIRE payload — nothing else leaves this box:" >&2
      jq '.' <<<"$payload" >&2
      echo >&2
      echo "Nothing filed. Re-run with --file to open this as a GitHub issue against $(gh_org)/5dive." >&2
    fi
    return 0
  fi

  # --file: show the exact payload regardless of --json — this line is the
  # confirmation, not decoration, so it is never conditional on output mode.
  echo "Filing the following payload — nothing else leaves this box:" >&2
  jq '.' <<<"$payload" >&2

  if [[ -t 0 ]]; then
    printf 'File this issue on %s/5dive as shown above? [y/N] ' "$(gh_org)" >&2
    local reply=""; read -r reply || reply=""
    case "$reply" in
      y|Y|yes|Yes|YES) ;;
      *) fail "$E_GENERIC" "aborted — nothing filed" ;;
    esac
  fi

  command -v gh >/dev/null 2>&1 \
    || fail "$E_NOT_INSTALLED" "gh is not installed — file the payload printed above by hand at https://github.com/$(gh_org)/5dive/issues/new"

  local body title tmpf rc=0 issue_url=""
  body=$(_bug_body_markdown "$payload")
  title="[5dive bug] ${verb:-unknown} exited ${exit_code:-unknown}"
  tmpf=$(mktemp) || fail "$E_GENERIC" "mktemp failed"
  printf '%s\n' "$body" > "$tmpf"
  # `if var=$(cmd)` (not `var=$(cmd); rc=$?`) — under set -e a failing command
  # substitution on the right of a bare assignment can still trip the shell;
  # as an if-condition it is explicitly exempt, so this is the safe capture.
  if issue_url=$(cmd_gh issue create --repo "$(gh_org)/5dive" --title "$title" --label bug --body-file "$tmpf"); then
    rc=0
  else
    rc=$?
  fi
  rm -f "$tmpf"
  if (( rc == 0 )); then
    ok "issue filed: $issue_url" '{filed:true, url:$u}' --arg u "$issue_url"
  else
    fail "$E_GENERIC" "gh issue create failed (rc=$rc) — the payload printed above is everything this would have sent"
  fi
}
