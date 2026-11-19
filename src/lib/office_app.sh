# -------- the office app: `5dive local app install|status` (DIVE-8809) --------
#
# An Enterprise office server serves its own private copy of the 5dive app (the
# /tg screens, DIVE-8806) at / on the office network. The app comes as ONE file,
# 5dive-office-app-<version>.tar, or inside the private "Office server" download
# (5dive-office-server-<cli>-app-<app>.run: the USB installer with the app file in
# its payload, packaging/offline/build-office.sh). Both go through this file:
#
#   sudo 5dive local app install <file> [--allow-downgrade]   check it, unpack it, serve it
#        5dive local app status                               which app (if any) is served
#
# WHAT THE FILE IS (lodar/5dive-frontend scripts/office/package.sh writes it):
#   manifest.json  {"format":1,"kind":"5dive-office-app","version":"X.Y.Z","arch":"web",
#                   "files":{"payload/app.tar.gz":"<sha256>"},
#                   "app":{"index":"/tg/","fallbacks":[{"prefix":"/tg/chat/","file":"tg/chat/_/index.html"}]},
#                   "trust":{"office_key","office_key_sig","revoked","revoked_sig"} (base64)}
#   manifest.sig   raw ed25519 signature of manifest.json's exact bytes, by the office app key
#   payload/app.tar.gz   the static export
#
# THE ORDER IS THE SECURITY (the update file's order, DIVE-7577):
#   1. members: regular files at the three names, each once, before a byte is unpacked;
#   2. the office app key, CERTIFIED BY 5dive's ROOT for this one purpose (kind
#      5dive-office-app-key — an update key's certificate is refused), not expired,
#      not on the root's revocation list (the highest-serial list this box kept);
#      there is NO pinned-key fallback: a box without the root refuses every app file;
#   3. manifest.sig by that key; kind, arch "web", version, the payload's sha256;
#   4. the version: older than or equal to the served one is refused unless --allow-downgrade;
#   5. the export's own members: files and folders only, no absolute path, no "..";
#   then it is unpacked root-owned into /opt/5dive/office-app/<version>/app and
#   `current` is switched to it in one rename. The chat server reads `current` on
#   every request, so no restart. The previous version stays (one step back).
#
# Test seams: OFFICE_APP_DIR (default /opt/5dive/office-app); the root-key seams of
# src/lib/offline_update.sh (OFFLINE_UPDATE_ROOT_PUBKEY_FILE, _STATE_DIR, _NOW).

_oa_dir() { printf '%s' "${OFFICE_APP_DIR:-/opt/5dive/office-app}"; }

# _oa_installed — the served version, or nothing.
_oa_installed() {
  local m; m="$(_oa_dir)/current/manifest.json"
  [[ -f "$m" ]] || return 0
  jq -r '.version // empty' "$m" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true
}

# _oa_from_run <office-server.run> <dir> — the app file inside a private "Office
# server" download, copied to <dir>; _OA_FILE is its path. 1 = none, _OU_WHY says why.
# The .run's own checksum line is not a signature; the app file carries its own.
_oa_from_run() {
  local run="$1" dir="$2" line names n
  line="$(awk '/^__5DIVE_USB_PAYLOAD__$/ { print NR + 1; exit }' "$run" 2>/dev/null)"
  [[ "$line" =~ ^[0-9]+$ ]] || { _OU_WHY="this is not an office app file or an Office server file"; return 1; }
  tail -n +"$line" "$run" > "$dir/payload.tar" || { _OU_WHY="could not read the Office server file (is the disk full?)"; return 1; }
  names="$(LC_ALL=C tar -tf "$dir/payload.tar" 2>/dev/null | grep -E '^(\./)?5dive-office-app-[0-9]+\.[0-9]+\.[0-9]+\.tar$')" || names=""
  n="$(grep -c . <<<"$names")" || n=0
  (( n == 1 )) || { rm -f "$dir/payload.tar"
    _OU_WHY="$( (( n == 0 )) && echo "this Office server file holds no office app (it is the public installer)" || echo "this Office server file holds more than one office app")"; return 1; }
  tar -xf "$dir/payload.tar" -C "$dir" --no-same-owner --no-same-permissions "$names" 2>/dev/null \
    || { rm -f "$dir/payload.tar"; _OU_WHY="could not unpack the Office server file (is the disk full?)"; return 1; }
  rm -f "$dir/payload.tar"
  [[ -f "$dir/${names#./}" && ! -L "$dir/${names#./}" ]] || { _OU_WHY="the office app in this file did not unpack as a plain file"; return 1; }
  _OA_FILE="$dir/${names#./}"
}

# _oa_verify <file> <stage> <installed-version> <allow-downgrade 0|1>
# 0 = verified: <stage>/app is the export, <stage>/manifest.json its signed
# manifest, _OA_VERSION the version. 1 = refused, _OU_WHY says why in plain words.
_oa_verify() {
  local file="$1" stage="$2" installed="$3" allow_down="${4:-0}"
  _OU_WHY="" _OA_VERSION="" _OU_NOT_NEWER=0
  [[ -f "$file" && -r "$file" ]] || { _OU_WHY="no readable file at $file"; return 1; }
  [[ -d "$stage" ]] || { _OU_WHY="internal: no stage directory"; return 1; }
  command -v openssl >/dev/null 2>&1 || { _OU_WHY="openssl is not installed, so the signature cannot be checked"; return 1; }

  # 1. Members, before anything is unpacked.
  local listing line name
  listing="$(LC_ALL=C tar -tvf "$file" 2>/dev/null)" || { _OU_WHY="this is not an office app file (it is not a tar archive)"; return 1; }
  local -A seen=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="$(awk '{ $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print }' <<<"$line")"; name="${name#./}"
    [[ "${line:0:1}" == - ]] || { _OU_WHY="the file holds a folder, link or special file ($name) — refused"; return 1; }
    case "$name" in manifest.json|manifest.sig|payload/app.tar.gz) ;;
      *) _OU_WHY="the file holds something an office app file does not ($name)"; return 1 ;; esac
    [[ -z "${seen[$name]:-}" ]] || { _OU_WHY="the file holds $name twice"; return 1; }
    seen[$name]=1
  done <<<"$listing"
  [[ -n "${seen[manifest.json]:-}" ]] || { _OU_WHY="the file has no manifest"; return 1; }
  [[ -n "${seen[manifest.sig]:-}" ]] || { _OU_WHY="the file is not signed (no signature in it)"; return 1; }
  [[ -n "${seen[payload/app.tar.gz]:-}" ]] || { _OU_WHY="the file holds no app"; return 1; }

  # 2. The office app key, through the root only.
  local meta="$stage/.meta" root rrc=0
  mkdir -m 700 "$meta" || { _OU_WHY="internal: could not create $meta"; return 1; }
  root="$meta/root.pem" _OU_KEEP_REVOKED=""
  _ou_root_key "$root" || rrc=$?
  (( rrc != 2 )) || return 1
  (( rrc == 0 )) || { _OU_WHY="this server holds no 5dive root key, so it cannot check an office app file — update 5dive first"; return 1; }
  tar -xf "$file" -C "$meta" --no-same-owner --no-same-permissions manifest.json manifest.sig 2>/dev/null \
    || { _OU_WHY="could not read the manifest from the file"; return 1; }
  # A plain update file (or anything else) says so plainly, before its certificate does.
  jq -e '.kind == "5dive-office-app"' "$meta/manifest.json" >/dev/null 2>&1 \
    || { _OU_WHY="this is not an office app file (an update file goes in the Update screen or self-update)"; return 1; }
  _ou_chain "$meta" "$root" office_key || return 1

  # 3. The signature, the manifest, the payload.
  _ou_sig_ok "$meta/certified.pem" "$meta/manifest.json" "$meta/manifest.sig" \
    || { _OU_WHY="the signature does not match the office app key 5dive's root key certified — the file was changed or was not made by 5dive"; return 1; }
  local m="$meta/manifest.json" ver want got
  jq -e '.format == 1 and .kind == "5dive-office-app" and .arch == "web" and (.version|type == "string")
         and (.files|type == "object") and ((.files|keys) == ["payload/app.tar.gz"])
         and ((.app.index // "/") | type == "string" and test("^/[A-Za-z0-9._/-]*$") and (test("\\.\\.")|not))
         and ((.app.fallbacks // []) | type == "array" and all(.[]; (.prefix|type == "string" and test("^/[A-Za-z0-9._/-]+/$"))
              and (.file|type == "string" and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$") and (test("(^|/)\\.\\.(/|$)")|not))))' "$m" >/dev/null 2>&1 \
    || { _OU_WHY="the manifest is not an office app manifest this 5dive reads"; return 1; }
  ver="$(jq -r '.version' "$m")"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _OU_WHY="the manifest's version '$ver' is not a release version"; return 1; }
  tar -xf "$file" -C "$meta" --no-same-owner --no-same-permissions payload/app.tar.gz 2>/dev/null \
    || { _OU_WHY="could not unpack the app (is the disk full?)"; return 1; }
  want="$(jq -r '.files["payload/app.tar.gz"]' "$m")"; got="$(_ou_sha256 "$meta/payload/app.tar.gz")"
  [[ "$want" =~ ^[0-9a-f]{64}$ && "$got" == "$want" ]] || { _OU_WHY="the app was changed after the file was signed — refused"; return 1; }

  # 4. The version.
  if [[ "$allow_down" != 1 && "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if [[ "$ver" == "$installed" ]] || version_lt "$ver" "$installed"; then
      _OU_WHY="this is office app $ver and this server already serves $installed — nothing newer to install"
      _OU_NOT_NEWER=1; return 1
    fi
  fi

  # 5. The export's members (signed, but still never unpacked outside the stage).
  local inner
  inner="$(LC_ALL=C tar -tzvf "$meta/payload/app.tar.gz" 2>/dev/null)" || { _OU_WHY="the app inside the file is damaged"; return 1; }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="$(awk '{ $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print }' <<<"$line")"
    case "${line:0:1}" in -|d) ;; *) _OU_WHY="the app holds a link or special file ($name) — refused"; return 1 ;; esac
    [[ "$name" != /* && "/$name/" != */../* ]] || { _OU_WHY="the app holds a path outside its folder ($name) — refused"; return 1; }
  done <<<"$inner"
  mkdir -m 755 "$stage/app" && tar -xzf "$meta/payload/app.tar.gz" -C "$stage/app" --no-same-owner --no-same-permissions 2>/dev/null \
    || { _OU_WHY="could not unpack the app (is the disk full?)"; return 1; }
  local idx; idx="$(jq -r '.app.index // "/"' "$m")"; idx="${idx#/}"
  [[ -f "$stage/app/${idx}index.html" || -f "$stage/app/$idx" ]] || { _OU_WHY="the app has no start page (${idx:-index.html})"; return 1; }
  cp "$m" "$stage/manifest.json"
  _ou_keep_revoked
  _OA_VERSION="$ver"
  return 0
}

# `local app install <file> [--allow-downgrade]` (root).
_oa_install() {
  require_root
  local file="" allow=0 a
  for a in "$@"; do
    case "$a" in
      --allow-downgrade) allow=1 ;;
      -*) fail "$E_USAGE" "local app install: unknown option '$a'." ;;
      *) [[ -z "$file" ]] || fail "$E_USAGE" "local app install: one file at a time."; file="$a" ;;
    esac
  done
  [[ -n "$file" ]] || fail "$E_USAGE" "usage: sudo 5dive local app install <5dive-office-app-X.Y.Z.tar | 5dive-office-server-….run>"
  _oa_install_file "$file" "$allow" || fail "$E_GENERIC" "office app not installed: $_OU_WHY"
  ok "office app $_OA_VERSION installed — your team opens it at the office address (the old page stays at /lite)" \
    '{installed: $v}' --arg v "$_OA_VERSION"
}

# _oa_install_file <file> <allow-downgrade> — 0 installed (_OA_VERSION), 1 refused (_OU_WHY).
# The panel's Update screen calls this too (src/cmd_local_panel.sh).
_oa_install_file() {
  local file="$1" allow="${2:-0}" dir work rc=0 app installed prev
  dir="$(_oa_dir)"
  [[ ! -L "$dir" ]] || { _OU_WHY="$dir is a link — refused"; return 1; }
  install -d -m 755 -o root -g root "$dir" 2>/dev/null || install -d -m 755 "$dir" \
    || { _OU_WHY="could not create $dir"; return 1; }
  work="$(mktemp -d "$dir/.stage.XXXXXX")" || { _OU_WHY="could not write in $dir (is the disk full?)"; return 1; }
  app="$file"
  if [[ "$(head -c 2 "$file" 2>/dev/null)" == '#!' ]]; then
    _oa_from_run "$file" "$work" || { rm -rf "$work"; return 1; }
    app="$_OA_FILE"
  fi
  installed="$(_oa_installed)"
  mkdir -m 700 "$work/s"
  _oa_verify "$app" "$work/s" "$installed" "$allow" || rc=1
  if (( rc == 0 )); then
    local v="$_OA_VERSION" dest="$dir/$_OA_VERSION"
    chmod -R u=rwX,go=rX "$work/s/app" && chown -R 0:0 "$work/s/app" "$work/s/manifest.json" 2>/dev/null
    chmod 644 "$work/s/manifest.json"
    prev="$(readlink "$dir/current" 2>/dev/null)" || prev=""
    if [[ -e "$dest" ]]; then mv -T "$dest" "$work/old" || rc=1; fi
    if (( rc == 0 )) && install -d -m 755 "$work/new" && mv "$work/s/app" "$work/new/app" && mv "$work/s/manifest.json" "$work/new/manifest.json" \
       && chmod 755 "$work/new" && mv -T "$work/new" "$dest" \
       && ln -sfn "$v" "$dir/.current.new" && mv -T "$dir/.current.new" "$dir/current"; then
      # Keep the one served before (one step back); remove the rest.
      local d n
      for d in "$dir"/*/; do
        n="$(basename "$d")"
        [[ "$n" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$n" != "$v" && "$n" != "$prev" ]] && rm -rf -- "${d%/}"
      done
      _OA_VERSION="$v"
    else
      [[ -e "$work/old" && ! -e "$dest" ]] && mv -T "$work/old" "$dest"
      _OU_WHY="could not put the app in place in $dir (is the disk full?)"; rc=1
    fi
  fi
  rm -rf "$work"
  return "$rc"
}

# `local app status` — any user.
_oa_status() {
  local v; v="$(_oa_installed)"
  if [[ -n "$v" ]]; then
    ok "office app $v is served at / (the old page stays at /lite)" '{installed: $v}' --arg v "$v"
  else
    ok "no office app installed — the office chat page is served at / (install one: sudo 5dive local app install <file>)" '{installed: null}'
  fi
}

_oa_cmd() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    install) _oa_install "$@" ;;
    status)  _oa_status ;;
    ""|-h|--help|help) printf '%s\n' \
      "usage: sudo 5dive local app install <file> [--allow-downgrade]   # the office app file, or the Office server file" \
      "            5dive local app status" ;;
    *) fail "$E_USAGE" "local app: unknown subcommand '$sub' (install, status)." ;;
  esac
}
