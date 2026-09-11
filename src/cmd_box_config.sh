# ── DIVE-4251: `5dive config` — the per-box settings surface ────────────────
#
# ONE KEY TODAY (`verify`), and the shape is deliberately open for the next one:
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
        "" \
        "  verify   whether a task on this box gets a grader session." \
        "             always          every standard row is graded (default)" \
        "             delivered-only  only rows bound to a delivery (task deliver --pr=)" \
        "             never           no row is graded by default" \
        "           A row always wins over the box: 'task add --verify' demands a" \
        "           grade on a 'never' box, 'task add --no-verify' skips one on 'always'."
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *=*) sets+=("$1") ;;
      *)  fail "$E_USAGE" "usage: 5dive config [<key>=<value>]  (keys: verify)" ;;
    esac
    shift
  done

  if (( ${#sets[@]} == 0 )); then
    local policy; policy=$(box_verify_policy)
    local src="box default"
    [[ -r "$(_box_config_path)" ]] || src="unset — defaulting to 'always'"
    [[ "${FIVE_VERIFY_DEFAULT:-1}" == "0" ]] && src="FIVE_VERIFY_DEFAULT=0 in this environment"
    ok "verify = ${policy} (${src})" \
       '{verify:$v, source:$s, path:$p}' \
       --arg v "$policy" --arg s "$src" --arg p "$(_box_config_path)"
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
      *) fail "$E_VALIDATION" "unknown box setting: $k (keys: verify)" ;;
    esac
  done
  require_root
  json=$(_box_config_read)
  local -a applied=()
  for kv in "${sets[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    json=$(jq --arg v "$v" '.verify = $v' <<<"$json")
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
  ok "box config updated (${applied[*]}) — verify = ${policy}" \
     '{verify:$v, applied:($a|split(",")), path:$p}' \
     --arg v "$policy" --arg a "$(IFS=,; printf '%s' "${applied[*]}")" --arg p "$cfg"
}
