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

_bug_usage() {
  local _org; _org=$(gh_org)
  cat >&2 <<EOF
5dive bug [--verb=<name>] [--exit=<code>] [--no-probes] [--file]

Preview (default): builds the diagnostic payload and prints it. Files nothing.
  --verb=<name>   the 5dive verb that failed (e.g. "doctor"); default: unknown
  --exit=<code>   its exit code; default: unknown
  --no-probes     skip the selfcheck probe summary entirely (probe name +
                  verdict only ever appear — never the free-text reason/detail
                  fields underneath them)

  --file          re-print the SAME payload, then open it as a GitHub issue
                  against ${_org}/5dive (via '5dive gh issue create', so it
                  files as 5dive-bot when this account can write). A TTY also
                  gets an interactive y/N; nothing is ever filed by default.

The payload is a fixed allowlist: version, OS, bash version, install method,
the verb that failed, its exit code, and selfcheck probe name+verdict pairs.
No free text ever leaves this box in it.
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
  local verb="$1" exit_code="$2" include_probes="$3"
  local v_san; v_san=$(_bug_sanitize_verb "$verb")
  [[ -n "$v_san" ]] || v_san="unknown"
  local probes_json='[]'
  (( include_probes )) && probes_json=$(_bug_collect_probes)
  local exit_json='null'
  [[ "$exit_code" =~ ^[0-9]+$ ]] && exit_json="$exit_code"
  jq -cn \
    --arg version "$FIVE_VERSION" \
    --arg os "$(_bug_os)" \
    --arg bash_version "${BASH_VERSION:-unknown}" \
    --arg install_method "$(_bug_install_method)" \
    --arg verb "$v_san" \
    --argjson exit_code "$exit_json" \
    --argjson probes "$probes_json" \
    '{version:$version, os:$os, bash_version:$bash_version,
      install_method:$install_method, verb:$verb, exit_code:$exit_code,
      probes:$probes}'
}

# _bug_body_markdown <payload-json> — renders the issue body from the
# ALREADY-ALLOWLISTED payload only (never re-reads selfcheck itself), matching
# the Environment/Logs sections of .github/ISSUE_TEMPLATE/bug_report.md.
_bug_body_markdown() {
  local payload="$1"
  local version os bash_version install_method verb exit_code probes_table
  version=$(jq -r '.version' <<<"$payload")
  os=$(jq -r '.os' <<<"$payload")
  bash_version=$(jq -r '.bash_version' <<<"$payload")
  install_method=$(jq -r '.install_method' <<<"$payload")
  verb=$(jq -r '.verb' <<<"$payload")
  exit_code=$(jq -r '.exit_code // "unknown"' <<<"$payload")
  probes_table=$(jq -r '.probes[]? | "- \(.probe): \(.verdict)"' <<<"$payload")
  [[ -n "$probes_table" ]] || probes_table="(skipped — re-run without --no-probes to include)"
  cat <<EOF
## What happened

Filed via \`5dive bug\` after \`5dive ${verb}\` exited ${exit_code}.

<!-- Add a one-paragraph summary here: what did you expect, what did you see. -->

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
  local verb="" exit_code="" include_probes=1 do_file=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verb=*)    verb="${1#--verb=}"; shift ;;
      --exit=*)    exit_code="${1#--exit=}"; shift ;;
      --no-probes) include_probes=0; shift ;;
      --file)      do_file=1; shift ;;
      -h|--help)   _bug_usage; return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1 (see: 5dive bug --help)" ;;
    esac
  done
  [[ -n "$verb" ]] || verb="${CURRENT_VERB:-unknown}"

  local payload
  payload=$(_bug_render_payload "$verb" "$exit_code" "$include_probes")

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
    || fail "$E_NOT_INSTALLED" "gh is not installed on this box — cannot file a GitHub issue. The payload above is everything this verb would have sent; file it by hand at https://github.com/$(gh_org)/5dive/issues/new?template=bug_report.md"

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
    fail "$E_GENERIC" "gh issue create failed (rc=$rc) — the payload printed above is everything this would have sent; file it by hand if needed"
  fi
}
