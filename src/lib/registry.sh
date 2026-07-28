with_registry_lock() {
  local fn="$1"; shift
  if [[ "${IN_REGISTRY_LOCK:-0}" == "1" ]]; then
    "$fn" "$@"
    return
  fi
  ensure_state
  (
    flock -x 200
    IN_REGISTRY_LOCK=1
    "$fn" "$@"
  ) 200>"$REGISTRY_LOCK"
}

registry_read() {
  [[ -f "$REGISTRY" ]] && cat "$REGISTRY" || echo '{"agents":{}}'
}

# registry_read() deliberately collapses "no registry yet" onto an empty-but-valid
# body so every read site can `jq` it without a guard. That is fine for callers
# who only want a value, and WRONG for callers who need to know whether the read
# happened at all: a permission failure, a truncated file and a genuinely empty
# fleet all come back as `{"agents":{}}`, indistinguishable.
#
# This is the checked variant. It never invents a body. Exit codes:
#   0  JSON on stdout
#   3  no registry file
#   4  file present but unreadable (perms, I/O)
#   5  file read but not parseable as JSON (truncation, partial write)
registry_read_checked() {
  [[ -e "$REGISTRY" ]] || return 3
  local body
  body="$(cat "$REGISTRY" 2>/dev/null)" || return 4
  printf '%s' "$body" | jq -e . >/dev/null 2>&1 || return 5
  printf '%s\n' "$body"
}

# DIVE-1064 stamped the sender's isolation tier into the inter-agent envelope.
# DIVE-2210 is about what that stamp does when it CANNOT be established.
#
# tier= is the one unforgeable field in `[5dive-msg ...]`: from= is caller-supplied
# and only format-validated, so tier= is the field that actually catches a
# cross-tier peer. Every site stamped it as `[[ -n "$t" ]] && header+=" tier=$t"`
# over a lookup whose stderr went to /dev/null — so a missing sudo caller, an
# unreadable registry, malformed JSON and a genuinely untiered sender ALL rendered
# as the field simply not being there. A receiver could not tell "not measured"
# from "measured, nothing to report". That is a fail-open on the only real control,
# and the same not-reached-vs-pass collapse as the v0.16 selfcheck work.
#
# So this never returns empty. A tier we could not establish is stamped
# `unknown:<reason>`, which is a value, is obviously not a tier, and says why.
# Callers append it UNCONDITIONALLY — absence of tier= now means "sent by a build
# that predates this", not "sender has no tier".
envelope_tier() {
  local caller="${1:-}"
  [[ -n "$caller" ]] || { printf 'unknown:no-caller\n'; return 0; }
  local body rc=0
  body="$(registry_read_checked)" || rc=$?
  case "$rc" in
    0) : ;;
    3) printf 'unknown:no-registry\n';          return 0 ;;
    5) printf 'unknown:registry-unparsable\n';  return 0 ;;
    *) printf 'unknown:registry-unreadable\n';  return 0 ;;
  esac
  local t=""
  t="$(printf '%s' "$body" | jq -r --arg n "$caller" '.agents[$n].isolation // empty' 2>/dev/null)" \
    || { printf 'unknown:lookup-failed\n'; return 0; }
  [[ -n "$t" ]] || { printf 'unknown:unregistered\n'; return 0; }
  # The value lands in a SPACE-DELIMITED header. A tier carrying a space would
  # forge additional envelope fields, so anything that is not a bare token is
  # reported as unusable rather than pasted through.
  [[ "$t" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { printf 'unknown:malformed-tier\n'; return 0; }
  printf '%s\n' "$t"
}

registry_write() {
  # stdin -> registry, atomic
  local tmp
  tmp=$(mktemp "${REGISTRY}.XXXXXX")
  cat > "$tmp"
  chown root:claude "$tmp"
  chmod 640 "$tmp"
  mv "$tmp" "$REGISTRY"
}
