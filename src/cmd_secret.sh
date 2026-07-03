# cmd_secret — box-side secret-write primitive (DIVE-930/932, secure credential drop).
#
# The single hardened, allowlisted write-path that lands a credential in the
# box's secret store. Shared by BOTH callers in the DIVE-919 chain:
#   - api (DIVE-930): execOnServer(userId, ['5dive','secret','write',KEY,
#     '--connector='..], {stdin: value})  -> the hosted /drop endpoint.
#   - telegram plugin (DIVE-932): `sudo -n 5dive secret write ...` locally, the
#     burn-after-read safety net for accidental plaintext.
#
# Hard invariants (Marcus ship-gates these hardest, spec:
# community/wiki/secure-credential-drop-link-spec.md):
#   - value crosses on STDIN ONLY, never argv  -> never in ps/process-table,
#     shell history, or the audit log (main.sh audits argv, which omits value).
#   - atomic write: temp file in the same dir + rename; no partial/torn file.
#   - idempotent key update: replace an existing `KEY=` line in place, never
#     blind-append a duplicate.
#   - file perms 600, owner root:claude (connectors dir is root-owned).
#   - value is NEVER echoed back, logged, or persisted anywhere but the target.
#   - embedded newline in the value is REJECTED (would inject extra env lines).
#
# Target (gate answer DIVE-932, 2026-07-03): per-connector file
#   /etc/5dive/connectors/<connector>.env
# ties the secret to the connector that consumes it (matches the existing
# anthropic.env / expo.env layout).

# CONNECTORS_DIR is the hardcoded global from header.sh (/etc/5dive/connectors).
# Intentionally NOT env-overridable — a caller must not be able to redirect where
# a secret lands.
SECRET_WRITE_LOCK="/run/5dive-secret-write.lock"

_secret_usage() {
  cat >&2 <<'EOF'
5dive secret — box-side secret store (secure credential drop, DIVE-919)

  5dive secret write <KEY> --connector=<name> [--task=<DIVE-N>]   (value on STDIN)
      Write/replace KEY in /etc/5dive/connectors/<name>.env. Atomic,
      idempotent, 600 root:claude. The value is read from stdin and never
      appears in argv, logs, or output. Root-only. With --task, a confirmed
      write clears that task's pending secret gate (secure-drop path).

      echo -n "$TOKEN" | sudo 5dive secret write OPENAI_API_KEY --connector=openai
EOF
}

# valid env-var name: leading letter/underscore, then upper alnum/underscore.
# Restricting to this charset also makes it safe to interpolate into the
# `^KEY=` grep pattern below without regex-escaping.
_valid_env_key() { [[ "$1" =~ ^[A-Z_][A-Z0-9_]*$ ]]; }
# connector filename stem: lower alnum + dashes; no dots/slashes -> no path
# traversal, no hidden double-extension.
_valid_connector() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

cmd_secret() {
  [[ $# -gt 0 ]] || { _secret_usage; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    write) _secret_write "$@" ;;
    -h|--help|help) _secret_usage ;;
    *) fail "$E_USAGE" "unknown secret command: $sub (write)" ;;
  esac
}

_secret_write() {
  local key="" connector="" task=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --connector=*) connector="${1#*=}" ;;
      --connector)   connector="${2:-}"; shift ;;
      # DIVE-931: the originating secret gate. On a confirmed write we clear it
      # (equivalent to the "Provided" tap) — a secure drop IS the human providing
      # the credential. Optional: a plain `secret write` (no drop) omits it.
      --task=*)      task="${1#*=}" ;;
      --task)        task="${2:-}"; shift ;;
      --*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)             [[ -z "$key" ]] && key="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done

  require_root secret write
  [[ -n "$key" ]]       || fail "$E_USAGE" "usage: 5dive secret write <KEY> --connector=<name> (value on stdin)"
  [[ -n "$connector" ]] || fail "$E_USAGE" "--connector=<name> is required"
  _valid_env_key "$key"       || fail "$E_USAGE" "invalid KEY '$key' (env-var name: ^[A-Z_][A-Z0-9_]*\$)"
  _valid_connector "$connector" || fail "$E_USAGE" "invalid --connector '$connector' (^[a-z0-9][a-z0-9-]*\$)"

  # Value on stdin ONLY. A tty means no value was piped -> refuse rather than
  # block reading from the keyboard (and rather than accept an empty secret).
  [[ -t 0 ]] && fail "$E_USAGE" "secret value must be piped on stdin (never passed as an argument)"
  local value; value="$(cat)"
  # Strip a single trailing CR/LF pair left by echo / heredocs; preserve any
  # other bytes verbatim.
  value="${value%$'\n'}"; value="${value%$'\r'}"
  [[ -n "$value" ]] || fail "$E_USAGE" "empty secret on stdin — nothing to write"
  # An embedded newline could smuggle additional `EVIL=...` lines into the env
  # file. Reject outright.
  [[ "$value" == *$'\n'* ]] && fail "$E_USAGE" "secret value must be single-line (embedded newline rejected)"

  local target="${CONNECTORS_DIR}/${connector}.env"
  mkdir -p "$CONNECTORS_DIR"; chmod 750 "$CONNECTORS_DIR" 2>/dev/null || true

  # Serialize concurrent writers (two keys into the same file must not lose an
  # update through read-modify-write interleaving). One global lock is plenty at
  # this volume. flock releases when fd 9 closes (process exit or the exec below).
  exec 9>"$SECRET_WRITE_LOCK" || fail "$E_GENERIC" "cannot open secret-write lock"
  flock 9 || fail "$E_GENERIC" "cannot acquire secret-write lock"

  local action="created"
  [[ -f "$target" ]] && grep -qE "^${key}=" "$target" && action="updated"

  # Temp file in the SAME dir so the final mv is a rename (atomic), never a
  # cross-filesystem copy. mktemp is 600 by default; set it explicitly anyway so
  # the secret is never briefly group/world-readable.
  local tmp; tmp="$(mktemp "${target}.XXXXXX")" || fail "$E_GENERIC" "mktemp failed"
  chmod 600 "$tmp"
  # Carry every OTHER key forward; drop the old line for this key (idempotent
  # replace). `|| true`: grep -v exits 1 when the result is empty (file held only
  # this key) — not an error under set -e.
  if [[ -f "$target" ]]; then grep -vE "^${key}=" "$target" > "$tmp" || true; fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
  exec 9>&-

  # DIVE-931 gate auto-resolve: the credential is now safely on the box, so clear
  # the originating secret gate (equivalent to the human tapping "Provided"). We
  # are root here (require_root above) — a sanctioned human-equivalent path, so
  # `task answer` accepts it; --human marks it human-sourced. Shelled out (not an
  # in-process call) so its `fail`/exit on an already-answered or closed gate can
  # NEVER abort this command: the write has succeeded and must report success.
  if [[ -n "$task" ]]; then
    5dive task answer "$task" --human --from=drop >/dev/null 2>&1 || true
  fi

  ok "secret $action: $key -> ${connector}.env" \
     '{connector: $c, key: $k, action: $a, path: $p}' \
     --arg c "$connector" --arg k "$key" --arg a "$action" --arg p "$target"
}
