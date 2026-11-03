#!/usr/bin/env bash
# DIVE-7577: `5dive self-update --from=<file>` — one signed file brings a
# local-only box to a new release from a USB disk, and refuses anything
# unsigned or altered.
#
# The file is built by the REAL builder (packaging/offline/build-offline.sh)
# from throwaway trees, signed with a key generated here, and checked by the
# SHIPPED bytes of src/lib/offline_update.sh (sourced whole). The installer the
# verb hands off to is a stand-in that reads every source the way install.sh
# does (curl on the file:// URLs the verb sets) and records what it was given.
#
# Arms (the row's list): good file installs; one byte flipped in any payload
# file; manifest edited; signature missing; signed by another key; older and
# equal version (and --allow-downgrade); a file extra or missing vs the
# manifest; a link member; no key pinned; a pin others can write; the good
# file again under `unshare -n` (no network at all). Then static guards on
# install.sh's offline skips, and a mutant that drops the signature check.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

LIB="$ROOT/src/lib/offline_update.sh"
grep -q '^# >>> DIVE-7577 offline update verifier' "$LIB" && grep -q '^# <<< DIVE-7577 offline update verifier' "$LIB" \
  || { bad_t "verifier fences missing in $LIB"; echo "$PASS passed, $FAIL failed"; exit 1; }

WORK="$(mktemp -d)"; chmod 755 "$WORK"
# ---------------------------------------------------------------- fixtures
mk_release() { # <dir> <version>
  local t="$1" v="$2"
  mkdir -p "$t"/{bin,prompts,hooks,systemd,scripts/git-hooks-portable,.github}
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\n' "$v" > "$t/5dive"; chmod 755 "$t/5dive"
  echo 5dive-agent-start > "$t/bin/host-scripts.manifest"
  : > "$t/prompts/team-CLAUDE.md"; : > "$t/hooks/h.sh"; : > "$t/systemd/5dive-agent@.service"
  : > "$t/scripts/install-pii-push-guard.sh"; : > "$t/scripts/pii-scan.sh"
  : > "$t/scripts/git-hooks-portable/pre-push"; : > "$t/scripts/git-hooks-portable/prepare-commit-msg"
  : > "$t/.github/pii-denylist.txt"
  # The stand-in installer: install.sh's own reads, recorded.
  cat > "$t/install.sh" <<'INST'
#!/usr/bin/env bash
set -euo pipefail
offline_update() { [[ "${FIVEDIVE_OFFLINE_UPDATE:-0}" == 1 ]]; }
[[ "${1:-}" == --upgrade ]]
env | grep -E '^(REPO|GH_ORG|FIVEDIVE_OFFLINE_UPDATE|FIVE_ALLOW_DOWNGRADE|SKILLS_REPO_TARBALL|CODEX_PLUGIN_TARBALL|PI_PLUGIN_TARBALL|NOTIFY_USER_SKILL_URL)=' | sort > "$FAKE_OUT/env"
curl -fsSL "$REPO/5dive" -o "$FAKE_OUT/5dive"
curl -fsSL "$REPO/systemd/5dive-agent%40.service" -o "$FAKE_OUT/unit"
mkdir -p "$FAKE_OUT/dash" "$FAKE_OUT/skill"
curl -fsSL "$CODEX_PLUGIN_TARBALL" | tar -xz -C "$FAKE_OUT/dash" --strip-components=3 '5dive-plugins-main/plugins/dashboard'
curl -fsSL "$SKILLS_REPO_TARBALL" | tar -xz -C "$FAKE_OUT/skill" --strip-components=1 'skills-main/5dive-cli'
curl -fsSL "$NOTIFY_USER_SKILL_URL" -o "$FAKE_OUT/notify.md"
INST
}
mk_release "$WORK/rel2" 2.0.0
P="$WORK/plugins"; mkdir -p "$P/.claude-plugin" "$P/plugins/dashboard/node_modules/left-pad" "$P/plugins/telegram/skills/notify-user"
echo '{"name":"5dive-plugins","plugins":[{"name":"dashboard","source":"./plugins/dashboard"}]}' > "$P/.claude-plugin/marketplace.json"
echo '{"name":"dashboard","dependencies":{"left-pad":"1"}}' > "$P/plugins/dashboard/package.json"
echo '{"name":"left-pad"}' > "$P/plugins/dashboard/node_modules/left-pad/package.json"
echo 'console.log("v2")' > "$P/plugins/dashboard/server.ts"
printf -- '---\nname: notify-user\n---\n' > "$P/plugins/telegram/skills/notify-user/SKILL.md"
S="$WORK/skills"; mkdir -p "$S/5dive-cli"; echo '# 5dive-cli v2' > "$S/5dive-cli/SKILL.md"
printf '#!/bin/sh\necho bun-2\n' > "$WORK/bun"; chmod 755 "$WORK/bun"

openssl genpkey -algorithm ed25519 -out "$WORK/key.pem" 2>/dev/null
openssl pkey -in "$WORK/key.pem" -pubout -out "$WORK/pub.pem" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$WORK/other.pem" 2>/dev/null
chmod 644 "$WORK/pub.pem"
[[ -s "$WORK/key.pem" && -s "$WORK/pub.pem" ]] || { bad_t "openssl could not make an ed25519 key"; echo "$PASS passed, $FAIL failed"; exit 1; }

B="$ROOT/packaging/offline/build-offline.sh"
GOOD="$(bash "$B" "$WORK/rel2" "$P" "$S" "$WORK/bun" "$WORK/out" "$WORK/key.pem" 2>"$WORK/build.err")" || GOOD=""
if [[ "$GOOD" == "$WORK/out/5dive-offline-2.0.0.tar" && -f "$GOOD" ]]; then
  ok_t "builder: a signed 5dive-offline-2.0.0.tar from a release tree, plugins with node_modules, skills, bun"
else
  bad_t "builder did not produce the file" "$(cat "$WORK/build.err")"; echo "$PASS passed, $FAIL failed"; exit 1
fi
mem="$(tar -tf "$GOOD" | tr '\n' ' ')"
[[ "$mem" == "manifest.json manifest.sig payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz " ]] \
  && ok_t "builder: exactly the six regular members, no folders" || bad_t "builder members" "$mem"
# A tag whose installer predates the offline skips is refused (it would dial).
mk_release "$WORK/rel-old" 2.0.0; sed -i '/^offline_update()/d' "$WORK/rel-old/install.sh"
if ! bash "$B" "$WORK/rel-old" "$P" "$S" "$WORK/bun" "$WORK/out-old" "$WORK/key.pem" >/dev/null 2>"$WORK/e"; then
  grep -q 'predates updates from a file' "$WORK/e" && ok_t "builder: a tag whose install.sh predates the offline skips is refused" \
    || bad_t "builder refused an old tag for another reason" "$(cat "$WORK/e")"
else bad_t "builder packaged a tag whose installer would dial out"; fi
# A plugin without its packages is refused at BUILD time (DIVE-7559).
rm -rf "$WORK/p-nodeps"; cp -a "$P" "$WORK/p-nodeps"; rm -rf "$WORK/p-nodeps/plugins/dashboard/node_modules"
if ! bash "$B" "$WORK/rel2" "$WORK/p-nodeps" "$S" "$WORK/bun" "$WORK/out-x" "$WORK/key.pem" >/dev/null 2>"$WORK/e"; then
  grep -q 'dashboard:left-pad' "$WORK/e" && ok_t "builder: a plugin missing node_modules is refused (offline it would dial npm)" \
    || bad_t "builder refusal names no dependency" "$(cat "$WORK/e")"
else bad_t "builder packed a plugin with no node_modules"; fi

# ---------------------------------------------------------------- the verifier
# The shipped bytes, sourced whole; version_lt is cmd_selfupdate.sh's own.
eval "$(sed -n '/^version_lt() {/,/^}/p' "$ROOT/src/cmd_selfupdate.sh")"
declare -F version_lt >/dev/null || { bad_t "version_lt not extractable from src/cmd_selfupdate.sh"; }
warn() { echo "warn: $*" >&2; }
# shellcheck disable=SC1090
. "$LIB"
export OFFLINE_UPDATE_PUBKEY_FILE="$WORK/pub.pem"

verify() { # <file> <installed> [allow-down] — prints the reason, rc of _ou_verify
  local st; st="$(mktemp -d "$WORK/st.XXXXXX")"; LAST_STAGE="$st"
  _ou_verify "$1" "$st" "$2" "${3:-0}"; local rc=$?
  printf '%s\n' "$_OU_WHY" > "$WORK/why"; return $rc
}
refused() { # <label> <file> <installed> <why-substring> [allow-down]
  if verify "$2" "$3" "${5:-0}"; then bad_t "$1" "ACCEPTED — the box would have installed it"
  elif grep -qi -- "$4" "$WORK/why"; then ok_t "$1 — \"$(cat "$WORK/why")\""
  else bad_t "$1 (refused for the wrong reason)" "$(cat "$WORK/why")"; fi
}
# Re-pack the good file with one change. <fn> runs inside the unpacked copy.
repack() { # <name> <fn> [members…] — prints the new path
  local d="$WORK/rp-$1" f="$WORK/$1.tar"; rm -rf "$d"; mkdir -p "$d"
  tar -xf "$GOOD" -C "$d"; ( cd "$d" && "$2" )
  shift 2
  local -a m=("$@"); (( ${#m[@]} )) || m=(manifest.json manifest.sig payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz)
  tar --no-recursion -cf "$f" -C "$d" "${m[@]}"; printf '%s\n' "$f"
}
flip() { python3 -c 'import sys;p=sys.argv[1];b=bytearray(open(p,"rb").read());b[len(b)//2]^=1;open(p,"wb").write(b)' "$1"; }

# 1. GOOD FILE INSTALLS.
if verify "$GOOD" 1.0.0; then
  st="$LAST_STAGE"
  [[ "$_OU_VERSION" == 2.0.0 && -f "$st/cli/install.sh" ]] && ok_t "GOOD: signature, hashes and version accepted (1.0.0 -> 2.0.0)" \
    || bad_t "GOOD: accepted but stage incomplete" "version=$_OU_VERSION"
  mkdir -p "$WORK/fake"; mapfile -t ie < <(_ou_installer_env "$st")
  if env "${ie[@]}" FAKE_OUT="$WORK/fake" bash "$st/cli/install.sh" --upgrade 2>"$WORK/inst.err" \
     && grep -q 'FIVE_VERSION="2.0.0"' "$WORK/fake/5dive" && [[ -f "$WORK/fake/unit" ]] \
     && [[ -f "$WORK/fake/dash/node_modules/left-pad/package.json" ]] \
     && grep -q v2 "$WORK/fake/skill/5dive-cli/SKILL.md" && grep -q '^name: notify-user' "$WORK/fake/notify.md" \
     && grep -qx 'FIVEDIVE_OFFLINE_UPDATE=1' "$WORK/fake/env" && grep -q "^REPO=file://$st/cli$" "$WORK/fake/env"; then
    ok_t "GOOD: the installer reads the new 5dive, the unit, plugins WITH node_modules, skills and notify-user — all from the stage"
  else
    bad_t "GOOD: the installer could not read the stage" "$(cat "$WORK/inst.err"; cat "$WORK/fake/env" 2>/dev/null)"
  fi
  # A seat's checkout: plugin folders replaced whole (a removed file goes), committed.
  co="$WORK/seat/5dive-plugins"; mkdir -p "$co/.claude-plugin" "$co/plugins/dashboard"
  echo '{}' > "$co/.claude-plugin/marketplace.json"; echo old > "$co/plugins/dashboard/server.ts"; echo gone > "$co/plugins/dashboard/stale.ts"
  git -C "$co" init -q && git -C "$co" add -A && git -C "$co" -c user.name=t -c user.email=t@t commit -qm init
  if _ou_refresh_checkout "$st/plugins" "$co" && grep -q v2 "$co/plugins/dashboard/server.ts" \
     && [[ ! -e "$co/plugins/dashboard/stale.ts" && -f "$co/plugins/dashboard/node_modules/left-pad/package.json" ]] \
     && grep -q '2.0.0' <<<"$(git -C "$co" log -1 --format=%s)" && grep -q v2 <<<"$(git -C "$co" show HEAD:plugins/dashboard/server.ts)"; then
    ok_t "GOOD: a seat's plugin checkout is replaced whole and committed (a clone of it gets the new code)"
  else
    bad_t "GOOD: seat checkout not refreshed" "$(ls -la "$co/plugins/dashboard"; git -C "$co" log --oneline | head -3)"
  fi
  export OFFLINE_UPDATE_BUN_DEST="$WORK/bin-bun"; echo old > "$OFFLINE_UPDATE_BUN_DEST"
  _ou_install_bun "$st"; cmp -s "$WORK/bun" "$OFFLINE_UPDATE_BUN_DEST" && [[ -x "$OFFLINE_UPDATE_BUN_DEST" ]] \
    && ok_t "GOOD: the update's bun replaces the box's" || bad_t "GOOD: bun not installed"
  unset OFFLINE_UPDATE_BUN_DEST
else
  bad_t "GOOD: the good file was refused" "$(cat "$WORK/why")"
fi

# 2. ONE BYTE FLIPPED IN ANY PAYLOAD FILE.
for p in bun cli.tar.gz plugins.tar.gz skills.tar.gz; do
  fx() { flip "payload/$FLIP"; }; FLIP="$p"
  refused "FLIP: one byte of payload/$p changed" "$(repack "flip-${p%%.*}" fx)" 1.0.0 "changed after the file was signed"
done
# 3. MANIFEST EDITED (the hash of a tampered file written in, signature kept).
fx() { flip payload/bun; jq --arg h "$(sha256sum payload/bun | awk '{print $1}')" '.files["payload/bun"]=$h' manifest.json > m && mv m manifest.json; }
refused "MANIFEST: edited to match a tampered file" "$(repack manifest fx)" 1.0.0 "signature does not match"
fx() { sed -i 's/"2.0.0"/"9.0.0"/' manifest.json; }
refused "MANIFEST: version edited" "$(repack manifest-ver fx)" 1.0.0 "signature does not match"
# 4. SIGNATURE MISSING.
fx() { :; }
refused "UNSIGNED: no manifest.sig" "$(repack nosig fx manifest.json payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz)" 1.0.0 "not signed"
UNSIGNED="$(bash "$B" "$WORK/rel2" "$P" "$S" "$WORK/bun" "$WORK/out-u" 2>/dev/null)"
refused "UNSIGNED: the builder's own unsigned file (no key yet)" "$UNSIGNED" 1.0.0 "not signed"
# 5. SIGNED BY ANOTHER KEY.
OTHER="$(bash "$B" "$WORK/rel2" "$P" "$S" "$WORK/bun" "$WORK/out-o" "$WORK/other.pem" 2>/dev/null)"
refused "OTHER KEY: a valid signature by a key this box does not pin" "$OTHER" 1.0.0 "signature does not match"
# 6. OLDER / EQUAL VERSION.
refused "OLDER: 2.0.0 onto a box on 3.0.0" "$GOOD" 3.0.0 "already runs 3.0.0"
refused "EQUAL: 2.0.0 onto a box on 2.0.0" "$GOOD" 2.0.0 "already runs 2.0.0"
verify "$GOOD" 3.0.0 1 && ok_t "OLDER with --allow-downgrade: accepted (the override works)" || bad_t "--allow-downgrade refused" "$(cat "$WORK/why")"
# 7. EXTRA / MISSING FILE vs THE MANIFEST.
fx() { echo x > payload/extra; }
refused "EXTRA: a payload file the manifest does not list" "$(repack extra fx manifest.json manifest.sig payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz payload/extra)" 1.0.0 "do not match its manifest"
fx() { :; }
refused "MISSING: a payload file the manifest lists is absent" "$(repack missing fx manifest.json manifest.sig payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz)" 1.0.0 "do not match its manifest"
# 8. A LINK MEMBER (never unpacked: it could point the unpack anywhere).
fx() { ln -s /etc/passwd payload/link; }
refused "LINK: a symlink inside the file" "$(repack link fx manifest.json manifest.sig payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz payload/link)" 1.0.0 "link or special file"
DUP="$WORK/dup.tar"; cp "$GOOD" "$DUP"
( d="$(mktemp -d "$WORK/d.XXXXXX")" && cd "$d" && echo x > manifest.json && tar -rf "$DUP" manifest.json )
refused "DUPLICATE: a second manifest.json appended after the signed one" "$DUP" 1.0.0 "twice"
# 9. NO KEY PINNED / A PIN OTHERS CAN WRITE.
OFFLINE_UPDATE_PUBKEY_FILE="$WORK/none.pem" OFFLINE_UPDATE_PUBKEY_PEM='' refused "NO KEY: a box with no update key refuses every file" "$GOOD" 1.0.0 "holds no update key"
cp "$WORK/pub.pem" "$WORK/loose.pem"; chmod 666 "$WORK/loose.pem"
OFFLINE_UPDATE_PUBKEY_FILE="$WORK/loose.pem" refused "LOOSE PIN: a key file others can write is not a pin" "$GOOD" 1.0.0 "cannot be trusted"
[[ -z "$OFFLINE_UPDATE_PUBKEY_PEM" ]] && ok_t "SHIPPED: the compiled key is empty until the release key exists, so every box refuses every file" \
  || ok_t "SHIPPED: a release key is compiled in"
refused "NOT A TAR: any other file" "$WORK/bun" 1.0.0 "not an update file"
OFFLINE_UPDATE_ARCH=riscv64 refused "ARCH: a file built for another processor" "$GOOD" 1.0.0 "this box is riscv64, so it cannot run here"

# 10. NO NETWORK: the good file again, in a network namespace with only lo.
if [[ $EUID -eq 0 ]]; then NS=(unshare -n); else NS=(sudo -n unshare -n); fi
if "${NS[@]}" true 2>"$WORK/ns.err"; then
  cat > "$WORK/ns-arm.sh" <<NSARM
set -uo pipefail
ifs="\$(awk -F: 'NR>2 {gsub(/ /, "", \$1); print \$1}' /proc/net/dev | tr '\n' ' ')"
[[ "\$ifs" == "lo " ]] || { echo "NETNS: interfaces \$ifs"; exit 3; }
curl -s --max-time 3 -o /dev/null https://github.com 2>/dev/null && { echo "NETNS: network reachable"; exit 3; }
eval "\$(sed -n '/^version_lt() {/,/^}/p' "$ROOT/src/cmd_selfupdate.sh")"
warn() { echo "warn: \$*" >&2; }
. "$LIB"
export OFFLINE_UPDATE_PUBKEY_FILE="$WORK/pub.pem"
st="\$(mktemp -d "$WORK/ns.XXXXXX")"
_ou_verify "$GOOD" "\$st" 1.0.0 0 || { echo "NETNS: refused: \$_OU_WHY"; exit 1; }
mkdir -p "$WORK/ns-fake"; mapfile -t ie < <(_ou_installer_env "\$st")
env "\${ie[@]}" FAKE_OUT="$WORK/ns-fake" bash "\$st/cli/install.sh" --upgrade || { echo "NETNS: installer failed"; exit 1; }
grep -q 'FIVE_VERSION="2.0.0"' "$WORK/ns-fake/5dive" || exit 1
echo NETNS-OK
NSARM
  out="$("${NS[@]}" setpriv --reuid="$(id -u)" --regid="$(id -g)" --clear-groups env HOME="$HOME" PATH="$PATH" bash "$WORK/ns-arm.sh" 2>&1)"
  [[ "$out" == *NETNS-OK* ]] && ok_t "NO NETWORK: verified and installed under unshare -n (only lo, github unreachable)" \
    || bad_t "NO NETWORK arm" "$out"
else
  if [[ "${OU_REQUIRE_NETNS_ARM:-0}" == 1 ]]; then bad_t "NO NETWORK arm could not run (unshare -n unavailable)"
  else printf "skip - NO NETWORK: unshare -n is not available here (%s)\n" "$(head -c 200 "$WORK/ns.err")"; fi
fi

# 11. THE VERB ITSELF: cmd_self_update --from, sourced from src/, with systemd,
#     the box dirs and the seat homes all pointed at this harness.
verb() { # <file> [args…] — runs cmd_self_update in a subshell; output in $WORK/verb.out
  ( set +u
    # shellcheck disable=SC2034  # read by the sourced cmd_self_update / ok()
    readonly FIVE_VERSION=1.0.0; JSON_MODE=0
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/src/lib/error_codes.sh"; . "$ROOT/src/lib/output.sh"
    . "$LIB"; . "$ROOT/src/cmd_selfupdate.sh"
    systemctl() { return 0; }; _team_bot_install_listener() { return 0; }
    local_only_on() { [[ "${VERB_LOCAL_ONLY:-1}" == 1 ]]; }
    export STATE_DIR="$WORK/vstate" HEALTH_GATE_BIN_DIR="$WORK/vbin" HEALTH_GATE_SYSTEMD_DIR="$WORK/vsys"
    export OFFLINE_UPDATE_HOME_ROOT="$WORK/vhome" OFFLINE_UPDATE_BUN_DEST="$WORK/vbin/bun" FAKE_OUT="$WORK/vfake"
    mkdir -p "$STATE_DIR" "$HEALTH_GATE_BIN_DIR" "$HEALTH_GATE_SYSTEMD_DIR" "$FAKE_OUT"
    cmd_self_update "--from=$1" "${@:2}" ) >"$WORK/verb.out" 2>&1
}
vco="$WORK/vhome/agent-ada/.claude/plugins/marketplaces/5dive-plugins"
mkdir -p "$vco/.claude-plugin" "$vco/plugins/dashboard"; echo '{}' > "$vco/.claude-plugin/marketplace.json"; echo old > "$vco/plugins/dashboard/server.ts"
if verb "$GOOD" && grep -q 'update from file complete — 1.0.0 -> 2.0.0' "$WORK/verb.out" \
   && grep -q 'FIVE_VERSION="2.0.0"' "$WORK/vfake/5dive" && grep -q v2 "$vco/plugins/dashboard/server.ts" \
   && grep -q 'plugins updated for agent-ada' "$WORK/verb.out" && cmp -s "$WORK/bun" "$WORK/vbin/bun"; then
  ok_t "VERB: self-update --from installs the good file, updates a seat's plugins and bun, prints 1.0.0 -> 2.0.0"
else bad_t "VERB: the good file did not install through cmd_self_update" "$(tail -15 "$WORK/verb.out")"; fi
! compgen -G "$WORK/vstate/update-stage.*" >/dev/null && ok_t "VERB: the staging folder is removed afterwards" \
  || bad_t "VERB: staging folder left behind" "$(ls -A "$WORK/vstate")"
rm -rf "$WORK/vfake"
if ! verb "$OTHER" && grep -q 'update refused: the signature does not match' "$WORK/verb.out" \
   && grep -q 'Nothing was changed; this box stays on 1.0.0' "$WORK/verb.out" && [[ ! -e "$WORK/vfake/5dive" ]] \
   && ! compgen -G "$WORK/vstate/update-stage.*" >/dev/null; then
  ok_t "VERB: a file signed by another key is refused before the installer runs, in plain words, and leaves no stage"
else bad_t "VERB: other-key file not refused cleanly" "$(tail -5 "$WORK/verb.out")"; fi
# On an online box the seats' checkouts are left for the online update (a local
# commit there would fork their history from GitHub's).
echo old > "$vco/plugins/dashboard/server.ts"; rm -rf "$WORK/vfake"
if VERB_LOCAL_ONLY=0 verb "$GOOD" && grep -q old "$vco/plugins/dashboard/server.ts" \
   && grep -q 'not local-only' "$WORK/verb.out" && grep -q 'FIVE_VERSION="2.0.0"' "$WORK/vfake/5dive"; then
  ok_t "VERB: on a box that is not local-only the CLI installs and seat checkouts are left to the online update"
else bad_t "VERB: online box seat checkout handling" "$(tail -6 "$WORK/verb.out")"; fi
if ! verb "$GOOD" --bogus && grep -q "unknown argument '--bogus'" "$WORK/verb.out"; then ok_t "VERB: an unknown flag is a usage error"
else bad_t "VERB: unknown flag accepted" "$(tail -3 "$WORK/verb.out")"; fi

# ---------------------------------------------------------------- static guards
I="$ROOT/install.sh"
n_bun="$(grep -c 'bun install --production' "$I")" || n_bun=0
n_gated="$(grep -B1 'bun install --production' "$I" | grep -c 'offline_update ||')" || n_gated=0
(( n_bun > 0 && n_bun == n_gated )) && ok_t "install.sh: all $n_bun bun installs are skipped under an update from a file" \
  || bad_t "install.sh: a bun install would dial npm offline" "$n_gated of $n_bun gated"
for fn in build_relation legacy_release_build_sha; do
  grep -q 'offline_update && return 1' <<<"$(sed -n "/^$fn() {/,/^}/p" "$I")" && ok_t "install.sh: $fn makes no GitHub call offline" \
    || bad_t "install.sh: $fn dials GitHub during an update from a file"
done
for s in bin/5dive-refresh-plugins.sh bin/5dive-refresh-skills.sh; do
  out="$(FIVE_LOCAL_ONLY_FILE="$WORK/no-such-flag" FIVEDIVE_OFFLINE_UPDATE=1 bash "$ROOT/$s" 2>&1)"
  [[ "$out" == *"updating from a file"* ]] && ok_t "$s skips during an update from a file" || bad_t "$s ran during an update from a file" "$out"
done
grep -q 'if ! offline_update && \[\[ "$_hp_help" == \*"plugin auto-upgrade"\* \]\]' "$I" \
  && ok_t "install.sh: box plugin auto-upgrade skipped offline" || bad_t "install.sh: plugin auto-upgrade runs offline"

# ---------------------------------------------------------------- mutant
# Drop the signature check: the other-key arm must then go through, which is
# what proves that arm reads the signature and not something incidental.
mut="$(sed '/openssl pkeyutl -verify/,/^  fi$/c\  :' "$LIB")"
if ( eval "$mut"; st="$(mktemp -d "$WORK/m.XXXXXX")"; _ou_verify "$OTHER" "$st" 1.0.0 0 ); then
  ok_t "MUTANT: without the signature check a file signed by another key installs (the OTHER KEY arm would red)"
else
  bad_t "MUTANT: the other-key file was still refused with no signature check" "the arm is not grading the signature"
fi

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
