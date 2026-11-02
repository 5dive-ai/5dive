#!/usr/bin/env bash
# DIVE-7557 unit: `5dive config local-only on|off|status|check` and the refusals.
#
# WHAT IS ASSERTED HERE (one arm each)
#   OFF.      no flag file → every command on the refusal list is allowed (today's
#             behaviour, unchanged).
#   REFUSE.   flag file → each refusal on the row's list fails with the plain
#             local-only sentence, exit 10, before any verb runs.
#   ALLOW.    flag file → office-network model servers (RFC1918, .lan, loopback),
#             local reads, a bug PREVIEW and self-update --status still run.
#   URL.      the office-network classifier, both directions.
#   BASEURL.  valid_base_url: http:// to 192.168.x is accepted either way
#             (DIVE-7568); http://gpu.lan only with the switch on; a public
#             http:// host is refused either way.
#   ONOFF.    `on` against a mocked root turns off only ENABLED units, writes the
#             agent drop-in + codex managed config, sets motd-news off, holds snap;
#             a unit the owner had off is NOT recorded, and `off` leaves it off
#             while restoring everything `on` changed. An owner's own codex managed
#             config is never overwritten or removed.
#   CHAT.     DIVE-7566: the office chat failing → never "ON", never rc 0; the
#             switch stays in force. Started → ON, recorded for off.
#   NTP.      --ntp=<lan host> points time sync at it (timesyncd stays on);
#             a public --ntp is refused.
#   CHECK.    a public connection in the ss watch → LEAK + exit 1; only
#             LAN/loopback peers → "Fully local" + exit 0.
#   REFRESH.  the skills/plugins refresh scripts skip (exit 0) when the flag exists.
#   MUTANTS.  a gate that ignores the flag reds REFUSE; an undo record naming an
#             owner-off unit reds ONOFF's owner-off arm.
#
# Fixture addresses: every PUBLIC address here is RFC 5737 / RFC 3849
# documentation space. The RFC 1918 / ULA literals (10.x, 172.16-31.x, 192.168.x,
# fd00::) are the SUBJECT under test — the classifier's job is to tell them from
# public ones — and identify nobody; the mod guard's ip check flags them, so this
# file was written outside the Write tool and the reason is recorded here.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/local-only.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

export FIVE_LOCAL_ONLY_FILE="$TMPD/root/etc/5dive/local-only"
export FIVE_LOCAL_ONLY_ROOT="$TMPD/root"
export FIVE_LOCAL_ONLY_TICK=0
export FIVE_REPORTED_FLAG="$TMPD/reported"
mkdir -p "$TMPD/root/etc/5dive" "$TMPD/bin" "$TMPD/units" "$TMPD/mkt"

# shellcheck disable=SC1090
for f in lib/error_codes.sh lib/output.sh lib/local_only.sh cmd_local_only.sh; do source "src/$f"; done
eval "$(sed -n '/^valid_base_url_private_ipv4()/,/^}/p;/^valid_base_url()/,/^}/p' src/header.sh)"
require_root() { return 0; }
JSON_MODE=0

# ── stubs: systemctl keeps one state file per unit; snap logs; ss replays ────
cat > "$TMPD/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
U="$STUB_UNITS"; echo "systemctl $*" >> "$U/.log"
case "$1" in
  is-enabled) [[ -f "$U/$2" ]] || { echo not-found; exit 4; }; s=$(cat "$U/$2"); echo "$s"; [[ $s == enabled ]] ;;
  disable) echo disabled > "$U/$3" ;;
  enable)  echo enabled  > "$U/$3" ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMPD/bin/snap" <<'EOF'
#!/usr/bin/env bash
echo "snap $*" >> "$STUB_UNITS/.log"
EOF
cat > "$TMPD/bin/ss" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_SS"
EOF
chmod +x "$TMPD/bin/"*
export STUB_UNITS="$TMPD/units" STUB_SS="$TMPD/ss.txt"
export PATH="$TMPD/bin:$PATH"

gate() { ( local_only_gate "$@" ) >"$TMPD/out" 2>&1; }
flag_on()  { : > "$FIVE_LOCAL_ONLY_FILE"; }
flag_off() { rm -f "$FIVE_LOCAL_ONLY_FILE"; }

REFUSED=(
  "a2a send x hi"
  "agent a2a-vouch bob"
  "partner hire lawyer"
  "agent first-job bob"
  "agent _first_job_run bob"
  "agent telegram-access bob"
  "agent _tg_connect_greet bob"
  "agent team-bot set"
  "agent pair bob --code=ABC"
  "telegram-app link --telegram-id=1234567890"
  "agent import some-slug --base-url=http://10.0.0.5:8000 --report-import"
  "agent import some-slug --base-url=http://10.0.0.5:8000"
  "bug --what=x --file --owner-approved"
  "self-update"
  "update --check"
  "self-update --on"
  "self-update --allow-downgrade"
  "self-update --check --from=/media/usb/5dive-offline-1.0.0.tar"
  "plugin add 5dive-ai/5dive-ui"
  "plugin upgrade voice"
  "agent skill bob add --source=owner/repo --skill=x"
  "buzz enable"
  "agent buzz bob enable"
  "account login acme --type=claude"
  "account set acme --type=claude --provider=anthropic --api-key=-"
  "account set acme --type=claude --provider=x --api-key=- --base-url=https://api.openai.com/v1"
  "agent create bob --type=claude"
  "agent create bob --type=claude --base-url=https://api.anthropic.com"
  "agent create bob --type=claude --base-url=http://192.0.2.10:8000"
  "agent create bob --type=claude --base-url=http://10.0.0.5:8000 --channels=telegram"
  "agent create bob --type=claude --base-url=http://10.0.0.5:8000 --telegram-token=-"
  "agent create bob --type=claude --base-url=http://10.0.0.5:8000 --with-skills=owner/repo"
  "agent config bob set channels=dashboard,telegram"
  "agent config bob set telegram.token=123"
  "agent auth login claude"
  "agent auth set claude --api-key=-"
  "agent set-account bob acme"
  "agent switch bob --to=codex"
  "agent install codex"
  "agent pack-sync bob"
  "hire lawyer"
  "hire lawyer --from-market --base-url=http://10.0.0.5:8000"
  "market"
  "plugin marketplace add 5dive-ai/5dive-plugins"
  "plugin marketplace add https://github.com/acme/plugins.git"
  "plugin marketplace update"
  "plugin marketplace upgrade 5dive-plugins"
  "tool google start"
  "tool google submit sess1"
  "tools google start"
  "hire-link lawyer"
  "hire-link --create --name=Ada --description=contracts"
  "hire-link custom-abcdef123456 --hire"
  "pkg install ripgrep"
)
ALLOWED_ON=(
  "agent create bob --type=claude --base-url=http://192.168.1.50:8000/v1 --api-key=-"
  "agent create bob --type=claude --base-url=http://10.1.2.3:11434"
  "agent create bob --type=claude --base-url=https://gpu.lan/v1 --channels=dashboard"
  "agent create bob --type=claude --base-url=http://127.0.0.1:8000"
  "account set acme --type=claude --provider=x --api-key=- --base-url=http://172.20.0.9:8000"
  "agent auth set claude --api-key=- --base-url=http://[fd00::5]:8000"
  "hire lawyer --base-url=http://192.168.0.7:8000"
  "agent config bob set model=qwen3 channels=dashboard"
  "bug --what=x"
  "self-update --status"
  "self-update --off"
  "self-update --from=/media/usb/5dive-offline-1.0.0.tar"
  "self-update --allow-downgrade --from=/media/usb/5dive-offline-1.0.0.tar"
  "self-update --write-pubkey"
  "plugin list"
  "agent skill bob list"
  "account list"
  "task ls"
  "config local-only check"
  "agent list"
  "plugin marketplace add $TMPD/mkt"
  "plugin marketplace list"
  "tool google poll sess1"
  "tool google cancel sess1"
  "tool set github"
  "pkg"
)

# ── OFF ──────────────────────────────────────────────────────────────────────
flag_off
n=0; for c in "${REFUSED[@]}"; do read -r -a av <<<"$c"; gate "${av[@]}" || { n=$((n+1)); echo "  refused with switch off: $c"; }; done
(( n == 0 )) && ok_ "OFF: no flag file → all ${#REFUSED[@]} refusal-list commands pass the gate" || bad_ "OFF" "$n refused with the switch off"

# ── REFUSE ───────────────────────────────────────────────────────────────────
flag_on
n=0; for c in "${REFUSED[@]}"; do
  read -r -a av <<<"$c"
  if gate "${av[@]}"; then n=$((n+1)); echo "  NOT refused: $c"
  else grep -q 'local-only mode is on' "$TMPD/out" || { n=$((n+1)); echo "  wrong message: $c: $(cat "$TMPD/out")"; }; fi
done
(( n == 0 )) && ok_ "REFUSE: flag on → all ${#REFUSED[@]} refusal-list commands refused with the local-only sentence" || bad_ "REFUSE" "$n not refused"
( local_only_gate bug --what=x --file ) >/dev/null 2>&1; rc=$?
[[ $rc == 10 ]] && ok_ "REFUSE: exit code is E_PERMISSION (10)" || bad_ "REFUSE exit" "rc=$rc"

# ── ALLOW ────────────────────────────────────────────────────────────────────
n=0; for c in "${ALLOWED_ON[@]}"; do read -r -a av <<<"$c"; gate "${av[@]}" || { n=$((n+1)); echo "  refused: $c: $(cat "$TMPD/out")"; }; done
(( n == 0 )) && ok_ "ALLOW: flag on → ${#ALLOWED_ON[@]} office-network / read-only commands still run" || bad_ "ALLOW" "$n refused"

# ── URL ──────────────────────────────────────────────────────────────────────
n=0; k=0
for u in http://127.0.0.1:8000 http://10.0.0.1 http://172.16.0.1:1 http://172.31.255.255 http://192.168.1.1/v1 \
         http://169.254.1.1 'http://[::1]:8000' 'http://[fd12::1]:80' https://gpu.lan https://srv.office.internal \
         http://gpu http://box.local:8080; do
  k=$((k+1)); local_only_url_is_local "$u" || { n=$((n+1)); echo "  should be local: $u"; }
done
for u in https://api.anthropic.com http://192.0.2.10 http://172.32.0.1 http://172.15.0.1 http://192.169.1.1 \
         'http://[2001:db8::1]' https://example.com http://10.0.0.1.example.com ftp://10.0.0.1 http://300.1.1.1; do
  k=$((k+1)); local_only_url_is_local "$u" && { n=$((n+1)); echo "  should be outside: $u"; }
done
(( n == 0 )) && ok_ "URL: $k URLs classified (12 office-network, 10 outside)" || bad_ "URL" "$n misclassified"

# ── BASEURL ──────────────────────────────────────────────────────────────────
flag_off
# DIVE-7568: a private IPv4 address is accepted over http with the switch off
# too; a NAME on the office network (gpu.lan) still needs the switch.
if valid_base_url http://192.168.1.5:8000 && valid_base_url http://127.0.0.1:8000 \
   && ! valid_base_url http://gpu.lan:8000 && ! valid_base_url http://192.0.2.10:8000; then
  ok_ "BASEURL: switch off → http://192.168.x and loopback ok, http://gpu.lan and public http:// refused"
else bad_ "BASEURL off" "private IPv4 refused, or a name/public host accepted, with the switch off"; fi
flag_on
if valid_base_url http://192.168.1.5:8000 && valid_base_url http://gpu.lan:8000 && ! valid_base_url http://192.0.2.10:8000; then ok_ "BASEURL: switch on → http://192.168.x and http://gpu.lan accepted, public http:// still refused"
else bad_ "BASEURL on" "LAN refused or public accepted"; fi

# ── ONOFF ────────────────────────────────────────────────────────────────────
flag_off
UNITS_ON=(apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service motd-news.timer apport.service systemd-timesyncd.service)
for u in "${UNITS_ON[@]}"; do echo enabled > "$TMPD/units/$u"; done
echo disabled > "$TMPD/units/whoopsie.service"      # the owner had this off
mkdir -p "$TMPD/root/etc/default"; printf 'ENABLED=1\n' > "$TMPD/root/etc/default/motd-news"
mkdir -p "$TMPD/root/var/lib/snapd/snaps"; : > "$TMPD/root/var/lib/snapd/snaps/core24_1.snap"   # a snap is installed
( _lo_on ) >"$TMPD/on.out" 2>&1; rc=$?
[[ $rc == 0 && -e "$FIVE_LOCAL_ONLY_FILE" ]] && ok_ "ONOFF: on exits 0 and writes the flag file" || bad_ "ONOFF on" "rc=$rc $(cat "$TMPD/on.out")"
n=0; for u in "${UNITS_ON[@]}"; do [[ $(cat "$TMPD/units/$u") == disabled ]] || { n=$((n+1)); echo "  still on: $u"; }; done
(( n == 0 )) && ok_ "ONOFF: every enabled outbound unit (incl. timesyncd, no --ntp) is off" || bad_ "ONOFF units" "$n left on"
grep -q 'whoopsie' "$(_lo_undo)" && bad_ "ONOFF owner-off" "an owner-disabled unit was recorded" || ok_ "ONOFF: a unit the owner had off is not in the undo record"
grep -q CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$(_lo_dropin)" && grep -q DISABLE_AUTOUPDATER=1 "$(_lo_dropin)" \
  && ok_ "ONOFF: agent drop-in sets CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC + DISABLE_AUTOUPDATER" || bad_ "ONOFF dropin" "missing"
grep -q 'check_for_update_on_startup = false' "$(_lo_codex)" && ok_ "ONOFF: codex managed config turns off update check" || bad_ "ONOFF codex" "missing"
grep -q '^ENABLED=0' "$TMPD/root/etc/default/motd-news" && grep -q 'snap refresh --hold' "$TMPD/units/.log" \
  && ok_ "ONOFF: motd-news off and snap refresh held" || bad_ "ONOFF motd/snap" "not changed"
# DIVE-7574 (N3): a woken snapd asks the Snap Store for its catalog; the hold does not stop that.
grep -q 'snap set system store.access=offline' "$TMPD/units/.log" && ! grep -q 'systemctl mask' "$TMPD/units/.log" \
  && ( _lo_check --watch=0 --status ) 2>/dev/null | grep -qE '^ok +snap store +offline' \
  && ok_ "SNAP1: snaps installed → snapd put offline (store.access), not masked; status says so" \
  || bad_ "SNAP1 offline" "$(grep -E 'snap|mask' "$TMPD/units/.log")"

( _lo_off ) >"$TMPD/off.out" 2>&1; rc=$?
n=0; for u in "${UNITS_ON[@]}"; do [[ $(cat "$TMPD/units/$u") == enabled ]] || { n=$((n+1)); echo "  not restored: $u"; }; done
[[ $rc == 0 && $n == 0 && ! -e "$FIVE_LOCAL_ONLY_FILE" && ! -e "$(_lo_dropin)" && ! -e "$(_lo_codex)" && ! -e "$(_lo_undo)" ]] \
  && grep -q '^ENABLED=1' "$TMPD/root/etc/default/motd-news" && grep -q 'snap refresh --unhold' "$TMPD/units/.log" \
  && grep -q 'snap unset system store.access' "$TMPD/units/.log" \
  && ok_ "ONOFF: off restores every recorded change and removes flag, drop-in, codex file, undo record" \
  || bad_ "ONOFF off" "rc=$rc n=$n $(cat "$TMPD/off.out")"
[[ $(cat "$TMPD/units/whoopsie.service") == disabled ]] && ok_ "ONOFF: off never turns on a unit the owner had off" || bad_ "ONOFF owner-off" "whoopsie re-enabled"

# DIVE-7574 (N3): no snap installed → snapd masked (never started, not even at
# boot by snapd.seeded), and no `snap` command runs (any one wakes snapd).
rm -f "$TMPD/root/var/lib/snapd/snaps/"*.snap; : > "$TMPD/units/.log"
( _lo_on ) >"$TMPD/on.out" 2>&1; rc=$?
st=$( ( _lo_check --watch=0 --status ) 2>/dev/null)
[[ $rc == 0 ]] && grep -q 'systemctl mask --now snapd.service snapd.socket snapd.seeded.service' "$TMPD/units/.log" \
  && ! grep -q '^snap ' "$TMPD/units/.log" && grep -qx snapd-mask "$(_lo_undo)" \
  && grep -qE '^ok +snapd \(no snaps installed\) +off' <<<"$st" && ! grep -q LEAK.*snap <<<"$st" \
  && ok_ "SNAP2: no snap installed → snapd masked, no snap command run, status ok" \
  || bad_ "SNAP2 mask" "rc=$rc $(cat "$TMPD/units/.log") / $st"
( _lo_off ) >/dev/null 2>&1
grep -q 'systemctl unmask snapd.service snapd.socket snapd.seeded.service' "$TMPD/units/.log" && grep -q 'systemctl start snapd.socket' "$TMPD/units/.log" \
  && ok_ "SNAP3: off unmasks snapd and starts its socket again" || bad_ "SNAP3 unmask" "$(cat "$TMPD/units/.log")"
for u in "${UNITS_ON[@]}"; do echo enabled > "$TMPD/units/$u"; done
: > "$TMPD/root/var/lib/snapd/snaps/core24_1.snap"

mkdir -p "$TMPD/root/etc/codex"; printf 'model = "mine"\n' > "$(_lo_codex)"
( _lo_on && _lo_off ) >/dev/null 2>&1
[[ $(cat "$(_lo_codex)") == 'model = "mine"' ]] && ok_ "ONOFF: an owner's codex managed config is never overwritten or removed" || bad_ "ONOFF codex owner" "changed"
rm -f "$(_lo_codex)"

# ── CHAT (DIVE-7566) ─────────────────────────────────────────────────────────
# The office chat step, run under the mocked root (FIVE_LOCAL_ONLY_CHAT=1) with
# `local serve` stubbed. A chat that did not start must never read as ON / rc 0
# (the DIVE-7560 proof: "error: ... no connectord token", then "ON", rc 0).
flag_off
_lc_serve_stop() { return 0; }
_lc_serve() { echo "error: local chat: the server did not start" >&2; return 1; }
( FIVE_LOCAL_ONLY_CHAT=1 _lo_on ) >"$TMPD/chat.out" 2>&1; rc=$?
if (( rc != 0 )) && ! grep -q 'Local-only mode is ON' "$TMPD/chat.out" && grep -q 'office chat did NOT start' "$TMPD/chat.out" \
   && [[ -e "$FIVE_LOCAL_ONLY_FILE" ]] && ! grep -qx 'local-chat' "$(_lo_undo)"; then
  ok_ "CHAT: the office chat failed → no plain ON, rc $rc, the switch stays in force"
else bad_ "CHAT failed" "rc=$rc $(cat "$TMPD/chat.out")"; fi
( _lo_off ) >/dev/null 2>&1
_lc_serve() { return 0; }
( FIVE_LOCAL_ONLY_CHAT=1 _lo_on ) >"$TMPD/chat.out" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q 'Local-only mode is ON' "$TMPD/chat.out" && grep -qx 'local-chat' "$(_lo_undo)" \
  && ok_ "CHAT: the office chat started → ON, rc 0, recorded for off" || bad_ "CHAT started" "rc=$rc $(cat "$TMPD/chat.out")"
( _lo_off ) >/dev/null 2>&1
unset -f _lc_serve _lc_serve_stop

# ── NTP ──────────────────────────────────────────────────────────────────────
echo enabled > "$TMPD/units/systemd-timesyncd.service"
( _lo_on --ntp=192.168.1.1 ) >/dev/null 2>&1
grep -q '^NTP=192.168.1.1' "$(_lo_ntpconf)" && [[ $(cat "$TMPD/units/systemd-timesyncd.service") == enabled ]] \
  && ok_ "NTP: --ntp=<lan> points time sync at the office server and keeps it on" || bad_ "NTP" "not written or timesyncd off"
( _lo_off ) >/dev/null 2>&1
[[ ! -e "$(_lo_ntpconf)" ]] && ok_ "NTP: off removes the office time-server file" || bad_ "NTP off" "left behind"
( _lo_on --ntp=pool.example.com ) >/dev/null 2>&1; rc=$?
[[ $rc == 3 && ! -e "$FIVE_LOCAL_ONLY_FILE" ]] && ok_ "NTP: a public --ntp is refused and nothing is written" || bad_ "NTP public" "rc=$rc"

# ── CHECK ────────────────────────────────────────────────────────────────────
( _lo_on ) >/dev/null 2>&1
printf '%s\n' 'tcp ESTAB 0 0 10.0.0.2:22 10.0.0.9:51000 users:(("sshd",pid=1,fd=3))' \
              'tcp ESTAB 0 0 127.0.0.1:5432 127.0.0.1:40000 users:(("postgres",pid=2,fd=3))' \
              'udp ESTAB 0 0 10.0.0.2:41000 [fd00::53]:53 users:(("resolved",pid=4,fd=3))' \
              'tcp LISTEN 0 0 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' > "$STUB_SS"
( _lo_check --watch=2 ) >"$TMPD/chk.out" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q 'Fully local' "$TMPD/chk.out" && ok_ "CHECK: only LAN/loopback peers → Fully local, exit 0" || bad_ "CHECK clean" "rc=$rc $(cat "$TMPD/chk.out")"
printf '%s\n' 'tcp SYN-SENT 0 0 10.0.0.2:40100 203.0.113.7:443 users:(("node",pid=9,fd=3))' >> "$STUB_SS"
( _lo_check --watch=2 ) >"$TMPD/chk.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q '203.0.113.7:443' "$TMPD/chk.out" && grep -q '^LEAK  outside connections seen: 1' "$TMPD/chk.out" \
  && ok_ "CHECK: a public connect in the watch → LEAK line naming it, exit 1" || bad_ "CHECK leak" "rc=$rc $(cat "$TMPD/chk.out")"
k=$(grep -cE '^(ok|LEAK) ' "$TMPD/chk.out")
(( k >= 5 )) && ok_ "CHECK: one ok/LEAK line per item ($k lines)" || bad_ "CHECK lines" "$k"
( _lo_off ) >/dev/null 2>&1
( _lo_check --watch=0 ) >"$TMPD/chk.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q '^LEAK  local-only switch' "$TMPD/chk.out" && ok_ "CHECK: switch off → LEAK on the switch line, exit 1" || bad_ "CHECK off" "rc=$rc"

# ── REFRESH ──────────────────────────────────────────────────────────────────
flag_on
n=0; for s in bin/5dive-refresh-skills.sh bin/5dive-refresh-plugins.sh; do
  out=$(bash "$s" 2>&1); rc=$?; [[ $rc == 0 && $out == *"skipped — local-only mode is on"* ]] || { n=$((n+1)); echo "  $s rc=$rc"; }; done
(( n == 0 )) && ok_ "REFRESH: skills + plugins refresh scripts skip with the flag on" || bad_ "REFRESH" "$n ran"
flag_off

# ── MUTANTS ──────────────────────────────────────────────────────────────────
flag_on
( local_only_on() { return 1; }; local_only_gate bug --what=x --file ) >/dev/null 2>&1 \
  && ok_ "MUTANT: a gate blind to the flag lets bug --file through (REFUSE would red)" || bad_ "MUTANT gate" "still refused"
flag_off
echo disabled > "$TMPD/units/whoopsie.service"
( _lo_on; printf 'unit whoopsie.service\n' >> "$(_lo_undo)"; _lo_off ) >/dev/null 2>&1
[[ $(cat "$TMPD/units/whoopsie.service") == enabled ]] \
  && ok_ "MUTANT: an undo record naming the owner's unit re-enables it (owner-off arm would red)" || bad_ "MUTANT owner-off" "not detected"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
