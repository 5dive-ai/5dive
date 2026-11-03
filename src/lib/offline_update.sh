
# -------- updates by disk: `5dive self-update --from=<file>` (DIVE-7577) --------
#
# A local-only box (an office with nothing allowed out) takes a new release from
# ONE file on a USB stick: 5dive-offline-<version>.tar, built and signed by
# .github/workflows/offline-update.yml and attached to the GitHub release.
#
# WHAT THE FILE IS (packaging/offline/build-offline.sh writes it):
#   manifest.json          {"format":1,"version":"X.Y.Z","arch":"x86_64","created":"…","files":{"payload/…":"<sha256>",…}}
#   manifest.sig           raw ed25519 signature over manifest.json's exact bytes
#   payload/cli.tar.gz     the release tree install.sh reads as REPO=file://…
#   payload/plugins.tar.gz 5dive-plugins with every plugin's node_modules (top dir 5dive-plugins-main/)
#   payload/skills.tar.gz  the skills repo (top dir skills-main/)
#   payload/bun            the bun binary the plugins run on
# Every member is a REGULAR FILE; anything else in the tar is refused before a
# byte is unpacked, so a link can never point the unpack outside the stage.
#
# THE ORDER IS THE SECURITY, and it is the row's order:
#   1. the signature, against the key PINNED ON THIS BOX — never a key the file
#      carries (a file that brings its own key proves only that it is a file);
#   2. every payload file's sha256 against the signed manifest, and the payload
#      set equal to the manifest set — an extra file and a missing one are both
#      refusals;
#   3. the version: older than or equal to the installed one is refused unless
#      --allow-downgrade;
#   then the stage is handed to the SAME installer the online update runs
#   (install.sh --upgrade, REPO=file://<stage>), with every source it would
#   download pointed at the stage and FIVEDIVE_OFFLINE_UPDATE=1 so it dials
#   nothing.
#
# THE SAFE FAILURE IS CHOSEN, NOT INHERITED. Until the release signing key exists
# (a repo admin generates it once, see the workflow header), the key below is
# empty, nothing is pinned, and this verb refuses EVERY file. A box that cannot
# check a signature must not install.

# The release public key, compiled in. EMPTY until a repo admin generates the
# signing key (OFFLINE_UPDATE_SIGNING_KEY on the 5dive repo) and pastes its
# public half here — `openssl pkey -in key.pem -pubout`. install.sh writes it to
# $OFFLINE_UPDATE_PUBKEY_FILE at every install/upgrade (`self-update --write-pubkey`).
OFFLINE_UPDATE_PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAf9KHm4dxpSPYZDHIeDI+mA4yHuPavXzwmsw3+POZW10=
-----END PUBLIC KEY-----'

# >>> DIVE-7577 offline update verifier
#     (tests/self_update_offline_unit.sh extracts this block VERBATIM between
#      these markers and runs the shipped bytes — keep them.)

# The four payload files a bundle of format 1 holds. Fixed, so a signed manifest
# naming something else (a file the installer would never read) is refused too.
_OU_PAYLOAD=(payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz)

_ou_pubkey_file() { printf '%s\n' "${OFFLINE_UPDATE_PUBKEY_FILE:-/etc/5dive/update-pubkey.pem}"; }

# _ou_pinned_key <out> — write the pinned public key to <out>. The box file wins
# (install.sh keeps it equal to the compiled key); the compiled key is the
# fallback for a box whose install predates the file. A box file that someone
# other than root (or the caller) owns, or that group/other can write, is NOT a
# pin and is refused rather than skipped. 1 = no key on this box.
_ou_pinned_key() {
  local out="$1" f; f="$(_ou_pubkey_file)"
  if [[ -e "$f" ]]; then
    local own mode
    own="$(stat -c %u "$f" 2>/dev/null)" || own=""
    mode="$(stat -c %a "$f" 2>/dev/null)" || mode=""
    if [[ "$own" != 0 && "$own" != "$(id -u)" ]] || [[ -z "$mode" ]] || (( (8#$mode & 8#022) != 0 )); then
      _OU_WHY="the update key file $f is not owned by root or is writable by others — it cannot be trusted as the pinned key"
      return 1
    fi
    cp "$f" "$out" 2>/dev/null && [[ -s "$out" ]] && return 0
  fi
  if [[ -n "$OFFLINE_UPDATE_PUBKEY_PEM" ]]; then
    printf '%s\n' "$OFFLINE_UPDATE_PUBKEY_PEM" > "$out" && return 0
  fi
  _OU_WHY="this box holds no update key, so it cannot check any update file (5dive has not published a signed update file yet)"
  return 1
}

_ou_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# _ou_verify <file> <stage> <installed-version> <allow-downgrade 0|1>
# 0 = verified and unpacked: <stage>/payload/* are the signed files and
# _OU_VERSION holds the new version. 1 = refused, _OU_WHY says why in plain
# words. <stage> must be an empty directory the caller owns.
_ou_verify() {
  local file="$1" stage="$2" installed="$3" allow_down="${4:-0}"
  _OU_WHY="" _OU_VERSION=""
  [[ -f "$file" && -r "$file" ]] || { _OU_WHY="no readable file at $file"; return 1; }
  [[ -d "$stage" ]] || { _OU_WHY="internal: no stage directory"; return 1; }
  command -v openssl >/dev/null 2>&1 || { _OU_WHY="openssl is not installed, so the signature cannot be checked"; return 1; }

  # 0. The member list, BEFORE anything is unpacked: regular files only, at the
  #    names format 1 allows, each once.
  local listing line type name
  listing="$(LC_ALL=C tar -tvf "$file" 2>/dev/null)" || { _OU_WHY="this is not an update file (it is not a tar archive)"; return 1; }
  local -A seen=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    type="${line:0:1}"
    name="$(awk '{ $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print }' <<<"$line")"
    name="${name#./}"
    case "$type" in
      d) [[ "$name" == payload/ || "$name" == payload || -z "$name" ]] && continue
         _OU_WHY="the file holds an unexpected folder ($name)"; return 1 ;;
      -) ;;
      *) _OU_WHY="the file holds a link or special file ($name) — refused"; return 1 ;;
    esac
    case "$name" in
      manifest.json|manifest.sig) ;;
      payload/*) ;;
      *) _OU_WHY="the file holds something outside its manifest ($name)"; return 1 ;;
    esac
    [[ -z "${seen[$name]:-}" ]] || { _OU_WHY="the file holds $name twice"; return 1; }
    seen[$name]=1
  done <<<"$listing"
  [[ -n "${seen[manifest.json]:-}" ]] || { _OU_WHY="the file has no manifest"; return 1; }
  [[ -n "${seen[manifest.sig]:-}" ]] || { _OU_WHY="the file is not signed (no signature in it)"; return 1; }

  # 1. The signature, against the PINNED key.
  local meta="$stage/.meta" key
  mkdir -m 700 "$meta" || { _OU_WHY="internal: could not create $meta"; return 1; }
  key="$meta/pinned.pem"
  _ou_pinned_key "$key" || return 1
  tar -xf "$file" -C "$meta" --no-same-owner --no-same-permissions manifest.json manifest.sig 2>/dev/null \
    || { _OU_WHY="could not read the manifest from the file"; return 1; }
  if ! openssl pkeyutl -verify -pubin -inkey "$key" -rawin \
         -in "$meta/manifest.json" -sigfile "$meta/manifest.sig" >/dev/null 2>&1; then
    _OU_WHY="the signature does not match 5dive's update key — the file was changed or was not made by 5dive"
    return 1
  fi

  # 2. The signed manifest, then every payload file against it.
  local m="$meta/manifest.json" ver p want got
  jq -e '.format == 1 and (.version|type == "string") and (.files|type == "object")' "$m" >/dev/null 2>&1 \
    || { _OU_WHY="the manifest is not in a format this 5dive reads"; return 1; }
  ver="$(jq -r '.version' "$m")"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _OU_WHY="the manifest's version '$ver' is not a release version"; return 1; }
  # bun and the plugins' native packages are built for one kind of processor.
  local arch here; arch="$(jq -r '.arch // ""' "$m")"; here="${OFFLINE_UPDATE_ARCH:-$(uname -m)}"
  [[ "$arch" == "$here" ]] || { _OU_WHY="this file is for ${arch:-an unnamed} computers and this box is $here, so it cannot run here"; return 1; }
  local want_set have_set
  want_set="$(jq -r '.files | keys[]' "$m" | LC_ALL=C sort)"
  [[ "$want_set" == "$(printf '%s\n' "${_OU_PAYLOAD[@]}" | LC_ALL=C sort)" ]] \
    || { _OU_WHY="the manifest does not list the four files an update holds"; return 1; }
  have_set="$(printf '%s\n' "${!seen[@]}" | grep '^payload/' | LC_ALL=C sort)" || have_set=""
  [[ "$have_set" == "$want_set" ]] \
    || { _OU_WHY="the files in the update do not match its manifest (one is missing or extra)"; return 1; }
  tar -xf "$file" -C "$stage" --no-same-owner "${_OU_PAYLOAD[@]}" 2>/dev/null \
    || { _OU_WHY="could not unpack the update file (is the disk full?)"; return 1; }
  for p in "${_OU_PAYLOAD[@]}"; do
    [[ -f "$stage/$p" && ! -L "$stage/$p" ]] || { _OU_WHY="$p did not unpack as a plain file"; return 1; }
    want="$(jq -r --arg p "$p" '.files[$p]' "$m")"
    got="$(_ou_sha256 "$stage/$p")"
    [[ "$want" =~ ^[0-9a-f]{64}$ && "$got" == "$want" ]] \
      || { _OU_WHY="$p was changed after the file was signed — refused"; return 1; }
  done

  # 3. The version.
  if [[ "$allow_down" != 1 ]] && [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if [[ "$ver" == "$installed" ]] || version_lt "$ver" "$installed"; then
      _OU_WHY="this file is version $ver and this box already runs $installed — nothing newer to install (--allow-downgrade to install it anyway)"
      return 1
    fi
  fi

  # 4. Unpack the signed tarballs into the stage — trusted now, they matched.
  mkdir -p "$stage/cli" "$stage/plugins" \
    && tar -xzf "$stage/payload/cli.tar.gz" -C "$stage/cli" --no-same-owner 2>/dev/null \
    && tar -xzf "$stage/payload/plugins.tar.gz" -C "$stage/plugins" --no-same-owner --strip-components=1 2>/dev/null \
    || { _OU_WHY="the update's contents could not be unpacked (is the disk full?)"; return 1; }
  local cli_ver
  cli_ver="$(grep -m1 'readonly FIVE_VERSION=' "$stage/cli/5dive" 2>/dev/null | sed -E 's/.*="([^"]+)".*/\1/')" || cli_ver=""
  [[ "$cli_ver" == "$ver" && -f "$stage/cli/install.sh" ]] \
    || { _OU_WHY="the update's 5dive is version '${cli_ver:-none}', not the $ver its manifest names"; return 1; }
  _OU_VERSION="$ver"
  return 0
}

# _ou_installer_env <stage> — the env install.sh --upgrade runs under: every
# source it would download is the stage, and FIVEDIVE_OFFLINE_UPDATE=1 turns off
# the steps that have no offline source (bun install, GitHub ancestry, plugin
# marketplace refresh). One VAR=VALUE per line.
_ou_installer_env() {
  local s="$1" t="file://$1/payload"
  printf '%s\n' "REPO=file://$s/cli" "GH_ORG=${GH_ORG:-5dive-ai}" "FIVEDIVE_OFFLINE_UPDATE=1" \
    "SKILLS_REPO_TARBALL=$t/skills.tar.gz" \
    "CODEX_PLUGIN_TARBALL=$t/plugins.tar.gz" "GROK_PLUGIN_TARBALL=$t/plugins.tar.gz" \
    "AGY_PLUGIN_TARBALL=$t/plugins.tar.gz" "OPENCODE_PLUGIN_TARBALL=$t/plugins.tar.gz" \
    "PI_PLUGIN_TARBALL=$t/plugins.tar.gz" \
    "NOTIFY_USER_SKILL_URL=file://$s/plugins/plugins/telegram/skills/notify-user/SKILL.md"
}

# _ou_replace_tree <src> <dest> — replace <dest> with a copy of <src>, on the
# same filesystem: copy beside it, rename the old away, rename the new in,
# remove the old. The plugin a seat runs is never half old and half new.
_ou_replace_tree() {
  local src="$1" dest="$2" parent base new old
  parent="$(dirname "$dest")"; base="$(basename "$dest")"
  new="$parent/.$base.new.$$"; old="$parent/.$base.old.$$"
  rm -rf "$new" "$old"
  cp -a "$src" "$new" || { rm -rf "$new"; return 1; }
  if [[ -e "$dest" ]]; then mv "$dest" "$old" || { rm -rf "$new"; return 1; }; fi
  mv "$new" "$dest" || { [[ -e "$old" ]] && mv "$old" "$dest"; return 1; }
  rm -rf "$old"
}

# _ou_refresh_checkout <plugins-tree> <checkout> — bring one 5dive-plugins
# marketplace checkout (a seat's, read in place on a local-only box, or the
# claude user's, which new agents are cloned from) to the update's plugins.
# Each plugin folder is replaced whole, the catalog file copied, the owner kept,
# and the result committed so a clone of it carries the new code (a clone takes
# HEAD, not the working tree). 0 = replaced. DIVE-7579 (m1): 3 = replaced, and
# git sees no difference from what it had (the seat need not restart for it).
_ou_refresh_checkout() {
  local src="$1" co="$2" owner d n
  [[ -f "$co/.claude-plugin/marketplace.json" && -d "$src/plugins" ]] || return 1
  owner="$(stat -c '%U:%G' "$co" 2>/dev/null)" || owner=""
  for d in "$src"/plugins/*/; do
    n="$(basename "$d")"
    _ou_replace_tree "${d%/}" "$co/plugins/$n" || return 1
  done
  install -d "$co/.claude-plugin" && cp -f "$src/.claude-plugin/marketplace.json" "$co/.claude-plugin/marketplace.json" || return 1
  [[ -n "$owner" ]] && chown -R "$owner" "$co/plugins" "$co/.claude-plugin" 2>/dev/null
  if [[ -d "$co/.git" ]]; then
    local u="${owner%%:*}" ver="${_OU_VERSION:-}" st
    local -a as=(); [[ -n "$u" && "$u" != "$(id -un)" ]] && as=(sudo -u "$u" -H)
    if "${as[@]}" git -c safe.directory='*' -C "$co" add -A plugins .claude-plugin >/dev/null 2>&1 \
       && st=$("${as[@]}" git -c safe.directory='*' -C "$co" status --porcelain -- plugins .claude-plugin 2>/dev/null) \
       && [[ -z "$st" ]]; then
      return 3
    fi
    "${as[@]}" git -c safe.directory='*' -C "$co" -c user.name=5dive -c user.email=support@5dive.com \
      commit -qm "5dive update from file${ver:+ ($ver)}" >/dev/null 2>&1 || true
  fi
  return 0
}

# _ou_install_bun <stage> — put the update's bun wherever this box has one (the
# system copy and the claude user's), or at /usr/local/bin/bun when it has none.
# Same-dir rename, so a running plugin keeps its open binary. 0 always: a box
# keeps the bun it has when this cannot run.
_ou_install_bun() {
  local b="$1/payload/bun" dest owner
  [[ -s "$b" ]] || return 0
  local -a dests=()
  if [[ -n "${OFFLINE_UPDATE_BUN_DEST:-}" ]]; then dests=("$OFFLINE_UPDATE_BUN_DEST")
  else
    for dest in /usr/local/bin/bun /home/claude/.bun/bin/bun; do [[ -f "$dest" && ! -L "$dest" ]] && dests+=("$dest"); done
    (( ${#dests[@]} )) || dests=(/usr/local/bin/bun)
  fi
  for dest in "${dests[@]}"; do
    cmp -s "$b" "$dest" 2>/dev/null && continue
    owner="$(stat -c '%u:%g' "$dest" 2>/dev/null)" || owner=""
    if install -m 755 "$b" "$dest.new.$$" 2>/dev/null && { [[ -z "$owner" ]] || chown "$owner" "$dest.new.$$" 2>/dev/null || true; } \
       && mv -f "$dest.new.$$" "$dest" 2>/dev/null; then :
    else rm -f "$dest.new.$$"; warn "could not install the update's bun to $dest — keeping the one this box has"; fi
  done
  return 0
}
# <<< DIVE-7577 offline update verifier

# `self-update --write-pubkey` (root, called by install.sh): pin the compiled
# key on the box. A CLI with no key writes nothing and leaves an existing pin.
_ou_write_pubkey() {
  [[ -n "$OFFLINE_UPDATE_PUBKEY_PEM" ]] || return 0
  local f; f="$(_ou_pubkey_file)"
  if install -d -m 755 "$(dirname "$f")" \
     && printf '%s\n' "$OFFLINE_UPDATE_PUBKEY_PEM" > "$f.tmp.$$" \
     && chmod 644 "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; then
    return 0
  fi
  rm -f "$f.tmp.$$"; warn "could not write the update key to $f"
  return 0
}

# -------- a NEW box from a USB stick: `5dive _usb_install` (DIVE-7598) --------
#
# A fresh Ubuntu 24.04 server with no internet becomes a local-only 5dive box
# from one file, 5dive-usb-<version>.run (packaging/offline/build-usb.sh). That
# file's starter (packaging/offline/usb-install.sh) puts in the system packages
# from the stick, then runs THIS verb from the 5dive inside the update file:
#
#   1. the update file is checked exactly as `self-update --from=` checks it
#      (_ou_verify, the key compiled into this CLI — the same key install.sh then
#      pins on the box);
#   2. the local-only switch file is written BEFORE anything is installed, so
#      every refusal holds from the first second (fail closed);
#   3. bun, then the SAME install.sh a `curl install.5dive.ai` runs — a fresh
#      install, not --upgrade — with every source pointed at the file and
#      FIVEDIVE_OFFLINE_UPDATE=1 (install.sh skips each step that has no source
#      in it: Node.js, bun's web installer, package mirrors, the cert pre-warm);
#   4. Claude Code, when the owner put Anthropic's own file on the stick (5dive
#      may not hand it out: its licence is "All rights reserved"), placed where
#      Anthropic's installer puts it, after its checksum matches Anthropic's
#      manifest.json;
#   5. `config local-only on` — the full switch, office chat included.
#
# Test seams: FIVE_USB_CLI (the installed CLI step 5 runs), FIVE_USB_CLAUDE_HOME
# (the claude user's home), FIVE_USB_STAGE_PARENT, FIVE_USB_INSTALLER_SHELL.

# _ou_claude_platform — Anthropic's platform name for this processor.
_ou_claude_platform() {
  case "${OFFLINE_UPDATE_ARCH:-$(uname -m)}" in
    x86_64|amd64) printf 'linux-x64' ;;
    aarch64|arm64) printf 'linux-arm64' ;;
    *) return 1 ;;
  esac
}

# _ou_place_claude <binary> <manifest.json> <home> — check Anthropic's file
# against Anthropic's manifest, then lay it out as their installer does:
# <home>/.local/share/claude/versions/<version> and <home>/.local/bin/claude
# pointing at it. 1 = refused, _OU_WHY says why.
_ou_place_claude() {
  local bin="$1" man="$2" home="$3" plat ver want got owner
  _OU_WHY=""
  [[ -f "$bin" && -s "$bin" ]] || { _OU_WHY="no Claude Code file at $bin"; return 1; }
  [[ -f "$man" ]] || { _OU_WHY="Claude Code's manifest.json is not next to it ($man) — download both files from Anthropic"; return 1; }
  plat="$(_ou_claude_platform)" || { _OU_WHY="this processor ($(uname -m)) has no Claude Code build"; return 1; }
  ver="$(jq -r '.version // empty' "$man" 2>/dev/null)" || ver=""
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _OU_WHY="$man is not Claude Code's manifest (no version in it)"; return 1; }
  want="$(jq -r --arg p "$plat" '.platforms[$p].checksum // empty' "$man" 2>/dev/null)" || want=""
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { _OU_WHY="Claude Code's manifest has no $plat build — download the $plat file"; return 1; }
  got="$(_ou_sha256 "$bin")"
  [[ "$got" == "$want" ]] || { _OU_WHY="the Claude Code file does not match Anthropic's checksum for $plat $ver (wrong file, or damaged)"; return 1; }
  owner="$(stat -c '%u:%g' "$home" 2>/dev/null)" || owner=""
  install -d "$home/.local/share/claude/versions" "$home/.local/bin" \
    && install -m 755 "$bin" "$home/.local/share/claude/versions/$ver" \
    && ln -sfn "$home/.local/share/claude/versions/$ver" "$home/.local/bin/claude" \
    || { _OU_WHY="could not copy Claude Code into $home"; return 1; }
  [[ -n "$owner" ]] && chown -h "$owner" "$home/.local" "$home/.local/share" "$home/.local/share/claude" \
    "$home/.local/share/claude/versions" "$home/.local/share/claude/versions/$ver" "$home/.local/bin" "$home/.local/bin/claude" 2>/dev/null
  _OU_CLAUDE_VERSION="$ver"
  return 0
}

_ou_usb_usage() {
  printf '%s\n' \
    "usage: sudo bash 5dive-usb-<version>.run [--claude=<file>] [--ntp=<office time server>] [--no-chat]" \
    "" \
    "Installs 5dive on this server from the file alone, with no internet, and leaves it" \
    "in local-only mode. --claude is Anthropic's Claude Code file (with its manifest.json" \
    "beside it); a claude file next to the .run file is found by itself."
}

cmd_usb_install() {
  local from="" claude="" man="" a
  local -a lo=()
  for a in "$@"; do
    case "$a" in
      --from=*)   from="${a#--from=}" ;;
      --claude=*) claude="${a#--claude=}" ;;
      --claude-manifest=*) man="${a#--claude-manifest=}" ;;
      --ntp=*|--no-chat) lo+=("$a") ;;
      -h|--help) _ou_usb_usage; return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $a ($(_ou_usb_usage | head -1))" ;;
    esac
  done
  [[ -n "$from" ]] || fail "$E_USAGE" "--from=<5dive-offline-<version>.tar> is required"
  require_root
  [[ -n "$claude" && -z "$man" ]] && man="$(dirname "$claude")/manifest.json"
  local cli="${FIVE_USB_CLI:-/usr/local/bin/5dive}" home="${FIVE_USB_CLAUDE_HOME:-/home/claude}"
  local have=""
  [[ -f "$cli" ]] && have="$(grep -m1 'readonly FIVE_VERSION=' "$cli" 2>/dev/null | sed -E 's/.*="([^"]+)".*/\1/')"

  local parent="${FIVE_USB_STAGE_PARENT:-/var/tmp}" stage
  install -d "$parent" 2>/dev/null || true
  stage=$(mktemp -d "$parent/5dive-usb-stage.XXXXXX") || fail "$E_GENERIC" "could not create a staging folder in $parent"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" RETURN
  step "Checking the 5dive file"
  _ou_verify "$from" "$stage" "" 0 \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "install refused: $_OU_WHY. Nothing was installed."; }
  if [[ "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_lt "$_OU_VERSION" "$have"; then
    rm -rf "$stage"; fail "$E_CONFLICT" "5dive $have is already installed here, newer than this file ($_OU_VERSION). Nothing was changed."
  fi
  step "Signature and every file check out — 5dive $_OU_VERSION"
  # Claude Code is checked BEFORE anything is installed, so a wrong file stops
  # the install with the box untouched.
  if [[ -n "$claude" ]]; then
    local cst; cst=$(mktemp -d "$stage/claude-check.XXXXXX")
    _ou_place_claude "$claude" "$man" "$cst" || { rm -rf "$stage"; fail "$E_VALIDATION" "Claude Code refused: $_OU_WHY. Nothing was installed."; }
    step "Claude Code $_OU_CLAUDE_VERSION checks out against Anthropic's manifest"
  fi

  # 2. the switch, first (the same file and words `config local-only on` writes).
  local flag; flag="$(local_only_file)"
  if [[ ! -e "$flag" ]]; then
    install -d -m 755 "$(dirname "$flag")" \
      && printf 'on since %s — turn off: sudo 5dive config local-only off\n' "$(date -u +%FT%TZ)" > "$flag" \
      && chmod 0644 "$flag" || { rm -rf "$stage"; fail "$E_GENERIC" "could not write $flag"; }
  fi

  # 3. bun, then the installer.
  _ou_install_bun "$stage"
  local -a inst_env=(); mapfile -t inst_env < <(_ou_installer_env "$stage")
  step "Installing 5dive $_OU_VERSION (no internet)"
  env "${inst_env[@]}" "${FIVE_USB_INSTALLER_SHELL:-bash}" "$stage/cli/install.sh" \
    || { rm -rf "$stage"; fail "$E_GENERIC" "the install did not finish (the error is above). Local-only mode is on; run the file again once it is fixed."; }

  # 4. Claude Code.
  if [[ -n "$claude" ]]; then
    _ou_place_claude "$claude" "$man" "$home" || { rm -rf "$stage"; fail "$E_GENERIC" "Claude Code: $_OU_WHY"; }
    step "Claude Code $_OU_CLAUDE_VERSION installed for $home"
  fi
  rm -rf "$stage"

  # 5. the full switch.
  step "Turning on local-only mode"
  local lrc=0
  "$cli" config local-only on "${lo[@]}" || lrc=$?
  printf '\n%s\n' "5dive $_OU_VERSION is installed and local-only: nothing on this server connects outside your network."
  [[ -n "$claude" ]] || printf '%s\n' "Claude Code is not installed: put Anthropic's Claude Code file and its manifest.json on the stick and run the file again (see the guide, \"No internet at all\")."
  printf '%s\n' "Next: add an agent that uses your office AI server:" \
    "  sudo 5dive agent create <name> --type=claude --base-url=http://<AI server on your network>:<port> --model=<model>" \
    "Going online later (for a Claude subscription): sudo 5dive config local-only off"
  return "$lrc"
}
