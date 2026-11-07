#!/usr/bin/env bash
# DIVE-7873 unit harness: `5dive backup enable|run|restore|code`.
#
# The load-bearing property is KEY CUSTODY: the recovery code is made on the box,
# reaches restic only through a 0600 password file, reaches the owner only through
# a Telegram DM from the box's own bot, and NEVER reaches the 5dive API (enrol and
# report bodies, curl argv) or restic's argv. Then: a box with an earlier backup
# in its place never starts a new key over it; a failed run is reported, not
# silent; the box token rides curl's stdin; a malformed enrol answer writes
# nothing; a restore refuses a wrong code and never brings back the old box's
# identity files.
#
# restic, curl, Telegram, systemctl and the user tools are stubs; every path is
# redirected into a temp dir. No root, no network. The restic stub is REPO-AWARE:
# each repository under the owner's prefix is a dir holding its keys, so init,
# the probe (10 absent / 0 opens / 12 wrong key), key add|list|remove and backup
# behave per repository the way restic 0.17.3 does, and the S3 listing the CLI
# reads is drawn from the same dirs. That is what lets the fresh-box sequence
# (old repo box-7, new box 42) run end to end here.
#
# Run: bash tests/backup_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/backup-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_backup.sh"
set +e

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL — %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }

# The agent unit's drop-in dir, built so no literal name-at-host string sits here.
export UNIT_D="5dive-agent$(printf '\x40')ava.service.d" UNIT_S="5dive-agent$(printf '\x40')ava.service"

reset() {
  rm -rf "$TMP/w" "$TMP/repos"; mkdir -p "$TMP/repos"; mkdir -p "$TMP/w/bin" "$TMP/w/etc" "$TMP/w/state" "$TMP/w/root"
  export FIVE_BACKUP_DIR="$TMP/w/etc/backup" FIVE_BACKUP_STATE="$TMP/w/state/backup"
  export FIVE_BACKUP_CRON="$TMP/w/etc/cron.d/5dive-backup" FIVE_BACKUP_LOG="$TMP/w/backup.log"
  export FIVE_BACKUP_RESTIC="$TMP/w/bin/restic" FIVE_BACKUP_USERS="$TMP/w/state/backup-users.tsv"
  export FIVE_BACKUP_ROOT="$TMP/w/root" FIVE_BACKUP_STAGE="$TMP/w/stage"
  export FIVE_CONNECTORD_ENV="$TMP/w/etc/connectord.env" FIVE_API_BASE_FILE="$TMP/none" FIVE_API_BASE="https://api.test"
  printf 'CONNECTORD_TOKEN=boxtok_SECRET123\n' >"$FIVE_CONNECTORD_ENV"
  REGISTRY="$TMP/w/state/agents.json"; printf '{"agents":{"ava":{}}}' >"$REGISTRY"
  : >"$TMP/curl.argv"; : >"$TMP/curl.stdin"; : >"$TMP/curl.body"; : >"$TMP/restic.argv"; : >"$TMP/tg"; : >"$TMP/restic.pw"; : >"$TMP/restic.sess"; : >"$TMP/sys"
  export RESTIC_PROBE_RC="" RESTIC_BACKUP_RC=0 RESTIC_SILENT="" LIST_FAIL="" T="$TMP"
  # restic stub: logs the repository + argv and the password it was given, then
  # acts on $T/repos/<repo>/keys (one password per line).
  cat >"$FIVE_BACKUP_RESTIC" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${RESTIC_REPOSITORY:-}" "$*" >>"$T/restic.argv"; printf '%s\n' "${AWS_SESSION_TOKEN:-}" >>"$T/restic.sess"
[[ -n "${RESTIC_PASSWORD_FILE:-}" ]] && printf 'pw=%s mode=%s\n' "$(cat "$RESTIC_PASSWORD_FILE")" "$(stat -c %a "$RESTIC_PASSWORD_FILE")" >>"$T/restic.pw"
R="$T/repos/${RESTIC_REPOSITORY##*/}"; pw=$(cat "$RESTIC_PASSWORD_FILE" 2>/dev/null)
opens() { [[ -f "$R/keys" ]] && grep -qxF -- "$pw" "$R/keys"; }
kid() { printf '%s' "$1" | sha256sum | cut -c1-64; }
argafter() { local p="" a; for a in "${@:2}"; do [[ "$p" == "$1" ]] && { printf '%s' "$a"; return; }; p="$a"; done; }
case " $* " in
  *" cat config"*) [[ -n "${RESTIC_PROBE_RC:-}" ]] && exit "$RESTIC_PROBE_RC"
     [[ -d "$R" ]] || exit 10; opens && exit 0; exit 12 ;;
  *" init"*) [[ -d "$R" ]] && { echo "Fatal: config file already exists" >&2; exit 1; }
     mkdir -p "$R"; printf '%s\n' "$pw" >"$R/keys"; exit 0 ;;
  *" key add "*) opens || exit 12; printf '%s\n' "$(cat "$(argafter --new-password-file "$@")")" >>"$R/keys"; exit 0 ;;
  *" key list "*) opens || exit 12
     while IFS= read -r k; do jq -cn --arg id "$(kid "$k")" --argjson c "$([[ "$k" == "$pw" ]] && echo true || echo false)" '{current:$c, id:$id}'; done <"$R/keys" | jq -cs . ; exit 0 ;;
  *" key remove "*) opens || exit 12; id="${@: -1}"; [[ "$id" == "$(kid "$pw")" ]] && exit 1
     while IFS= read -r k; do [[ "$(kid "$k")" == "$id" ]] || printf '%s\n' "$k"; done <"$R/keys" >"$R/keys.n"; mv "$R/keys.n" "$R/keys"; exit 0 ;;
  *" backup "*) opens || { echo "Fatal: wrong password or no key found" >&2; exit 12; }
     [[ "$RESTIC_BACKUP_RC" == 0 ]] && { echo x >>"$R/snapshots"; echo '{"message_type":"summary","snapshot_id":"abc123","data_added":4096}'; exit 0; }
     [[ -n "${RESTIC_SILENT:-}" ]] || echo "Fatal: unable to open repo" >&2; exit "$RESTIC_BACKUP_RC" ;;
  *" forget "*) exit 0 ;;
  *" restore "*) opens || exit 12; t=$(argafter --target "$@")
     mkdir -p "$t/home/agent-ava" "$t/var/lib/5dive" "$t/etc/5dive/connectors" "$t/etc/systemd/system/$UNIT_D"
     echo "remembers: the blue door" >"$t/home/agent-ava/MEMORY.md"
     printf '{"agents":{"ava":{}}}' >"$t/var/lib/5dive/agents.json"
     printf 'agent-ava\t1007\t1007\tagent-ava\t/home/agent-ava\t/bin/bash\tagent-ava,claude\n' >"$t/var/lib/5dive/backup-users.tsv"
     # A different LENGTH from the new box's token, so rsync's size+mtime check
     # can never skip it by coincidence: the IDENTITY arm is deterministic.
     echo "CONNECTORD_TOKEN=OLD_BOX_IDENTITY_FROM_THE_BACKUP" >"$t/etc/5dive/connectord.env"
     echo "TELEGRAM_BOT_TOKEN=bot" >"$t/etc/5dive/connectors/telegram-ava.env"
     echo "[Service]" >"$t/etc/systemd/system/$UNIT_D/x.conf" ;;
esac
exit 0
EOF
  chmod +x "$FIVE_BACKUP_RESTIC"
  ENROLL_BODY='{"endpoint":"https://acct.eu.r2.cloudflarestorage.com","bucket":"5dive-box-backups","prefix":"o-0123456789abcdef01234567/","accessKeyId":"AKID1","secretAccessKey":"deadbeef","sessionToken":"sess.TOKEN_1","region":"auto","serverId":42}'
  ENROLL_HTTP=200
}
# curl stub: argv, stdin (the auth header) and the body. Writes the answer to -o.
curl() {
  printf '%s\n' "$*" >>"$TMP/curl.argv"
  local o="" d="" prev="" a url=""
  for a in "$@"; do
    [[ "$prev" == -o ]] && o="$a"; [[ "$prev" == --data ]] && d="$a"; prev="$a"; url="$a"
  done
  cat >>"$TMP/curl.stdin"; printf '%s\n' "$d" >>"$TMP/curl.body"
  case "$url" in
    *list-type=2*) [[ -n "$LIST_FAIL" ]] && return 22
       local r; printf '<ListBucketResult><Prefix>o-0123456789abcdef01234567/</Prefix>'
       for r in "$TMP"/repos/box-*; do [[ -d "$r" ]] && printf '<CommonPrefixes><Prefix>o-0123456789abcdef01234567/%s/</Prefix></CommonPrefixes>' "${r##*/}"; done
       printf '</ListBucketResult>' ;;
    */enroll) printf '%s' "$ENROLL_BODY" >"$o"; printf '%s' "$ENROLL_HTTP" ;;
    */report) printf '{"ok":true}' >"$o"; printf 200 ;;
  esac
}
require_root() { :; }
_bk_restic_install() { :; }
_task_agent_channel() { [[ "$1" == ava ]] || return 1; TASK_CH_TOKEN=bot; TASK_CH_ACCESS="$TMP/w/access.json"; printf '{"allowFrom":["1234567890"]}' >"$TASK_CH_ACCESS"; }
_bk_send() { printf 'chat=%s text=%s\n' "$2" "$4" >>"$TMP/tg"; echo '{"ok":true}'; }
systemctl() { printf 'systemctl %s\n' "$*" >>"$TMP/sys"; }
getent() { case "$1" in passwd|group) [[ "${2:-}" == claude ]] && return 0; return 2 ;; esac; }
useradd() { printf 'useradd %s\n' "$*" >>"$TMP/sys"; }
groupadd() { printf 'groupadd %s\n' "$*" >>"$TMP/sys"; }
usermod() { printf 'usermod %s\n' "$*" >>"$TMP/sys"; }
run() { ( cmd_backup "$@" ) >"$TMP/out" 2>&1; echo $? >"$TMP/rc"; }
rc() { cat "$TMP/rc"; }
code_on_box() { cat "$FIVE_BACKUP_DIR/key" 2>/dev/null; }
seed() { mkdir -p "$TMP/repos/$1"; printf '%s\n' "$2" >"$TMP/repos/$1/keys"; }   # <repo> <key that opens it>
opens_repo() { grep -qxF -- "$2" "$TMP/repos/$1/keys" 2>/dev/null; }

# --- the recovery code ---------------------------------------------------------
c=$(_bk_code_new)
check "a new code is 28 symbols of the no-0/O/1/I alphabet" '[[ ${#c} -eq 28 && "$c" =~ ^[A-HJ-NP-Z2-9]+$ ]]'
check "two codes differ" '[[ "$c" != "$(_bk_code_new)" ]]'
p=$(_bk_code_pretty "$c")
check "the pretty code normalises back, lowercase and dashed" '[[ "$(_bk_code_normalize "${p,,}")" == "$c" ]]'
check "a short code refuses" '! _bk_code_normalize "ABCD-EFGH" >/dev/null'
check "a code with O/0/1/I refuses" '! _bk_code_normalize "O0I1ABCDEFGHJKLMNPQRSTUVWXYZ" >/dev/null'

# --- enable on a fresh box ------------------------------------------------------
reset; run enable
K=$(code_on_box)
check "enable: rc 0" '[[ $(rc) == 0 ]]'
check "enable: the key file is 0600 and holds a valid code" '[[ $(stat -c %a "$FIVE_BACKUP_DIR/key") == 600 && -n "$(_bk_code_normalize "$K")" ]]'
check "enable: r2.env is 0600 and names repo box-42" '[[ $(stat -c %a "$FIVE_BACKUP_DIR/r2.env") == 600 ]] && grep -q "^BACKUP_REPO=box-42$" "$FIVE_BACKUP_DIR/r2.env"'
check "enable: the repository is box-42 under this owner's prefix" 'grep -q "^s3:https://acct.eu.r2.cloudflarestorage.com/5dive-box-backups/o-0123456789abcdef01234567/box-42 .* init" "$TMP/restic.argv"'
check "enable: restic got the temporary credential's session token" 'grep -qx "sess.TOKEN_1" "$TMP/restic.sess"'
check "enable: restic got the key via a 0600 password file" 'grep -q "^pw=$K mode=600$" "$TMP/restic.pw"'
check "enable: cron scheduled nightly as root" 'grep -qE "^[0-9]+ [2-4] \* \* \* root /usr/local/bin/5dive backup run" "$FIVE_BACKUP_CRON"'
check "enable: the owner got the code in a DM, with the no-recovery warning" 'grep -q "chat=1234567890" "$TMP/tg" && grep -q "$(_bk_code_pretty "$K")" "$TMP/tg" && grep -q "nobody can restore" "$TMP/tg"'
check "CUSTODY: the code is in no API body, header or argv" '! grep -q "$K" "$TMP/curl.argv" "$TMP/curl.body" "$TMP/curl.stdin" && ! grep -q "$(_bk_code_pretty "$K")" "$TMP/curl.argv" "$TMP/curl.body"'
check "CUSTODY: the code is never on restic's argv" '! grep -q "$K" "$TMP/restic.argv"'
check "the box token rides curl's stdin, never argv" 'grep -q "boxtok_SECRET123" "$TMP/curl.stdin" && ! grep -q "boxtok_SECRET123" "$TMP/curl.argv"'
check "the code is delivered once: a second enable sends nothing new" '( cmd_backup enable ) >/dev/null 2>&1; [[ $(grep -c "chat=" "$TMP/tg") == 1 ]]'

# --- enable on a box whose place already holds a backup -------------------------
reset; seed box-42 OTHERKEYOTHERKEYOTHERKEY2345; run enable
check "earlier backup: no key is made over it" '[[ ! -e "$FIVE_BACKUP_DIR/key" ]] && ! grep -q " init" "$TMP/restic.argv"'
check "earlier backup: state restore-available, no cron, no DM" '[[ "$(cat "$FIVE_BACKUP_STATE/state")" == restore-available && ! -e "$FIVE_BACKUP_CRON" && ! -s "$TMP/tg" ]]'
check "earlier backup: the nightly run reports it, and still makes no key" '( cmd_backup run ) >/dev/null 2>&1; grep -q "waiting for the owner" "$TMP/curl.body" && [[ ! -e "$FIVE_BACKUP_DIR/key" ]]'

# --- FIX (1): a fresh box of an owner whose backup is an EARLIER box's ----------
# The fresh box gets a new server id (42), so its own place is empty; the owner's
# real backup is box-7. No new key, no init, no second code in the owner's DMs.
reset; seed box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345; run enable
check "FRESH BOX (1): another box's backup under the owner's prefix: no key, no init" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_DIR/key" && ! -d "$TMP/repos/box-42" ]] && ! grep -q " init" "$TMP/restic.argv"'
check "FRESH BOX (1): state restore-available, no cron, no DM, and it names box-7" '[[ "$(cat "$FIVE_BACKUP_STATE/state")" == restore-available && ! -e "$FIVE_BACKUP_CRON" && ! -s "$TMP/tg" ]] && grep -q -- "--from=box-7" "$TMP/out"'
reset; LIST_FAIL=1; run enable
check "FRESH BOX (1): a listing that fails makes no key (unknown is not empty)" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/key" && ! -s "$TMP/tg" ]] && ! grep -q " init" "$TMP/restic.argv"'
reset; seed box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345; run enable --new-key
check "--new-key: the owner may start over beside a lost backup (box-7 untouched)" '[[ $(rc) == 0 && -s "$FIVE_BACKUP_DIR/key" ]] && opens_repo box-42 "$(code_on_box)" && opens_repo box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345'
reset; seed box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345; run enable --auto --new-key
check "--new-key is never unattended: --auto with it refuses and makes no key" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/key" ]]'

# --- the nightly run enables a never-set-up box ----------------------------------
reset; run run
check "rollout: the first nightly run sets the box up and backs up" '[[ $(rc) == 0 && -s "$FIVE_BACKUP_DIR/key" ]] && grep -q " backup " "$TMP/restic.argv" && grep -q "chat=1234567890" "$TMP/tg"'
reset; rm -f "$FIVE_CONNECTORD_ENV"; run run
check "rollout: a box with no 5dive identity is left alone" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_DIR/key" && ! -s "$TMP/curl.argv" ]]'

# --- enrol refusals -------------------------------------------------------------
reset; ENROLL_BODY='{"endpoint":"https://acct.r2.cloudflarestorage.com","bucket":"../other-box","accessKeyId":"A","secretAccessKey":"b","serverId":42}'; run enable
check "a malformed enrol answer writes no storage settings and no key" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/r2.env" && ! -e "$FIVE_BACKUP_DIR/key" ]]'
for bad in '"prefix":"../o-x/"' '"prefix":""' '"sessionToken":"a$(id)"' '"sessionToken":"a b"'; do
  reset; ENROLL_BODY=$(jq -c ". + {${bad}}" <<<"$ENROLL_BODY"); run enable
  check "a malformed enrol answer ($bad) writes nothing" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/r2.env" && ! -e "$FIVE_BACKUP_DIR/key" ]]'
done
reset; ENROLL_HTTP=503; ENROLL_BODY='{"code":"backup_not_configured"}'; run enable --auto
check "--auto: an unready API never fails the caller, and says why" '[[ $(rc) == 0 ]] && grep -q "backup_not_configured" "$FIVE_BACKUP_LOG"'

# --- run -------------------------------------------------------------------------
reset; ( cmd_backup enable ) >/dev/null 2>&1; K=$(code_on_box); : >"$TMP/curl.body"; : >"$TMP/curl.argv"; run run
check "run: re-enrols first (the credential lives 36 h)" '[[ $(grep -c "/enroll" "$TMP/curl.argv") -ge 1 ]]'
check "run: ok, snapshot recorded in status.json" '[[ $(rc) == 0 ]] && jq -e ".ok == true and .snapshot == \"abc123\"" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
check "run: reported ok to the API with the snapshot" 'grep -q "\"ok\":true" "$TMP/curl.body" && grep -q abc123 "$TMP/curl.body"'
check "run: caches and the key dir are excluded" 'grep -q -- "--exclude node_modules" "$TMP/restic.argv" && grep -q -- "--exclude /etc/5dive/backup" "$TMP/restic.argv"'
check "run: old snapshots are pruned" 'grep -q "forget --keep-daily 7" "$TMP/restic.argv"'
export RESTIC_BACKUP_RC=1; : >"$TMP/curl.body"; run run
check "FAILED run: non-zero exit" '[[ $(rc) != 0 ]]'
check "FAILED run: status.json says so and keeps the last good time" 'jq -e ".ok == false and (.error|test(\"rc 1\")) and .lastOkAt != null" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
check "FAILED run: reported to the API as not ok" 'grep -q "\"ok\":false" "$TMP/curl.body"'
check "FAILED run: status says FAILED" '( cmd_backup status ) 2>&1 | grep -q "FAILED"'
check "FAILED run (4): the error is restic's own stderr of this run" 'jq -e ".error|test(\"Fatal: unable to open repo\")" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
export RESTIC_BACKUP_RC=0; ( cmd_backup run ) >/dev/null 2>&1; export RESTIC_BACKUP_RC=1 RESTIC_SILENT=1; run run
check "FAILED run (4): a silent restic never borrows an older log line" 'jq -e "(.error|test(\"run ok=\")|not) and (.error|test(\"printed no error\"))" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
export RESTIC_SILENT="" RESTIC_BACKUP_RC=0
check "CUSTODY: no report body carries the code" '! grep -q "$K" "$TMP/curl.body"'

# --- restore ----------------------------------------------------------------------
GOOD=ABCDEFGHJKLMNPQRSTUVWXYZ2345
reset; seed box-42 "$GOOD"
mkdir -p "$FIVE_BACKUP_ROOT/etc/5dive"; echo "CONNECTORD_TOKEN=NEW_BOX" >"$FIVE_BACKUP_ROOT/etc/5dive/connectord.env"
run restore --code=ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ --yes
check "restore: a wrong code refuses before touching anything" '[[ $(rc) == 6 && ! -e "$FIVE_BACKUP_ROOT/home" ]]'
run restore --code=abcd-efgh-jklm-npqr-stuv-wxyz-2345 --from=../x --yes
check "restore: --from takes only box-N" '[[ $(rc) == 3 ]]'
run restore --code=abcd-efgh-jklm-npqr-stuv-wxyz-2345
check "restore without --yes only checks the key" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_ROOT/home" ]] && grep -q "opens box-42" "$TMP/out"'

# The fresh-box sequence, end to end: old repo box-7 under the owner's prefix,
# a fresh box 42 that has never been set up.
reset; seed box-7 "$GOOD"
mkdir -p "$FIVE_BACKUP_ROOT/etc/5dive"; echo "CONNECTORD_TOKEN=NEW_BOX" >"$FIVE_BACKUP_ROOT/etc/5dive/connectord.env"
run run   # step 1: the first nightly run on the fresh box
check "SEQUENCE step 1: the nightly run on the fresh box makes no key, no repo, no DM" '[[ ! -e "$FIVE_BACKUP_DIR/key" && ! -d "$TMP/repos/box-42" && ! -s "$TMP/tg" ]] && grep -q "waiting for the owner" "$TMP/curl.body"'
: >"$TMP/restic.argv"; run restore --code=abcd-efgh-jklm-npqr-stuv-wxyz-2345 --from=box-7 --yes   # step 2
check "restore: rc 0" '[[ $(rc) == 0 ]] || { cat "$TMP/out"; false; }'
check "restore: read from the named box's repository, under the owner's prefix" 'grep -q "^s3:https://acct.eu.r2.cloudflarestorage.com/5dive-box-backups/o-0123456789abcdef01234567/box-7 .*restore latest" "$TMP/restic.argv"'
check "restore: the agent's memory is back" 'grep -q "blue door" "$FIVE_BACKUP_ROOT/home/agent-ava/MEMORY.md"'
check "restore: its bot connector and unit drop-in are back" '[[ -f "$FIVE_BACKUP_ROOT/etc/5dive/connectors/telegram-ava.env" && -f "$FIVE_BACKUP_ROOT/etc/systemd/system/$UNIT_D/x.conf" ]]'
check "IDENTITY: the old box's token never overwrites the new box's" 'grep -qx "CONNECTORD_TOKEN=NEW_BOX" "$FIVE_BACKUP_ROOT/etc/5dive/connectord.env"'
check "restore: the agent user is recreated with its uid, and its groups" 'grep -q "useradd -M -u 1007 .* agent-ava" "$TMP/sys" && grep -q "usermod -aG claude agent-ava" "$TMP/sys"'
check "restore: the agent is restarted" 'grep -q "restart $UNIT_S" "$TMP/sys"'
check "SEQUENCE step 2: this box's own repository box-42 is created with the owner's code" 'opens_repo box-42 "$GOOD" && [[ "$(code_on_box)" == "$GOOD" && -f "$FIVE_BACKUP_CRON" ]] && grep -q "continue as box-42" "$TMP/out"'
check "CUSTODY: the restore code reached no API call" '! grep -q "$GOOD" "$TMP/curl.argv" "$TMP/curl.body" "$TMP/curl.stdin"'
: >"$TMP/tg"; run run   # step 3
check "SEQUENCE step 3: the next nightly backup succeeds into box-42" '[[ $(rc) == 0 && -s "$TMP/repos/box-42/snapshots" ]] && jq -e ".ok == true" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
check "SEQUENCE: no second recovery code was ever DMed" '! [[ -s "$TMP/tg" ]]'

# FIX (2): this box's own repository already exists under ANOTHER key (one this
# box made before the restore). Re-key it with the box's old key: the owner's
# code opens it, the old key no longer does.
reset; seed box-7 "$GOOD"; seed box-42 OLDBOXKEYOLDBOXKEYOLDBOXKEY2
mkdir -p "$FIVE_BACKUP_DIR"; printf OLDBOXKEYOLDBOXKEYOLDBOXKEY2 >"$FIVE_BACKUP_DIR/key"
run restore --code="$GOOD" --from=box-7 --yes
check "RE-KEY (2): box-42 now opens with the owner's code and not the old box key" '[[ $(rc) == 0 ]] && opens_repo box-42 "$GOOD" && ! opens_repo box-42 OLDBOXKEYOLDBOXKEYOLDBOXKEY2 && grep -q "continue as box-42" "$TMP/out"'
run run
check "RE-KEY (2): the next nightly backup succeeds" '[[ $(rc) == 0 && -s "$TMP/repos/box-42/snapshots" ]]'

# FIX (2), the residue: nothing on this box opens its own repository. The agents
# come back, and the box says backups are NOT running, everywhere it can.
reset; seed box-7 "$GOOD"; seed box-42 STRANGERKEYSTRANGERKEYSTRAN
run restore --code="$GOOD" --from=box-7 --yes
check "MISMATCH (2): the restore still brings the agents back" '[[ $(rc) == 0 ]] && grep -q "blue door" "$FIVE_BACKUP_ROOT/home/agent-ava/MEMORY.md"'
check "MISMATCH (2): it never claims backups continue" '! grep -q "continue as" "$TMP/out" && grep -q "NOT running" "$TMP/out"'
check "MISMATCH (2): status and the API both say backups failed" 'jq -e ".ok == false and (.error|test(\"different key\"))" "$FIVE_BACKUP_STATE/status.json" >/dev/null && grep -q "\"ok\":false" "$TMP/curl.body"'
check "MISMATCH (2): the stranger's repository is left as it was" 'opens_repo box-42 STRANGERKEYSTRANGERKEYSTRAN && ! opens_repo box-42 "$GOOD"'

echo "---"; echo "passed=$PASSED failed=$FAILED"
(( FAILED == 0 ))
