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
#   - a value never puts a newline into the .env. DIVE-5384: a multi-line value
#     (PEM key, service-account JSON) lands whole in its own file,
#     /etc/5dive/connectors/<connector>.d/<KEY> (600, value + one newline), and the
#     .env gets ONE line naming it: KEY_FILE=<that path>. The same shape as
#     GITHUB_APP_PRIVATE_KEY_FILE. A single-line value is written exactly as before.
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
5dive secret — box-side secret store (secure credential drop,)

  5dive secret write <KEY> --connector=<name> [--task=<DIVE-N>]   (value on STDIN)
      Write/replace KEY in /etc/5dive/connectors/<name>.env. Atomic,
      idempotent, 600 root:claude. The value is read from stdin and never
      appears in argv, logs, or output. Root-only. With --task, a confirmed
      write clears that task's pending secret gate (secure-drop path).

      echo -n "$TOKEN" | sudo 5dive secret write OPENAI_API_KEY --connector=openai
      A value of several lines (a PEM key, JSON) is saved whole in
      /etc/5dive/connectors/<name>.d/<KEY>, and <name>.env gets KEY_FILE=<that path>.
      Run at a terminal with nothing piped, it asks for the value (hidden input).

  5dive secret link <DIVE-N> [--ttl=<minutes>]
      Mint a one-time link for an open secret gate: https://secrets.<box>/<token>.
      The owner opens it, pastes, taps once; the value goes from their browser to
      this box only, lands as the gate's KEY, and clears the gate. Single use,
      expires in 30 min by default. Root-only.

  5dive secret serve [--listen=127.0.0.1:3127]
      The page behind those links. Started on demand by `secret link`; exits by
      itself once no link is live. Root-only.
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
  [[ $# -gt 0 ]] || { _secret_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    write) _secret_write "$@" ;;
    # DIVE-5319: the box-served drop link (src/cmd_secret_drop.sh).
    link)    _secret_link "$@" ;;
    serve)   _secret_serve "$@" ;;
    _peek)   _secret_drop_peek "$@" ;;
    _redeem) _secret_drop_redeem "$@" ;;
    -h|--help|help) _secret_usage ;;
    *) fail "$E_USAGE" "unknown secret command: $sub (write|link|serve)" ;;
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

  # Value on stdin ONLY, never argv. DIVE-5319: at a terminal (nothing piped) it
  # asks with hidden input, the fallback for a box no owner's browser can reach.
  local value
  if [[ -t 0 ]]; then
    printf 'Paste the value for %s (hidden), then Enter: ' "$key" >&2
    IFS= read -rs value || value=""
    printf '\n' >&2
  else
    value="$(cat)"
  fi
  # Strip a single trailing CR/LF pair left by echo / heredocs; preserve any
  # other bytes verbatim.
  value="${value%$'\n'}"; value="${value%$'\r'}"
  [[ -n "$value" ]] || fail "$E_USAGE" "empty secret on stdin — nothing to write"
  # An embedded newline must never reach the .env: it would smuggle `EVIL=...`
  # lines in. DIVE-5384: such a value goes whole into its own file instead, and
  # the .env names it with one line whose every byte we chose.
  local multi=0
  [[ "$value" == *$'\n'* ]] && multi=1

  local target="${CONNECTORS_DIR}/${connector}.env"
  local vdir="${CONNECTORS_DIR}/${connector}.d"
  local vfile="${vdir}/${key}" pointer="${key}_FILE=${vdir}/${key}"
  mkdir -p "$CONNECTORS_DIR"; chmod 750 "$CONNECTORS_DIR" 2>/dev/null || true

  # Serialize concurrent writers (two keys into the same file must not lose an
  # update through read-modify-write interleaving). One global lock is plenty at
  # this volume. flock releases when fd 9 closes (process exit or the exec below).
  exec 9>"$SECRET_WRITE_LOCK" || fail "$E_GENERIC" "cannot open secret-write lock"
  flock 9 || fail "$E_GENERIC" "cannot acquire secret-write lock"

  local action="created"
  if [[ -f "$target" ]]; then
    grep -qE "^${key}=" "$target" && action="updated"
    grep -qxF "$pointer" "$target" && action="updated"
    (( multi )) && grep -qE "^${key}_FILE=" "$target" && action="updated"
  fi

  if (( multi )); then
    # The value file first, so the .env never names a file that is not there.
    mkdir -p "$vdir"; chown root:claude "$vdir" 2>/dev/null || true; chmod 750 "$vdir" 2>/dev/null || true
    local vtmp; vtmp="$(mktemp "${vfile}.XXXXXX")" || fail "$E_GENERIC" "mktemp failed"
    chmod 600 "$vtmp"
    printf '%s\n' "$value" > "$vtmp"
    chown root:claude "$vtmp" 2>/dev/null || true
    chmod 600 "$vtmp"
    mv -f "$vtmp" "$vfile"
  fi

  # Temp file in the SAME dir so the final mv is a rename (atomic), never a
  # cross-filesystem copy. mktemp is 600 by default; set it explicitly anyway so
  # the secret is never briefly group/world-readable.
  local tmp; tmp="$(mktemp "${target}.XXXXXX")" || fail "$E_GENERIC" "mktemp failed"
  chmod 600 "$tmp"
  # Carry every OTHER key forward; drop the old line for this key (idempotent
  # replace), in either form. A single-line write drops only OUR pointer line, so
  # a key someone else named <KEY>_FILE survives it. `|| true`: grep -v exits 1
  # when the result is empty (file held only this key) — not an error under set -e.
  if [[ -f "$target" ]]; then
    if (( multi )); then
      grep -vE "^${key}(_FILE)?=" "$target" > "$tmp" || true
    else
      grep -vE "^${key}=" "$target" | grep -vxF "$pointer" > "$tmp" || true
    fi
  fi
  if (( multi )); then
    printf '%s\n' "$pointer" >> "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
  # A single line replacing a multi-line value: the old file is no longer named.
  (( multi )) || rm -f "$vfile"
  exec 9>&-

  # DIVE-931 gate auto-resolve: the credential is now safely on the box, so clear
  # the originating secret gate (equivalent to the human tapping "Provided"). We
  # are root here (require_root above) — a sanctioned human-equivalent path, so
  # `task answer` accepts it; --human marks it human-sourced. Shelled out (not an
  # in-process call) so its `fail`/exit on an already-answered or closed gate can
  # NEVER abort this command: the write has succeeded and must report success.
  # DIVE-5319: the write still reports success when the clear is refused (the
  # value IS on the box), but it says so instead of swallowing it. The page path
  # (`secret _redeem`) clears with its own evidence and checks the row itself.
  if [[ -n "$task" ]]; then
    local _ans_out _ans_rc=0
    _ans_out=$(5dive task answer "$task" --human --from=drop 2>&1 >/dev/null) || _ans_rc=$?
    (( _ans_rc == 0 )) || warn "saved, but $task was not marked provided (${_ans_out:-rc $_ans_rc}); tell its agent the value is in ${connector}.env"
  fi

  if (( multi )); then
    ok "secret $action: $key -> ${connector}.d/${key} (several lines; ${connector}.env names it as ${key}_FILE)" \
       '{connector: $c, key: $k, action: $a, path: $p, value_file: $f}' \
       --arg c "$connector" --arg k "$key" --arg a "$action" --arg p "$target" --arg f "$vfile"
  else
    ok "secret $action: $key -> ${connector}.env" \
       '{connector: $c, key: $k, action: $a, path: $p}' \
       --arg c "$connector" --arg k "$key" --arg a "$action" --arg p "$target"
  fi
}
