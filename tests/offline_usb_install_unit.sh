#!/usr/bin/env bash
# DIVE-7598: a fresh server with no internet becomes a local-only 5dive box from
# ONE file on a USB stick, 5dive-usb-<version>.run.
#
# The file is built by the REAL builders (build-offline.sh, then build-usb.sh)
# from throwaway trees and a throwaway signing key, and its REAL starter
# (packaging/offline/usb-install.sh, as the builder fills it in) is run with
# apt-get stubbed and the final 5dive call recorded. The verb the starter hands to,
# `5dive _usb_install`, runs from the SHIPPED src/lib/offline_update.sh against a
# stand-in install.sh that records what it was given.
#
# Arms: B builder (a .run + .sha256; refuses an unsigned update file and a
# missing .deb); S starter (checksum before anything, only the packages the
# server lacks, Claude Code found next to the file, a changed byte refused with
# dpkg never run); U verb (switch file written BEFORE the installer, a FRESH
# install with every source on the stick, Claude Code laid out as Anthropic's
# installer does and checked against Anthropic's manifest before anything is
# installed, the full switch last, a newer installed 5dive refused); G install.sh
# guards (each fresh-install step with no offline source is skipped).
# The time-server value is passed through untouched (RFC 5737 address).
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
finish(){ echo "$PASS passed, $FAIL failed"; exit $(( FAIL > 0 )); }   # fixture aborts
for t in openssl jq dpkg-deb sha256sum; do
  command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }
done
NTP=192.0.2.10

WORK="$(mktemp -d)"; chmod 755 "$WORK"
# ---------------------------------------------------------------- fixtures
t="$WORK/rel"; mkdir -p "$t"/{bin,prompts,hooks,systemd,scripts/git-hooks-portable,.github}
printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="2.0.0"\ncmd_usb_install() { :; }\n' > "$t/5dive"; chmod 755 "$t/5dive"
echo 5dive-agent-start > "$t/bin/host-scripts.manifest"
: > "$t/prompts/team-CLAUDE.md"; : > "$t/hooks/h.sh"; : > "$t/systemd/5dive-agent@.service"
: > "$t/scripts/install-pii-push-guard.sh"; : > "$t/scripts/pii-scan.sh"
: > "$t/scripts/git-hooks-portable/pre-push"; : > "$t/scripts/git-hooks-portable/prepare-commit-msg"
: > "$t/.github/pii-denylist.txt"
cat > "$t/install.sh" <<'INST'
#!/usr/bin/env bash
set -euo pipefail
offline_update() { [[ "${FIVEDIVE_OFFLINE_UPDATE:-0}" == 1 ]]; }
printf '%s\n' "$@" > "$FAKE_OUT/args"
[[ -e "$FIVE_LOCAL_ONLY_FILE" ]] && echo flag-on > "$FAKE_OUT/flag-at-install"
env | grep -E '^(REPO|GH_ORG|FIVEDIVE_OFFLINE_UPDATE|SKILLS_REPO_TARBALL|CODEX_PLUGIN_TARBALL|NOTIFY_USER_SKILL_URL)=' | sort > "$FAKE_OUT/env"
curl -fsSL "$REPO/5dive" -o "$FAKE_OUT/5dive"
INST
P="$WORK/plugins"; mkdir -p "$P/.claude-plugin" "$P/plugins/dashboard"
echo '{"name":"5dive-plugins","plugins":[]}' > "$P/.claude-plugin/marketplace.json"
echo 'x' > "$P/plugins/dashboard/server.ts"
S="$WORK/skills"; mkdir -p "$S/5dive-cli"; echo '# s' > "$S/5dive-cli/SKILL.md"
printf '#!/bin/sh\necho bun-2\n' > "$WORK/bun"; chmod 755 "$WORK/bun"
openssl genpkey -algorithm ed25519 -out "$WORK/key.pem" 2>/dev/null
openssl pkey -in "$WORK/key.pem" -pubout -out "$WORK/pub.pem" 2>/dev/null; chmod 644 "$WORK/pub.pem"

UPD="$(bash packaging/offline/build-offline.sh "$t" "$P" "$S" "$WORK/bun" "$WORK/upd" "$WORK/key.pem" 2>/dev/null)" || UPD=""
UNSIGNED="$(bash packaging/offline/build-offline.sh "$t" "$P" "$S" "$WORK/bun" "$WORK/upd-unsigned" 2>/dev/null)" || UNSIGNED=""
[[ -f "$UPD" && -f "$UNSIGNED" ]] || { bad_t "fixture: build-offline.sh did not build"; finish; }

mkdeb() { # <name> [<depends>] — a tiny real .deb
  local d="$WORK/debsrc/$1"; mkdir -p "$d/DEBIAN"
  { printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@example.com>\n' "$1"
    [[ -n "${2:-}" ]] && printf 'Depends: %s\n' "$2"; printf 'Description: t\n'; } > "$d/DEBIAN/control"
  mkdir -p "$WORK/debs"; dpkg-deb --build --root-owner-group "$d" "$WORK/debs/$1_1.0_all.deb" >/dev/null 2>&1
}
mkdeb fivedive-fake-a fivedive-fake-dep; mkdeb fivedive-fake-dep; mkdeb fivedive-fake-have
[[ -f "$WORK/debs/fivedive-fake-a_1.0_all.deb" ]] || { bad_t "fixture: dpkg-deb could not build a .deb"; finish; }
PKGS="fivedive-fake-a fivedive-fake-have"

# ---------------------------------------------------------------- B: builder
B="packaging/offline/build-usb.sh"
RUN="$(bash "$B" "$UPD" "$WORK/debs" "$PKGS" "$WORK/out" 2>"$WORK/b.err")" || RUN=""
if [[ "$RUN" == "$WORK/out/5dive-usb-2.0.0.run" && -x "$RUN" ]] && (cd "$WORK/out" && sha256sum -c --quiet 5dive-usb-2.0.0.run.sha256); then
  ok_t "B1 builder: 5dive-usb-2.0.0.run and a matching .sha256"
else bad_t "B1 builder" "$(cat "$WORK/b.err")"; finish; fi
if sed '/^__5DIVE_USB_PAYLOAD__$/q' "$RUN" | grep -aq '@@'; then bad_t "B2 starter left a @@ value"
else ok_t "B2 every @@ value is filled in"; fi
if ! bash "$B" "$UNSIGNED" "$WORK/debs" "$PKGS" "$WORK/out-u" >/dev/null 2>"$WORK/e"; then
  grep -q UNSIGNED "$WORK/e" && ok_t "B3 an unsigned update file is refused" || bad_t "B3 wrong reason" "$(cat "$WORK/e")"
else bad_t "B3 built a stick from an unsigned file"; fi
if ! bash "$B" "$UPD" "$WORK/debs" "$PKGS jq" "$WORK/out-m" >/dev/null 2>"$WORK/e"; then
  grep -q 'no .deb for jq' "$WORK/e" && ok_t "B4 a named package with no .deb is refused" || bad_t "B4 wrong reason" "$(cat "$WORK/e")"
else bad_t "B4 built a stick missing a package"; fi

# A release whose 5dive has no USB verb: refused.
t2="$WORK/rel-old"; cp -a "$t" "$t2"; sed -i '/^cmd_usb_install/d' "$t2/5dive"
OLDUPD="$(bash packaging/offline/build-offline.sh "$t2" "$P" "$S" "$WORK/bun" "$WORK/upd-old" "$WORK/key.pem" 2>/dev/null)" || OLDUPD=""
if [[ -f "$OLDUPD" ]] && ! bash "$B" "$OLDUPD" "$WORK/debs" "$PKGS" "$WORK/out-o" >/dev/null 2>"$WORK/e"; then
  grep -q 'predates the USB install' "$WORK/e" && ok_t "B5 an update file whose 5dive predates the USB install is refused" || bad_t "B5 wrong reason" "$(cat "$WORK/e")"
else bad_t "B5 built a stick from a release with no USB verb"; fi

# ---------------------------------------------------------------- S: starter
STUB="$WORK/stub"; mkdir -p "$STUB" "$WORK/dpkgdb"
touch "$WORK/dpkgdb/fivedive-fake-have"
cat > "$STUB/dpkg-query" <<EOF
#!/bin/bash
n="\${@: -1}"; [[ -e "$WORK/dpkgdb/\$n" ]] && printf 'install ok installed' || exit 1
EOF
# apt-get, emulated from what the starter hands it: the one source in the
# -o Dir::Etc::SourceList file, that source's Packages index (each Filename must
# be a file there with the size and SHA256 the index names), dependencies
# resolved through the index. Every call is recorded.
cat > "$STUB/apt-get" <<'APT'
#!/bin/bash
echo "$*" >> "$CALLS"
sl=""; names=(); verb=""
while (( $# )); do
  case "$1" in
    -o) [[ "$2" == Dir::Etc::SourceList=* ]] && sl="${2#*=}"; shift 2; continue ;;
    -*) ;;
    *) if [[ -z "$verb" ]]; then verb="$1"; else names+=("$1"); fi ;;
  esac; shift
done
[[ -f "$sl" ]] || { echo "E: no source list"; exit 100; }
src="$(sed -n 's#^deb \[trusted=yes\] file:\(/[^ ]*\) \./$#\1#p' "$sl")"
[[ -n "$src" && $(wc -l < "$sl") -eq 1 && -f "$src/Packages" ]] || { echo "E: bad source"; exit 100; }
field() { awk -v p="$1" -v f="$2" 'BEGIN{RS="";FS="\n"} {k=0; for(i=1;i<=NF;i++) if($i=="Package: " p) k=1; if(k) for(i=1;i<=NF;i++) if(index($i, f ": ")==1) print substr($i, length(f)+3)}' "$src/Packages"; }
[[ "$verb" == update ]] && { echo updated > "$sl.updated"; exit 0; }
[[ "$verb" == install && -f "$sl.updated" ]] || { echo "E: install before update"; exit 100; }
todo=("${names[@]}")
while (( ${#todo[@]} )); do
  n="${todo[0]}"; todo=("${todo[@]:1}")
  [[ -e "$DPKGDB/$n" ]] && continue
  f="$(field "$n" Filename)"; [[ -n "$f" && -f "$src/$f" ]] || { echo "E: Unable to locate package $n"; exit 100; }
  [[ "$(field "$n" Size)" == "$(stat -c %s "$src/$f")" && "$(field "$n" SHA256)" == "$(sha256sum "$src/$f" | cut -d' ' -f1)" ]] \
    || { echo "E: Hash Sum mismatch $n"; exit 100; }
  touch "$DPKGDB/$n"
  for dep in $(field "$n" Depends | tr ',' ' '); do todo+=("$dep"); done
done
APT
cat > "$STUB/fake-shell" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/cli.args"
[[ -f "\$1" ]] && grep -q 'FIVE_VERSION="2.0.0"' "\$1" && echo bundle-ok >> "$WORK/cli.args"
for a; do [[ "\$a" == --from=* && -f "\${a#--from=}" ]] && echo from-ok >> "$WORK/cli.args"; done
exit 0
EOF
chmod 755 "$STUB"/*
os="$WORK/os-release"; printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$os"
start() { # <run-file> [args] — a copy of the starter with no root check and our os-release
  local f="$1"; shift
  rm -f "$WORK/dpkg.calls" "$WORK/cli.args"
  sed "s#/etc/os-release#$os#g; s#^\[\[ \$EUID -eq 0 \]\] ||#true ||#" "$f" > "$f.t"
  CALLS="$WORK/dpkg.calls" DPKGDB="$WORK/dpkgdb" PATH="$STUB:$PATH" FIVE_USB_SHELL="$STUB/fake-shell" FIVE_USB_WORK_PARENT="$WORK" bash "$f.t" "$@"
}
# The test copy sits beside the real one, so "next to the file" is the same folder.
start "$RUN" --ntp=$NTP >"$WORK/s.out" 2>&1; rc=$?
calls="$(cat "$WORK/dpkg.calls" 2>/dev/null)"
inst="$(grep '^install ' "$WORK/dpkg.calls" 2>/dev/null)"
if (( rc == 0 )) && [[ -e "$WORK/dpkgdb/fivedive-fake-a" && -e "$WORK/dpkgdb/fivedive-fake-dep" \
      && "$inst" == *" fivedive-fake-a"* && "$inst" != *fivedive-fake-have* ]]; then
  ok_t "S1 only the packages this server lacks are installed from the file (one it has is left alone), their dependency through the file's index"
else bad_t "S1 packages" "rc=$rc calls=[$calls] $(tail -5 "$WORK/s.out")"; fi
# apt orders the packages (a bare dpkg -i does not honour Pre-Depends across
# them) and sees ONLY the file: one flat local source with an index of every
# .deb, no other source list or parts, its own empty lists. Not --no-download:
# with it apt 2.7 dies "Pathname to install is not absolute" (CI run 41595689732).
# The stub above refuses a missing/extra source, an index entry whose size or
# SHA256 does not match the .deb, and an install before the update.
if [[ "$(grep -c '^update ' "$WORK/dpkg.calls" 2>/dev/null)" == 1 && "$(sed -n 1p "$WORK/dpkg.calls" 2>/dev/null)" == "update "* \
      && "$calls" != *--no-download* && "$inst" == *"Dir::Etc::SourceList=$WORK/5dive-usb."*"/apt/sources.list "* \
      && "$inst" == *"Dir::Etc::SourceParts=$WORK/5dive-usb."*"/apt/sources.d "* && "$inst" == *"Dir::State::Lists=$WORK/5dive-usb."*"/apt/lists "* ]]; then
  ok_t "S1b the packages go in through apt from one local source made of the file's .debs, nothing else"
else bad_t "S1b apt local source" "calls=[$calls]"; fi
args="$(cat "$WORK/cli.args" 2>/dev/null)"
grep -qx '_usb_install' <<<"$args" && grep -qx 'bundle-ok' <<<"$args" && grep -qx 'from-ok' <<<"$args" && grep -qx -- "--ntp=$NTP" <<<"$args" \
  && ! grep -q -- '--claude=' <<<"$args" \
  && ok_t "S2 hands over to the 5dive inside the update file: _usb_install --from=<it>, --ntp passed on" \
  || bad_t "S2 handover" "$args"
if compgen -G "$WORK/5dive-usb.*" >/dev/null; then bad_t "S3 work folder left behind"; else ok_t "S3 the unpacked copy is removed after"; fi
# Claude Code next to the file.
printf 'claude-bin' > "$WORK/out/claude"; echo '{}' > "$WORK/out/manifest.json"
start "$RUN" >/dev/null 2>&1
grep -qx -- "--claude=$WORK/out/claude" "$WORK/cli.args" 2>/dev/null \
  && ok_t "S4 Anthropic's claude file next to the .run is found by itself" || bad_t "S4 claude not found" "$(cat "$WORK/cli.args" 2>/dev/null)"
rm -f "$WORK/out/manifest.json"
if start "$RUN" >"$WORK/s.out" 2>&1; then bad_t "S5 claude without its manifest accepted"
elif grep -q "manifest.json must be next to" "$WORK/s.out"; then ok_t "S5 claude without Anthropic's manifest.json is refused"
else bad_t "S5 wrong reason" "$(cat "$WORK/s.out")"; fi
rm -f "$WORK/out/claude"
# One byte changed in the payload: refused before dpkg runs.
rm -f "$WORK/dpkgdb/fivedive-fake-a" "$WORK/dpkgdb/fivedive-fake-dep"
cp "$RUN" "$WORK/out/bad.run"; sz=$(stat -c %s "$WORK/out/bad.run")
printf 'Z' | dd of="$WORK/out/bad.run" bs=1 seek=$((sz - 4000)) conv=notrunc 2>/dev/null
start "$WORK/out/bad.run" >"$WORK/s.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'damaged or was changed' "$WORK/s.out" && [[ ! -e "$WORK/dpkg.calls" && ! -e "$WORK/cli.args" ]]; then
  ok_t "S6 one changed byte: refused before any package or 5dive step"
else bad_t "S6 changed file" "rc=$rc $(cat "$WORK/s.out")"; fi
# Another OS lacking packages: refused, nothing installed.
printf 'ID=debian\nVERSION_ID=12\n' > "$os"
if start "$RUN" >"$WORK/s.out" 2>&1; then bad_t "S7 installed packages on a non-24.04 server"
elif grep -q 'not Ubuntu 24.04' "$WORK/s.out" && [[ ! -e "$WORK/dpkg.calls" ]]; then ok_t "S7 a server that is not Ubuntu 24.04 gets no packages from the file"
else bad_t "S7" "$(cat "$WORK/s.out")"; fi
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$os"

# ---------------------------------------------------------------- U: the verb
eval "$(sed -n '/^version_lt() {/,/^}/p' src/cmd_selfupdate.sh)"
warn() { echo "warn: $*" >&2; }
step() { echo "==> $*" >&2; }
fail() { shift; echo "error: $*" >&2; exit 1; }
require_root() { :; }
E_USAGE=2 E_VALIDATION=3 E_CONFLICT=4 E_GENERIC=1
# shellcheck disable=SC1091
. src/lib/offline_update.sh
eval "$(grep -m1 '^local_only_file()' src/lib/local_only.sh)"
declare -F cmd_usb_install >/dev/null && declare -F local_only_file >/dev/null || { bad_t "U0 cmd_usb_install / local_only_file not defined"; finish; }
export OFFLINE_UPDATE_PUBKEY_FILE="$WORK/pub.pem" OFFLINE_UPDATE_ARCH=x86_64
export FIVE_LOCAL_ONLY_FILE="$WORK/etc/5dive/local-only" FIVE_USB_STAGE_PARENT="$WORK/stage"
export FIVE_USB_CLAUDE_HOME="$WORK/home-claude" OFFLINE_UPDATE_BUN_DEST="$WORK/bin-bun"
export FIVE_USB_CLI="$WORK/cli-installed"
mkdir -p "$FIVE_USB_CLAUDE_HOME"
cat > "$WORK/cli-recorder" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/cli.after"
EOF
chmod 755 "$WORK/cli-recorder"
# Anthropic's two files.
CC="$WORK/cc"; mkdir -p "$CC"; printf 'claude-code-binary' > "$CC/claude"
jq -n --arg s "$(sha256sum "$CC/claude" | awk '{print $1}')" '{version:"9.8.7", platforms:{"linux-x64":{checksum:$s, size:18}}}' > "$CC/manifest.json"

verb() { export FAKE_OUT="$WORK/fo"; rm -rf "$FAKE_OUT" "$WORK/cli.after"; mkdir -p "$FAKE_OUT"; ( cmd_usb_install "$@" ) >"$WORK/u.out" 2>&1; }
# The full switch runs from the installed CLI; the stand-in installer writes
# none, so the recorder stands in for it.
rm -f "$FIVE_USB_CLI"; ln -s "$WORK/cli-recorder" "$FIVE_USB_CLI"
verb --from="$UPD" --claude="$CC/claude" --ntp=$NTP; rc=$?
[[ $rc == 0 ]] && ok_t "U1 a good file installs (rc 0)" || bad_t "U1 rc=$rc" "$(cat "$WORK/u.out")"
[[ -s "$FAKE_OUT/flag-at-install" ]] && ok_t "U2 the local-only switch file existed BEFORE the installer ran" || bad_t "U2 switch not on at install time"
[[ -f "$FAKE_OUT/args" && -z "$(tr -d "\n" < "$FAKE_OUT/args")" ]] && ok_t "U3 a FRESH install (install.sh given no --upgrade)" || bad_t "U3 installer args" "$(cat "$FAKE_OUT/args")"
e="$(cat "$FAKE_OUT/env" 2>/dev/null)"
grep -q '^FIVEDIVE_OFFLINE_UPDATE=1$' <<<"$e" && grep -q '^REPO=file://' <<<"$e" && grep -q '^GH_ORG=' <<<"$e" \
  && grep -q '^SKILLS_REPO_TARBALL=file://' <<<"$e" && grep -q '^CODEX_PLUGIN_TARBALL=file://' <<<"$e" \
  && cmp -s "$FAKE_OUT/5dive" "$t/5dive" \
  && ok_t "U4 every source is the file: REPO/tarballs file://, GH_ORG set (no org probe), offline flag on" \
  || bad_t "U4 installer env" "$e"
cmp -s "$WORK/bun" "$OFFLINE_UPDATE_BUN_DEST" && ok_t "U5 bun from the file is in place" || bad_t "U5 bun"
v="$FIVE_USB_CLAUDE_HOME/.local/share/claude/versions/9.8.7"
[[ -x "$v" && "$(readlink "$FIVE_USB_CLAUDE_HOME/.local/bin/claude")" == "$v" ]] && cmp -s "$v" "$CC/claude" \
  && ok_t "U6 Claude Code laid out as Anthropic's installer does (versions/9.8.7, ~/.local/bin/claude)" || bad_t "U6 claude layout" "$(ls -lR "$FIVE_USB_CLAUDE_HOME/.local" 2>&1 | head)"
a="$(cat "$WORK/cli.after" 2>/dev/null)"
[[ "$a" == $'config\nlocal-only\non\n'"--ntp=$NTP" ]] && ok_t "U7 the full switch last: config local-only on --ntp=…" || bad_t "U7 switch call" "$a"
if compgen -G "$FIVE_USB_STAGE_PARENT/*" >/dev/null; then bad_t "U8 stage left behind"; else ok_t "U8 the stage is removed"; fi
# Wrong Claude Code: refused before ANYTHING is installed.
rm -rf "$WORK/etc" "$FIVE_USB_CLAUDE_HOME/.local" "$OFFLINE_UPDATE_BUN_DEST"
printf 'other' > "$CC/claude"
verb --from="$UPD" --claude="$CC/claude"; rc=$?
if (( rc != 0 )) && grep -q "does not match Anthropic's checksum" "$WORK/u.out" && [[ ! -e "$FAKE_OUT/env" && ! -e "$FIVE_LOCAL_ONLY_FILE" && ! -e "$OFFLINE_UPDATE_BUN_DEST" ]]; then
  ok_t "U9 a Claude Code file that does not match Anthropic's manifest stops the install with the box untouched"
else bad_t "U9 wrong claude" "rc=$rc $(cat "$WORK/u.out")"; fi
# An unsigned file: refused, untouched.
verb --from="$UNSIGNED"; rc=$?
if (( rc != 0 )) && grep -q 'not signed' "$WORK/u.out" && [[ ! -e "$FAKE_OUT/env" && ! -e "$FIVE_LOCAL_ONLY_FILE" ]]; then
  ok_t "U10 an unsigned update file is refused, nothing installed"
else bad_t "U10 unsigned" "rc=$rc $(cat "$WORK/u.out")"; fi
# A newer 5dive already installed: refused.
rm -f "$FIVE_USB_CLI"; printf 'readonly FIVE_VERSION="3.0.0"\n' > "$FIVE_USB_CLI"
verb --from="$UPD"; rc=$?
if (( rc != 0 )) && grep -q 'already installed here, newer' "$WORK/u.out" && [[ ! -e "$FAKE_OUT/env" ]]; then
  ok_t "U11 a newer installed 5dive is never replaced by an older stick"
else bad_t "U11 newer installed" "rc=$rc $(cat "$WORK/u.out")"; fi

# ---------------------------------------------------------------- G: install.sh guards
I="install.sh"
g() { if grep -qE -- "$2" "$I"; then ok_t "G $1"; else bad_t "G $1" "no line matching: $2"; fi; }
g "no package-mirror fetch from the file (packages missing → stop, no apt-get update)" '^if \(\( apt_need \)\) && offline_update; then$'
g "Node.js (nvm) is skipped from the file" '^if offline_update; then$'
g "bun's web installer is never run from the file" "^if ! sudo -u claude bash -lc 'command -v bun' >/dev/null 2>&1 && offline_update; then$"
g "the certificate pre-warm is skipped from the file" '^offline_update \|\| 5dive secret _prewarm'
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
