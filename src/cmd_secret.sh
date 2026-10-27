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
      --connector=tools is the one store every agent reads: the key lands in
      /etc/5dive/connectors/tools.sh and agents see $KEY from their next command
      (one line, no spaces or quotes). Every other connector file is root-only.
      --connector=project-<app> is for an app's own variable (any name): the
      value lands as KEY=value in /home/claude/projects/<app>/.env.local when
      that file exists, else .env, written as the project folder's owner.

  5dive secret link <DIVE-N> [--ttl=<minutes>] [--again]
      Mint a one-time link for an open secret gate: https://secrets.<box>/<token>.
      The owner opens it, pastes, taps once; the value goes from their browser to
      this box only, lands as the gate's KEY, and clears the gate. Single use,
      expires in 30 min by default. Root-only. Returns once the page answers over
      a valid certificate (at most ~20s on a box's first link); --json carries
      ready:false if it did not in time (the link still works a moment later).
      An agent asking while a link for the gate is live (the gate's alert
      carries one) is refused, exit 3; --again mints another anyway.

  5dive secret link --save=<name> [--pair] [--ttl=<minutes>]
      A one-time link for a SAVED login with no task, kept on this box for
      agents to type into a site (DIVE-6844). The name is lowercase letters,
      digits and dashes (github). --pair asks for a login, a password and an
      optional 2FA setup key in one page; without it, one value. A link for a
      name already saved replaces it and never shows the old value. Saved values
      are encrypted with this box's key, /etc/5dive/vault.key, which no export
      or copy carries: on a new box, save them again.
  5dive secret saved [ls] [--json]      each name, its login and its last use;
                                        never a password or a value. Root-only.
  5dive secret saved rm <name>          forget one. Root-only.
      An agent uses one in the browser by name, without seeing it:
      5dive browser act <url> --steps='[{"op":"fill","selector":"…","saved":"<name>.password"}]'
      (<name>.login, <name>.password, or <name>.2fa, which types the current
      code; a bare <name> is a one-value item)
  5dive secret https [status | enable --via=ip|sslip|domain|auto [--host=<name>] | disable]
      A self-hosted box (no 5dive domain) has no https name for those links, so
      its FIRST `secret link` makes one by itself: a Let's Encrypt certificate for
      the box's public IP, else <ip>.sslip.io, served by Caddy on this box (ports
      80 and 443). Nothing about a value passes through 5dive's servers. Behind
      NAT or closed ports neither works: point your own domain at the box and run
      `sudo 5dive secret https enable --via=domain --host=box.example.com`, or use
      `secret write` at a terminal. --via=auto keeps the name the box has, else
      takes those first-link steps. The same front serves the browser's login
      screen (/browser/viewer/). Root-only (status is not).
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

# DIVE-5664: SECRET_PROJECTS_DIR and _secret_project_file live in lib/validation.sh
# (core), because `task need` checks the folder at filing too.

# _secret_project_put <file> <key> — value on stdin. Runs AS THE FOLDER OWNER, not
# root (see _secret_write): a symlink the owner planted can then only reach what
# the owner could already write. Keeps every other line and the file's mode; a
# new file is 640 (the app's group reads it). Atomic: temp file + rename.
# A file the owner cannot READ is refused, never replaced: the owner can still
# rename over it (a root-owned 600 .env.local after a `sudo tee`), and doing so
# would drop every other line in it (DIVE-5664, quinn).
_secret_project_put() {
  local f="$1" key="$2" value tmp rc=0
  value="$(cat)"
  [[ -L "$f" ]] && { echo "$f is a symlink; nothing was saved" >&2; return 3; }
  [[ -e "$f" && ! ( -f "$f" && -r "$f" ) ]] \
    && { echo "$f is not a file $(id -un) can read, so its other lines cannot be kept; nothing was saved" >&2; return 3; }
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  chmod 600 "$tmp"
  # grep -v exits 1 when nothing is left (the file held only this key); 2 is a
  # read error, and writing on would replace the file with the lines it lost.
  if [[ -f "$f" ]]; then
    grep -vE "^(export[[:space:]]+)?${key}=" "$f" > "$tmp" || rc=$?
    (( rc <= 1 )) || { rm -f "$tmp"; echo "could not read $f (grep rc $rc); nothing was saved" >&2; return 1; }
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  # The mode last, once the content is in: a read-only mode copied first would
  # stop the append itself.
  if [[ -f "$f" ]]; then chmod --reference="$f" "$tmp"; else chmod 640 "$tmp"; fi \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

cmd_secret() {
  [[ $# -gt 0 ]] || { _secret_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    write) _secret_write "$@" ;;
    # DIVE-5319: the box-served drop link (src/cmd_secret_drop.sh).
    link)    _secret_link "$@" ;;
    saved)   _secret_saved "$@" ;;   # DIVE-6844
    _reveal) _secret_reveal "$@" ;;  # DIVE-6973: the browser's root hop
    serve)   _secret_serve "$@" ;;
    _peek)   _secret_drop_peek "$@" ;;
    _redeem) _secret_drop_redeem "$@" ;;
    _prewarm) _secret_drop_prewarm "$@" ;;   # DIVE-5372: install.sh
    https)   _secret_https "$@" ;;   # DIVE-7113: https on a self-hosted box
    -h|--help|help) _secret_usage ;;
    *) fail "$E_USAGE" "unknown secret command: $sub (write|link|saved|https|serve)" ;;
  esac
}

# ---- DIVE-6844 / DIVE-6973: the saved store (the owner's Vault) -------------
#
# A login or a detail the owner saves once for agents to type into a site. It is
# one more secret in the store, no new kind: lines in
# /etc/5dive/connectors/saved.env, 600 root, which no agent seat can read (unlike
# tools.sh, which every agent loads). The owner adds or rewrites one through the
# one-time link (`secret link --save=<name> [--pair]`, value phone -> box, never
# through the API), the app lists the NAMES (`secret saved ls`) and removes one
# (`saved rm`). Nothing here ever prints a password, a 2FA key or a one-value
# item. An agent uses one by name in a browser act; the browser's root hop asks
# `secret _reveal` for it and types it in (5dive-browser, DIVE-6844/6973).
#
# DIVE-6973, the item shapes (`__` cannot come from a name: names forbid `--`):
#   one value   KEY=v1:<b64>                       (DIVE-6844's items, unchanged)
#   a pair      KEY__LOGIN=v1:… KEY__PASSWORD=v1:… [KEY__2FA=v1:<base32 seed>]
# Saving one shape under a name drops the other, so a name is one item.
#
# DIVE-6973, encrypted at rest (lodar 03:24Z "can vault be encoded?"). Every
# value line is `v1:` + `openssl enc -aes-256-cbc -pbkdf2` under a per-box key,
# /etc/5dive/vault.key (400 root, 32 random bytes as hex, made on the first
# save). openssl reads the plaintext on STDIN and the key from its file, so no
# value and no key is ever on a command line; a value is decrypted only into a
# pipe or a shell variable, never a file. A plain line (a DIVE-6844 box) is
# encrypted in place the first time any saved verb runs as root.
# WHAT IT IS NOT: a wall against root. Root can read vault.key, so an admin seat
# (the lead, anything with sudo) can decrypt. It keeps the values out of every
# copy of the file (a backup, a tar of /etc/5dive, a support paste); the
# separate-account tip on the save page is the guard against root.
#
# KEY EXCLUSION, and what a team copy does with the Vault (DIVE-6973, decided):
# nothing in this CLI tars or copies /etc/5dive. `agent export` (and the cloud
# move, which copies a team agent by agent) stages from a seat's home only, and
# its tripwire now refuses a stage holding vault.key or a saved.* file by name
# (_PACK_SECRET_FILE_RE, cmd_pack.sh). So the key NEVER travels, and the Vault
# does not move with a team: on a new box the owner saves his logins again (one
# link each). A saved.env carried over by hand without its key reads as names
# whose values `_reveal` refuses ("save it again"), never as garbage typed in.
SECRET_SAVED_CONNECTOR="saved"
SECRET_VAULT_KEY="/etc/5dive/vault.key"
SAVED_ENC_TAG="v1:"
_saved_name_ok() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,39}$ && "$1" != *- && "$1" != *--* ]]; }
_saved_key() { local k="${1^^}"; printf '%s' "${k//-/_}"; }
_saved_name_of() { local n="${1,,}"; printf '%s' "${n//_/-}"; }
_saved_file() { printf '%s/%s.env' "$CONNECTORS_DIR" "$SECRET_SAVED_CONNECTOR"; }
# Which site each saved value is for: the browser binds one on first use
# (5dive-browser, 600 root). A new value or a remove frees it for its next site.
_saved_hosts_file() { printf '%s/%s.hosts' "$CONNECTORS_DIR" "$SECRET_SAVED_CONNECTOR"; }
# DIVE-6973: who used which item, when: `<name> <host> <agent> <utc>` per
# `_reveal`, 600 root, append-only. Never a value.
_saved_usage_file() { printf '%s/%s.usage' "$CONNECTORS_DIR" "$SECRET_SAVED_CONNECTOR"; }
_saved_unbind() {  # <KEY>
  local f tmp; f=$(_saved_hosts_file)
  [[ -f "$f" ]] && grep -qE "^${1}=" "$f" || return 0
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  chmod 600 "$tmp"
  grep -vE "^${1}=" "$f" > "$tmp" || true
  mv -f "$tmp" "$f"
}

# The secret-write lock every saved verb holds across read-modify-write.
_saved_lock() {
  exec 9>"$SECRET_WRITE_LOCK" || fail "$E_GENERIC" "cannot open secret-write lock"
  flock 9 || fail "$E_GENERIC" "cannot acquire secret-write lock"
}
_saved_unlock() { exec 9>&-; }

# The per-box key, made once (lock held). umask 077 from the first byte, 400
# root, renamed into place so a reader never sees half a key.
_vault_key_ensure() {
  local k="$SECRET_VAULT_KEY" tmp
  [[ -s "$k" ]] && return 0
  mkdir -p "$(dirname "$k")" || return 1
  tmp=$(umask 077; mktemp "${k}.XXXXXX") || return 1
  ( umask 077; openssl rand -hex 32 > "$tmp" ) 2>/dev/null || { rm -f "$tmp"; return 1; }
  [[ "$(wc -c < "$tmp")" -ge 64 ]] || { rm -f "$tmp"; return 1; }
  chown root:root "$tmp" 2>/dev/null || true
  chmod 400 "$tmp" && mv -f "$tmp" "$k" || { rm -f "$tmp"; return 1; }
}
# Plaintext on stdin -> `v1:<base64>` on stdout. The key is read from its file.
_vault_enc() {
  local c
  c=$(openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -md sha256 -salt -a -A -pass "file:${SECRET_VAULT_KEY}" 2>/dev/null) \
    && [[ -n "$c" ]] || return 1
  printf '%s%s' "$SAVED_ENC_TAG" "$c"
}
# <v1:…> -> the plaintext on stdout (a pipe or a $(…), never a file).
_vault_dec() {
  [[ "$1" == "$SAVED_ENC_TAG"?* && -r "$SECRET_VAULT_KEY" ]] || return 1
  printf '%s' "${1#"$SAVED_ENC_TAG"}" \
    | openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -md sha256 -a -A -pass "file:${SECRET_VAULT_KEY}" 2>/dev/null
}

# rc 0 = the file still holds a value in the clear.
_saved_has_plain() {
  [[ -f "$1" ]] || return 1
  awk -v t="$SAVED_ENC_TAG" '/^[A-Z][A-Z0-9_]*=/ && substr($0, index($0, "=") + 1, length(t)) != t { f = 1; exit }
    END { exit f ? 0 : 1 }' "$1"
}

# DIVE-6973 migration (lock held, root): encrypt every plain line in place, one
# rename. After it no value is in the file in the clear. Every other line is
# carried as it is.
_saved_migrate() {
  local f; f=$(_saved_file)
  _saved_has_plain "$f" || return 0
  _vault_key_ensure || fail "$E_GENERIC" "could not make the Vault key $SECRET_VAULT_KEY; nothing was changed"
  local tmp line enc
  tmp=$(umask 077; mktemp "${f}.XXXXXX") || fail "$E_GENERIC" "mktemp failed"
  chmod 600 "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ && "${BASH_REMATCH[2]}" != "$SAVED_ENC_TAG"* ]]; then
      local mk="${BASH_REMATCH[1]}"
      enc=$(printf '%s' "${BASH_REMATCH[2]}" | _vault_enc) \
        || { rm -f "$tmp"; fail "$E_GENERIC" "could not encrypt the saved store; nothing was changed"; }
      printf '%s=%s\n' "$mk" "$enc" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$f"
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}

# _saved_put <drop-ere> <KEY> <FIELD=value>... (lock held). Drops the lines the
# ERE names and writes each field encrypted, all in ONE rename, so an item is
# never half written. FIELD is empty for a one-value item ("=value"). The values
# are this function's arguments, in this process: they reach openssl on stdin.
_saved_put() {
  local drop="$1" key="$2"; shift 2
  local f tmp spec fld enc rc=0; f=$(_saved_file)
  _vault_key_ensure || return 1
  mkdir -p "$CONNECTORS_DIR"; chmod 750 "$CONNECTORS_DIR" 2>/dev/null || true
  tmp=$(umask 077; mktemp "${f}.XXXXXX") || return 1
  chmod 600 "$tmp"
  if [[ -f "$f" ]]; then
    grep -vE "$drop" "$f" > "$tmp" || rc=$?
    (( rc <= 1 )) || { rm -f "$tmp"; return 1; }
  fi
  for spec in "$@"; do
    fld="${spec%%=*}"
    enc=$(printf '%s' "${spec#*=}" | _vault_enc) || { rm -f "$tmp"; return 1; }
    printf '%s%s=%s\n' "$key" "${fld:+__$fld}" "$enc" >> "$tmp"
  done
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}

# An authenticator setup key, as the owner copies it (spaces, lower case, an
# otpauth:// link), down to its base32 seed. Empty output = not one.
_saved_2fa_seed() {
  local s="$1"
  [[ "$s" == otpauth://* && "$s" =~ [?\&]secret=([^\&]+) ]] && s="${BASH_REMATCH[1]}"
  s="${s^^}"; s="${s//[[:space:]-]/}"; s="${s//=/}"
  if [[ "$s" =~ ^[A-Z2-7]{16,128}$ ]]; then printf '%s' "$s"; fi
}

# DIVE-6973: a pair item from the save page, on stdin: login, password and the
# 2FA setup key (may be empty), one per line. All of it or nothing; the host the
# name was bound to is freed (a new login may be for a new site). rc 3 = refused.
_saved_write_pair() {
  local key="$1" login="" password="" tfa="" extra="" seed=""
  IFS= read -r login || true
  IFS= read -r password || true
  IFS= read -r tfa || true
  IFS= read -r extra || true
  login="${login%$'\r'}"; password="${password%$'\r'}"; tfa="${tfa%$'\r'}"
  [[ -n "$login" && -n "$password" && -z "$extra" ]] || return 3
  local specs=("LOGIN=$login" "PASSWORD=$password")
  if [[ -n "$tfa" ]]; then
    seed=$(_saved_2fa_seed "$tfa"); [[ -n "$seed" ]] || return 3
    specs+=("2FA=$seed")
  fi
  _saved_lock; _saved_migrate
  _saved_put "^${key}(__(LOGIN|PASSWORD|2FA))?=" "$key" "${specs[@]}" || { _saved_unlock; return 1; }
  _saved_unbind "$key" || true
  _saved_unlock
}

# One record per item, sorted by name, fields joined by \x1f:
#   name, fields (comma list), login (decrypted, control chars dropped),
#   host, lastUsedAt, lastUsedBy.
# Never a password, a 2FA key or a one-value item's value.
_saved_items() {
  local f; f=$(_saved_file)
  [[ -r "$f" ]] || return 0
  local -A one=() lg=() pw=() tf=() host=() at=() by=()
  local line k base
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"
    if [[ "$k" =~ ^(.+)__(LOGIN|PASSWORD|2FA)$ ]]; then
      base="${BASH_REMATCH[1]}"
      case "${BASH_REMATCH[2]}" in
        LOGIN) lg[$base]="${line#*=}" ;; PASSWORD) pw[$base]=1 ;; 2FA) tf[$base]=1 ;;
      esac
    else
      one[$k]=1
    fi
  done < "$f"
  local hf uf; hf=$(_saved_hosts_file); uf=$(_saved_usage_file)
  if [[ -r "$hf" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.+)$ ]] && host[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    done < "$hf"
  fi
  if [[ -r "$uf" ]]; then
    local un uh ua ut
    while read -r un uh ua ut; do
      [[ -n "$ut" ]] || continue
      at[$un]="$ut"; by[$un]="$ua"
    done < "$uf"
  fi
  local keys name fields login
  keys=$(printf '%s\n' "${!one[@]}" "${!lg[@]}" "${!pw[@]}" "${!tf[@]}" | sed '/^$/d' | sort -u)
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    name=$(_saved_name_of "$k"); login=""
    if [[ -n "${lg[$k]+x}${pw[$k]+x}${tf[$k]+x}" ]]; then
      fields="login,password"; [[ -n "${tf[$k]+x}" ]] && fields+=",2fa"
      [[ -n "${lg[$k]+x}" ]] && login=$(_vault_dec "${lg[$k]}") || login=""
      login="${login//[[:cntrl:]]/}"
    else
      fields="value"
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$name" "$fields" "$login" "${host[$k]:-}" "${at[$name]:-}" "${by[$name]:-}"
  done <<<"$keys" | sort -t$'\x1f' -k1,1
}

# "2 hours ago" for an ISO-8601 UTC time.
_saved_ago() {
  local t now d
  t=$(date -u -d "$1" +%s 2>/dev/null) || { printf '%s' "$1"; return; }
  now=$(date -u +%s); d=$(( now - t ))
  if (( d < 60 )); then printf 'just now'
  elif (( d < 3600 )); then printf '%d min ago' $(( d / 60 ))
  elif (( d < 86400 )); then printf '%d h ago' $(( d / 3600 ))
  elif (( d < 172800 )); then printf 'yesterday'
  else printf '%d days ago' $(( d / 86400 )); fi
}

_secret_saved() {
  local sub="${1:-ls}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    ls|list)
      [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive secret saved ls [--json]"
      require_root secret saved
      _saved_lock; _saved_migrate; _saved_unlock
      local recs; recs=$(_saved_items)
      # The records reach jq on a pipe, never as --arg: a login is not a secret,
      # but nothing read out of the store rides a command line.
      if (( JSON_MODE )); then
        printf '%s' "$recs" | jq -cRs '
          [split("\n")[] | select(length > 0) | split("\u001f")
           | {name: .[0], fields: (.[1] | split(",")),
              login: (if .[2] == "" then null else .[2] end),
              host: (if .[3] == "" then null else .[3] end),
              lastUsedAt: (if .[4] == "" then null else .[4] end),
              lastUsedBy: (if .[5] == "" then null else .[5] end)}]
          | {ok: true, data: {names: map(.name), items: .}}'
      elif [[ -z "$recs" ]]; then
        echo "OK — (nothing saved)"
      else
        local n fl lo ho wa wb
        while IFS=$'\x1f' read -r n fl lo ho wa wb; do
          printf '%s%s, %s\n' "$n" "${lo:+ ($lo)}" \
            "$([[ -n "$wa" ]] && printf 'used by %s %s' "${wb:-an agent}" "$(_saved_ago "$wa")" || printf 'not used yet')"
        done <<<"$recs"
      fi ;;
    rm|remove)
      local name="${1:-}"
      [[ $# -eq 1 ]] || fail "$E_USAGE" "usage: 5dive secret saved rm <name>"
      _saved_name_ok "$name" || fail "$E_VALIDATION" "'$name' is not a saved name (lowercase letters, digits and dashes, starting with a letter)"
      require_root secret saved
      local f key tmp uf rc=0; f=$(_saved_file); key=$(_saved_key "$name"); uf=$(_saved_usage_file)
      _saved_lock; _saved_migrate
      [[ -f "$f" ]] && grep -qE "^${key}(__(LOGIN|PASSWORD|2FA))?=" "$f" || fail "$E_NOT_FOUND" "nothing is saved as $name"
      tmp="$(mktemp "${f}.XXXXXX")" || fail "$E_GENERIC" "mktemp failed"
      chmod 600 "$tmp"
      grep -vE "^${key}(__(LOGIN|PASSWORD|2FA))?=" "$f" > "$tmp" || rc=$?
      (( rc <= 1 )) || { rm -f "$tmp"; fail "$E_GENERIC" "could not read $f; nothing was removed"; }
      chown root:claude "$tmp" 2>/dev/null || true
      chmod 600 "$tmp"
      mv -f "$tmp" "$f"
      _saved_unbind "$key" || true
      # Its usage lines go with it: a new item under the name starts "not used yet".
      if [[ -f "$uf" ]]; then
        tmp="$(mktemp "${uf}.XXXXXX")" && chmod 600 "$tmp" \
          && { grep -v "^${name} " "$uf" > "$tmp" || true; } && mv -f "$tmp" "$uf"
      fi
      _saved_unlock
      ok "removed $name" '{removed: $n}' --arg n "$name" ;;
    *) fail "$E_USAGE" "usage: 5dive secret saved [ls] | rm <name>" ;;
  esac
}

# DIVE-6973: `secret _reveal --agent=<seat> --host=<host> <ref>...` (root,
# internal): the browser's root hop asks for what a fill types. ref = <name> (a
# one-value item) | <name>.login | <name>.password | <name>.2fa (the base32
# seed: the hop turns it into the current code, and only the code leaves root).
# stdout: ONE JSON object {"<ref>": "<plaintext>"}, built on a pipe (never a
# --arg, which `ps` shows every seat). One usage line per distinct item name.
# A missing or unreadable ref: an error naming it on stderr, NOTHING on stdout
# and no usage line, whatever --json says.
_secret_reveal() {
  local agent="" host="" refs=() a
  local JSON_MODE=0   # an error here never reaches stdout, whatever --json says
  for a in "$@"; do
    case "$a" in
      --agent=*) agent="${a#*=}" ;;
      --host=*)  host="${a#*=}" ;;
      --json)    ;;
      --*)       fail "$E_USAGE" "unknown flag: $a" ;;
      *)         refs+=("$a") ;;
    esac
  done
  require_root secret _reveal
  (( ${#refs[@]} )) || fail "$E_USAGE" "usage: 5dive secret _reveal --agent=<seat> --host=<host> <name>[.login|.password|.2fa]..."
  [[ "$agent" =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] || fail "$E_USAGE" "--agent=<seat> is required (the seat the value is typed for)"
  [[ -z "$host" || "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})(:[0-9]{1,5})?$ ]] || fail "$E_VALIDATION" "--host '$host' is not a host name"
  local r name
  for r in "${refs[@]}"; do
    [[ "$r" =~ ^[a-z][a-z0-9-]{0,39}(\.(login|password|2fa))?$ ]] && _saved_name_ok "${r%%.*}" \
      || fail "$E_VALIDATION" "'$r' is not a saved name (<name>, <name>.login, <name>.password or <name>.2fa)"
  done
  _saved_lock; _saved_migrate
  local f; f=$(_saved_file)
  local -A enc=()
  local line
  if [[ -r "$f" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] && enc[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    done < "$f"
  fi
  local missing=() k fld
  local -a keys=()
  for r in "${refs[@]}"; do
    k=$(_saved_key "${r%%.*}")
    if [[ "$r" == *.* ]]; then fld="${r#*.}"; k+="__${fld^^}"; fi
    [[ -n "${enc[$k]+x}" ]] || missing+=("$r")
    keys+=("$k")
  done
  (( ${#missing[@]} == 0 )) || { _saved_unlock; fail "$E_NOT_FOUND" "nothing is saved as: ${missing[*]}"; }
  # Decrypt into this shell's memory first, so an unreadable ref is known before
  # anything is printed or logged.
  local -a vals=() unread=()
  local i v
  for i in "${!refs[@]}"; do
    v=$(_vault_dec "${enc[${keys[$i]}]}") || { unread+=("${refs[$i]}"); continue; }
    vals[i]="$v"
  done
  v=""
  if (( ${#unread[@]} )); then
    vals=(); _saved_unlock
    fail "$E_CONFLICT" "cannot read ${unread[*]} on this box (saved under another Vault key, e.g. on another box); ask the owner to save it again"
  fi
  # Plaintext flows printf (a builtin, so no argv) -> a pipe -> jq's stdin.
  local json
  json=$(for i in "${!refs[@]}"; do printf '%s\0%s\0' "${refs[$i]}" "${vals[$i]}"; done \
    | jq -cRs 'split("\u0000") | .[:-1] as $a | reduce range(0; $a | length; 2) as $j ({}; .[$a[$j]] = $a[$j + 1])') \
    || { vals=(); _saved_unlock; fail "$E_GENERIC" "could not build the answer"; }
  vals=()
  local uf now; uf=$(_saved_usage_file); now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ( umask 077; for name in $(printf '%s\n' "${refs[@]%%.*}" | sort -u); do
      printf '%s %s %s %s\n' "$name" "${host:--}" "$agent" "$now"
    done >> "$uf" ) || true
  chmod 600 "$uf" 2>/dev/null || true
  # Append-only, but bounded: past 2000 lines keep the newest 1000.
  if (( $(wc -l < "$uf" 2>/dev/null || echo 0) > 2000 )); then
    local ut; ut=$(mktemp "${uf}.XXXXXX") && chmod 600 "$ut" && tail -n 1000 "$uf" > "$ut" && mv -f "$ut" "$uf"
  fi
  _saved_unlock
  printf '%s\n' "$json"
}

# DIVE-7102: the ident of the one open secret gate naming <key> + <connector>.
_secret_open_gate_for() { # <key> <connector>
  local rows
  declare -F db >/dev/null 2>&1 || return 1
  rows=$(db "SELECT ident FROM tasks WHERE need_type='secret' AND need_answered_at IS NULL
               AND secret_key=$(sqlq "$1") AND connector=$(sqlq "$2") ORDER BY id;" 2>/dev/null) || return 1
  [[ -n "$rows" && "$rows" != *$'\n'* ]] || return 1
  printf '%s' "$rows"
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
  # Before stdin is read: a refused name never asks for its value.
  if [[ "$connector" == tools ]] && _tools_var_reserved "$key"; then
    fail "$E_VALIDATION" "$key is not allowed for --connector=tools: every agent loads tools.sh, so it takes only a key name (ending _KEY, _TOKEN, _SECRET or _PASSWORD, and not a seat's own such as ANTHROPIC_API_KEY); anything else could override $key for every seat on the box. Use the tool's own variable name (e.g. ELEVENLABS_API_KEY), or --connector=project-<app> for one app's variable. Nothing was saved"
  fi
  local pfile=""
  if [[ "$connector" == project-* ]]; then
    pfile="$(_secret_project_file "$connector")" || fail "$E_VALIDATION" "--connector=$connector: $pfile. Nothing was saved"
  fi
  # DIVE-7102: on a self-hosted box the owner types the value on the self-host
  # page and the box's reporter writes it with no --task, so the gate that asked
  # for it would stay open and its agent would never hear. Close the ONE open
  # secret gate naming this exact key and connector; two or more stay as they are.
  if [[ -z "$task" ]] && box_is_chat_only; then
    task=$(_secret_open_gate_for "$key" "$connector") || task=""
  fi

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
  # DIVE-6844: a saved value is typed into one field of a page, so it is one line.
  (( multi )) && [[ "$connector" == "$SECRET_SAVED_CONNECTOR" ]] \
    && fail "$E_VALIDATION" "a saved value is typed into one field, so it must be one line; nothing was saved"

  # DIVE-6973: the saved store is encrypted, one item per name (see above).
  # KEY is a one-value item, KEY__LOGIN|PASSWORD|2FA one field of a pair; either
  # shape replaces the other, and a rewrite frees the name's site.
  if [[ "$connector" == "$SECRET_SAVED_CONNECTOR" ]]; then
    local sbase="$key" sfld="" sdrop action="created"
    if [[ "$key" =~ ^(.+)__(LOGIN|PASSWORD|2FA)$ ]]; then
      sbase="${BASH_REMATCH[1]}"; sfld="${BASH_REMATCH[2]}"
      sdrop="^${sbase}(__${sfld})?="
    else
      sdrop="^${key}(__(LOGIN|PASSWORD|2FA))?="
    fi
    if [[ "$sfld" == 2FA ]]; then
      local sseed; sseed=$(_saved_2fa_seed "$value")
      [[ -n "$sseed" ]] || fail "$E_VALIDATION" "that is not a 2FA setup key (letters A-Z and digits 2-7, as the site shows it); nothing was saved"
      value="$sseed"
    fi
    local sf; sf=$(_saved_file)
    _saved_lock; _saved_migrate
    [[ -f "$sf" ]] && grep -qE "^${key}=" "$sf" && action="updated"
    _saved_put "$sdrop" "$sbase" "${sfld}=${value}" \
      || fail "$E_GENERIC" "could not write the saved store; nothing was saved"
    value=""
    _saved_unbind "$sbase" || true
    _saved_unlock
    _secret_write_done "$key" "$connector" "$action" "$sf" "the saved store (encrypted)" "$task"
    return 0
  fi

  # DIVE-5370: `--connector=tools` is the one store every agent reads: tools.sh,
  # loaded by each agent command through BASH_ENV (DIVE-5366). Every other
  # connector file below is 600 root, which no agent seat can read, so a key an
  # agent asks its owner for through a secret gate's link goes here instead.
  local action="created" where="${connector}.env"
  if [[ "$connector" == tools ]]; then
    [[ " $(_tool_set_vars | tr '\n' ' ') " == *" $key "* ]] && action="updated"
    _tool_put_var "$key" "$value"
    where="every agent's environment, as \$${key}"
    _secret_write_done "$key" "$connector" "$action" "$TOOLS_ENV_FILE" "$where" "$task"
    return 0
  fi

  # DIVE-5664: one app's env file. One line, bare KEY=value, so a value must be
  # one that dotenv, Next's $-expansion and a shell `source` all read the same:
  # no spaces, quotes, $, # or newline. Real API keys fit; anything else is refused
  # rather than written in a form one of those readers would change.
  if [[ -n "$pfile" ]]; then
    [[ "$value" =~ ^[A-Za-z0-9_./:+=@,~-]+$ ]] \
      || fail "$E_VALIDATION" "this value has a character a .env line cannot hold as written (space, quote, \$, # or a newline); nothing was saved — use --connector=<name> and set it in the app yourself"
    [[ -f "$pfile" ]] && grep -qE "^(export[[:space:]]+)?${key}=" "$pfile" 2>/dev/null && action="updated"
    local powner _prc=0
    powner="$(stat -c %U "$(dirname "$pfile")")"
    if [[ "$(id -un)" == "$powner" ]]; then
      printf '%s' "$value" | _secret_project_put "$pfile" "$key" || _prc=$?
    else
      printf '%s' "$value" | runuser -u "$powner" -- bash -c "$(declare -f _secret_project_put); _secret_project_put \"\$@\"" _ "$pfile" "$key" || _prc=$?
    fi
    (( _prc == 0 )) || fail "$E_GENERIC" "could not write $pfile as $powner (rc $_prc); nothing was saved"
    _secret_write_done "$key" "$connector" "$action" "$pfile" "$pfile" "$task"
    return 0
  fi

  local target="${CONNECTORS_DIR}/${connector}.env"
  local vdir="${CONNECTORS_DIR}/${connector}.d"
  local vfile="${vdir}/${key}" pointer="${key}_FILE=${vdir}/${key}"
  mkdir -p "$CONNECTORS_DIR"; chmod 750 "$CONNECTORS_DIR" 2>/dev/null || true

  # Serialize concurrent writers (two keys into the same file must not lose an
  # update through read-modify-write interleaving). One global lock is plenty at
  # this volume. flock releases when fd 9 closes (process exit or the exec below).
  exec 9>"$SECRET_WRITE_LOCK" || fail "$E_GENERIC" "cannot open secret-write lock"
  flock 9 || fail "$E_GENERIC" "cannot acquire secret-write lock"

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
  if (( multi )); then
    where="${connector}.d/${key}"
    _secret_write_done "$key" "$connector" "$action" "$target" "$where" "$task" "$vfile"
  else
    _secret_write_done "$key" "$connector" "$action" "$target" "$where" "$task"
  fi
}

# The tail both stores share: clear the gate, then report where the value is.
_secret_write_done() {
  local key="$1" connector="$2" action="$3" target="$4" where="$5" task="$6" vfile="${7:-}"
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
    (( _ans_rc == 0 )) || warn "saved, but $task was not marked provided (${_ans_out:-rc $_ans_rc}); tell its agent the value is in ${where}"
  fi

  if [[ -n "$vfile" ]]; then
    ok "secret $action: $key -> ${where} (several lines; ${connector}.env names it as ${key}_FILE)" \
       '{connector: $c, key: $k, action: $a, path: $p, value_file: $f}' \
       --arg c "$connector" --arg k "$key" --arg a "$action" --arg p "$target" --arg f "$vfile"
  else
    ok "secret $action: $key -> ${where}" \
       '{connector: $c, key: $k, action: $a, path: $p}' \
       --arg c "$connector" --arg k "$key" --arg a "$action" --arg p "$target"
  fi
}
