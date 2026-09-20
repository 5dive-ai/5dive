# ── DIVE-4251: `5dive config` — the per-box settings surface ────────────────
#
# Box settings, shared by every seat:
# the company wizard needs somewhere to write a per-box choice that every seat
# reads and no seat can change for itself. `5dive agent config <name> set …` is
# the PER-AGENT surface and could not host this — a box default that each seat
# stores separately is not a box default.
#
# ROOT WRITES, EVERYONE READS. The file lives in STATE_DIR (2750 root:claude),
# so any agent reads it without sudo and only root sets it. A customer who does
# not want graders sets it once, on the box, and every seat honours it.
_box_config_read() {
  local f; f=$(_box_config_path)
  [[ -r "$f" ]] && cat "$f" 2>/dev/null || printf '{}'
}

cmd_box_config() {
  local -a sets=()
  while (( $# )); do
    case "$1" in
      --json) JSON_MODE=1 ;;
      -h|--help) printf '%s\n' \
        "usage: 5dive config                 # show this box's settings" \
        "       5dive config verify=<always|delivered-only|never>" \
        "       5dive config verify-small=<lines>|off" \
        "       5dive config coauthor=<on|off>" \
        "" \
        "  verify   whether a task on this box gets a grader session." \
        "             always          every standard row is graded" \
        "             delivered-only  only rows bound to a delivery (default when unset)" \
        "             never           no row is graded by default" \
        "           A row always wins over the box: 'task add --verify' demands a" \
        "           grade on a 'never' box, 'task add --no-verify' skips one on 'always'." \
        "" \
        "  verify-small  how SMALL a delivery has to be to close without a grader." \
        "             <lines>  a delivery under this many changed lines (additions +" \
        "                      deletions, across the whole PR) closes outright" \
        "             off      every delivery is graded on its own merits (default)" \
        "           Paths override the number: anything touching the scheduler, the task" \
        "           store, credentials, deploy, a shared lib, sudo policy, systemd, the" \
        "           schema or the provisioning scripts is never small, at any size." \
        "           'task add --verify' still demands a grade whatever the size."
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *=*) sets+=("$1") ;;
      *)  fail "$E_USAGE" "usage: 5dive config [<key>=<value>]  (keys: verify, verify-small, coauthor)" ;;
    esac
    shift
  done

  if (( ${#sets[@]} == 0 )); then
    local policy; policy=$(box_verify_policy)
    local src="box default" configured="" cfg
    cfg=$(_box_config_path)
    [[ -r "$cfg" ]] && configured=$(jq -r '.verify // empty' "$cfg" 2>/dev/null || printf '')
    [[ -n "$configured" ]] || src="unset — defaulting to 'delivered-only'"
    [[ "${FIVE_VERIFY_DEFAULT:-1}" == "0" ]] && src="FIVE_VERIFY_DEFAULT=0 in this environment"
    local small; small=$(box_verify_small)
    local ssrc="off — every delivery is graded on its own merits"
    [[ "$small" != "off" ]] && ssrc="a delivery under ${small} changed lines closes without a grader (DIVE-4559)"
    local coauthor; coauthor=$(jq -r '.coauthor // "on"' <<<"$(_box_config_read)" 2>/dev/null || printf on)
    [[ "$coauthor" == on || "$coauthor" == off ]] || coauthor=on
    ok "verify = ${policy} (${src})
verify-small = ${small} (${ssrc})
coauthor = ${coauthor} (box-wide, default on)" \
       '{verify:$v, source:$s, verify_small:$sm, coauthor:$c, path:$p}' \
       --arg v "$policy" --arg s "$src" --arg sm "$small" --arg c "$coauthor" --arg p "$(_box_config_path)"
    return 0
  fi

  # VALIDATE BEFORE require_root. A typo'd value is a typo whether or not the
  # caller is root, and refusing it with "must run as root" sends the reader
  # after the wrong problem — they sudo, and only then learn the value was wrong.
  local kv k v json
  for kv in "${sets[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      verify) _verify_policy_valid "$v" \
                || fail "$E_VALIDATION" "verify takes one of: ${_VERIFY_POLICIES// /, } — got '$v'" ;;
      # DIVE-4559. `verify-small` on the command line, `.verify_small` in the
      # file: the hyphen is the CLI convention every other 5dive flag uses and
      # the underscore is jq-addressable without quoting. Both spellings are
      # accepted here so a caller who read the JSON cannot be told their own
      # key is unknown.
      verify-small|verify_small) _verify_small_valid "$v" \
                || fail "$E_VALIDATION" "verify-small takes a positive number of changed lines, or 'off' — got '$v'" ;;
      coauthor) [[ "$v" == on || "$v" == off ]] \
                || fail "$E_VALIDATION" "coauthor takes one of: on, off — got '$v'" ;;
      *) fail "$E_VALIDATION" "unknown box setting: $k (keys: verify, verify-small, coauthor)" ;;
    esac
  done
  require_root
  json=$(_box_config_read)
  local -a applied=()
  # DIVE-4559: WRITE THE KEY THAT WAS SET. This loop hardcoded `.verify = $v`
  # while iterating over every key — harmless with one key, and a silent
  # mis-write the moment there were two (`verify-small=30` would have stored
  # "30" as the verification POLICY, which `box_verify_policy` then discards as
  # invalid: the setting vanishes and the command reports success).
  for kv in "${sets[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    json=$(jq --arg k "${k//-/_}" --arg v "$v" '.[$k] = $v' <<<"$json")
    applied+=("$k")
  done
  local cfg; cfg=$(_box_config_path)
  mkdir -p "$(dirname "$cfg")"
  local tmp; tmp=$(mktemp "${cfg}.XXXXXX")
  printf '%s\n' "$json" > "$tmp"
  # 640 root:claude, the same posture as agents.json: every seat reads it,
  # only root writes it.
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 640 "$tmp"
  mv "$tmp" "$cfg"
  local policy; policy=$(box_verify_policy)
  local small; small=$(box_verify_small)
  ok "box config updated (${applied[*]}) — verify = ${policy}, verify-small = ${small}" \
     '{verify:$v, verify_small:$sm, applied:($a|split(",")), path:$p}' \
     --arg v "$policy" --arg sm "$small" --arg a "$(IFS=,; printf '%s' "${applied[*]}")" --arg p "$cfg"
}
