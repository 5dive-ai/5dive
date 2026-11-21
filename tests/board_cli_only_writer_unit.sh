#!/usr/bin/env bash
# DIVE-9001 — only the 5dive CLI opens the task board.
#
# The production board dir becomes root:5dive-board 2770, no agent is in that
# group, and a board verb run by a seat re-runs itself through
# `sudo -g 5dive-board /usr/local/bin/5dive` (src/lib/board_hop.sh). This
# harness holds both halves:
#
#   U arms (no root, run everywhere): the pure pieces — which commands hop, when
#     a process decides to hop, the sudoers text, the refusal inside the hop, and
#     the loud failure a seat gets on a locked board it reached without the hop.
#   R arm (AS ROOT, on a disposable box only — CI's root-arms job, where
#     BD_REQUIRE_ROOT_ARM=1 turns a skip into a failure): installs this tree's
#     bundle as /usr/local/bin/5dive, builds a board in the OLD shape with rows,
#     runs the update step (`5dive task init`), then, as a real agent uid:
#     direct sqlite3/python3 are refused, `task add/assign/done` work and stamp
#     the real caller, every pre-existing row is still there, ~/.sqliterc cannot
#     inject SQL, and the unlock marker puts the old shape back.
#
# Run: bash tests/board_cli_only_writer_unit.sh        (U arms; R arm skips)
#      sudo -E env BD_REQUIRE_ROOT_ARM=1 bash tests/board_cli_only_writer_unit.sh
#      (R arm: ONLY on a throwaway machine — it creates a group, a user, a
#      sudoers file and /var/lib/5dive, and refuses to start if a board exists.)
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${FIVEDIVE_TEST:=1}"; export FIVEDIVE_TEST
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rc=$?; chmod -R u+rwx "${TMP:-/nonexistent}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }
has()  { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }

# ---------------------------------------------------------------- U arms
(
  warn() { echo "warn: $*" >&2; }
  # shellcheck source=/dev/null
  source "$REPO/src/lib/board_hop.sh"
  f=0
  t() { if "$@"; then :; else echo "FAILED: $*"; f=1; fi; }
  n() { if "$@"; then echo "WRONGLY TRUE: $*"; f=1; fi; }
  t _board_is_board_cmd task ls
  t _board_is_board_cmd --json task show DIVE-1
  t _board_is_board_cmd trace DIVE-1
  t _board_is_board_cmd agent proactive dev more
  n _board_is_board_cmd gh pr view 5
  n _board_is_board_cmd agent send dev hi
  n _board_is_board_cmd agent
  n _board_is_board_cmd
  n _board_is_board_cmd memory search x
  exit $f
) && ok "U1 board verbs hop; gh, agent send, memory and an empty line do not" \
  || bad "U1 board-verb classification"

(
  warn() { :; }
  # shellcheck source=/dev/null
  source "$REPO/src/lib/board_hop.sh"
  P="$TMP/u2/tasks"; mkdir -p "$P"; : >"$TMP/u2/bin5dive"
  _BOARD_PROD_DIR="$P"; FIVEDIVE_BOARD_BIN="$TMP/u2/bin5dive"
  FIVEDIVE_BOARD_HOP_PATH="$TMP/u2/hop"; ln -s "$FIVEDIVE_BOARD_BIN" "$FIVEDIVE_BOARD_HOP_PATH"
  unset STATE_DIR TASKS_DIR TASKS_DB
  export TASKS_DIR="$P"
  f=0
  chk() { local want="$1"; shift; local got=no; _board_hop_needed "$@" && got=yes
          [[ "$got" == "$want" ]] || { echo "want $want got $got: $*"; f=1; }; }
  _BOARD_EUID=1000
  chk no  "$FIVEDIVE_BOARD_BIN" task ls             # dir still enterable (old shape)
  chmod 0 "$P"
  if [[ -x "$P" ]]; then echo "SKIP-ROOT"; exit 0; fi
  chk yes "$FIVEDIVE_BOARD_BIN" task ls             # locked, prod store, the one binary, a board verb
  chk no  "$FIVEDIVE_BOARD_BIN" gh pr view 1        # not a board verb
  chk no  "$TMP/u2/other" task ls                   # a build elsewhere never hops
  TASKS_DB="$TMP/elsewhere.db" chk no "$FIVEDIVE_BOARD_BIN" task ls   # store moved off prod
  TASKS_DIR="$TMP/x" chk no "$FIVEDIVE_BOARD_BIN" task ls
  _BOARD_EUID=0 chk no "$FIVEDIVE_BOARD_BIN" task ls                 # root never hops
  FIVE_BOARD_HOPPED=1 chk no "$FIVEDIVE_BOARD_BIN" task ls           # never twice
  FIVEDIVE_BOARD_HOP_PATH="$TMP/u2/missing" chk no "$FIVEDIVE_BOARD_BIN" task ls  # no hop link: no hop
  chmod 700 "$P"
  exit $f
) && ok "U2 a seat hops only on a locked prod board, through the one binary, for a board verb, once" \
  || bad "U2 hop decision"

(
  warn() { :; }
  # shellcheck source=/dev/null
  source "$REPO/src/lib/board_hop.sh"
  f=0
  for variant in full portable; do
    s="$(board_sudoers_render "$variant")"
    has '%claude ALL=(:5dive-board) NOPASSWD: FIVEDIVE_BOARD_CLI' "$s" || { echo "$variant: no group rule"; f=1; }
    # The hop's own symlink, never /usr/local/bin/5dive (that name would put these
    # Defaults on every root `sudo 5dive` too), and only with --board-hopped, so
    # sudo refuses `sudo -g 5dive-board <hop> gh ...` before the CLI even starts.
    has 'Cmnd_Alias FIVEDIVE_BOARD_CLI = /usr/local/lib/5dive/5dive-board --board-hopped *'$'\n' "$s" \
      || { echo "$variant: alias is not the hop link bound to --board-hopped"; f=1; }
    has '/usr/local/bin/5dive' "$s" && { echo "$variant: names the CLI binary itself"; f=1; }
    ek="$(grep '^Defaults!FIVEDIVE_BOARD_CLI env_keep' <<<"$s")"
    for v in PATH BASH_ENV LD_ ENV= PYTHON SHELLOPTS _BIN; do
      has "$v" "$ek" && { echo "$variant: env_keep carries $v"; f=1; }
    done
    # Only ever a group runas: never a user runas, never ALL commands.
    grep -E '^[^#].*NOPASSWD' <<<"$s" | grep -vq '(:5dive-board)' && { echo "$variant: a non-group runas"; f=1; }
    printf '%s\n' "$s" >"$TMP/sudoers-$variant"
  done
  has 'pam_session' "$(<"$TMP/sudoers-portable")" && { echo "portable carries a sudo-only setting"; f=1; }
  # Every visudo here: the box's own, plus any named in BD_EXTRA_VISUDO (e.g. an
  # unpacked sudo-rs visudo on a box that runs sudo). The portable variant must
  # pass every one; the full one must pass classic sudo (it is what a sudo box
  # installs). visudo's own words are printed on failure.
  for vb in $(command -v visudo 2>/dev/null) ${BD_EXTRA_VISUDO:-}; do
    rs=0; has 'sudo-rs' "$("$vb" --version 2>&1)" && rs=1
    out="$("$vb" -cf "$TMP/sudoers-portable" 2>&1)" || { echo "$vb rejects the portable rule: $out"; f=1; }
    if (( ! rs )); then
      out="$("$vb" -cf "$TMP/sudoers-full" 2>&1)" || { echo "$vb (sudo) rejects the full rule: $out"; f=1; }
    fi
    echo "visudo checked: $vb ($( ((rs)) && echo sudo-rs || echo sudo ))"
  done
  exit $f
) && ok "U3 both sudoers variants are group-only, name only the hop link bound to --board-hopped, keep no PATH/BASH_ENV/LD_*/*_BIN, and pass visudo" \
  || bad "U3 sudoers render"

out=$(
  warn() { :; }
  # shellcheck source=/dev/null
  source "$REPO/src/lib/board_hop.sh"
  ( _board_hopped_enter gh pr view 1 ) 2>&1; echo "rc=$?"
  ( _board_hopped_enter task ls && declare -f sqlite3 && echo "nus=${PYTHONNOUSERSITE:-}" ) 2>&1; echo "rc=$?"
)
if has 'does not run in the task-board group' "$out" && has 'rc=10' "$out" \
   && has 'command sqlite3 -init /dev/null' "$out" && has 'nus=1' "$out" && has 'rc=0' "$out"; then
  ok "U4 inside the hop: a non-board verb is refused 10; sqlite3 skips ~/.sqliterc; python ignores the seat's site dir"
else
  bad "U4 hopped entry (got: $(tr '\n' '|' <<<"$out"))"
fi

if (( EUID != 0 )); then
  [[ -x ./5dive ]] || ./build.sh >/dev/null
  mkdir -p "$TMP/u5/tasks"; chmod 0 "$TMP/u5/tasks"
  out=$(STATE_DIR="$TMP/u5" TASKS_DIR="$TMP/u5/tasks" TASKS_DB="$TMP/u5/tasks/tasks.db" \
        TASKS_BACKUP_DIR="$TMP/u5/backups" ./5dive task ls 2>&1); rc=$?
  chmod 700 "$TMP/u5/tasks"
  if (( rc == 10 )) && has 'DIVE-9001' "$out" && has "'5dive task'" "$out" && [[ ! -e "$TMP/u5/backups" ]]; then
    ok "U5 a seat on a locked board without the hop fails 10 naming the verb, and no recovery runs"
  else
    bad "U5 locked board without hop (rc=$rc out=$(tr '\n' '|' <<<"$out"))"
  fi
else
  echo "skip - U5 (root enters any dir)"
fi

# ---------------------------------------------------------------- R arm
R_SKIP=""
if (( EUID != 0 )); then R_SKIP="not root"
elif [[ -e /var/lib/5dive/tasks/tasks.db ]]; then R_SKIP="a real board exists on this machine"
elif [[ "${BD_REQUIRE_ROOT_ARM:-0}" != 1 ]]; then R_SKIP="BD_REQUIRE_ROOT_ARM is not 1 (disposable boxes only)"
fi
if [[ -n "$R_SKIP" ]]; then
  if [[ "${BD_REQUIRE_ROOT_ARM:-0}" == 1 ]]; then bad "R skipped under BD_REQUIRE_ROOT_ARM=1: $R_SKIP"
  else echo "skip - R ($R_SKIP)"; fi
else
  U=agent-bdt1
  as() { sudo -u "$U" -H bash -c "cd /tmp && $1"; }
  ./build.sh >/dev/null
  install -m 0755 ./5dive /usr/local/bin/5dive
  getent group claude >/dev/null || groupadd claude
  id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash -G claude "$U"
  install -d -m 2750 -o root -g claude /var/lib/5dive
  mkdir -p /etc/5dive
  # 1. the OLD shape, with rows a seat wrote directly.
  touch /etc/5dive/board-unlocked
  5dive task init >/dev/null 2>&1 || bad "R1 task init (old shape) failed"
  [[ "$(stat -c %G:%a /var/lib/5dive/tasks)" == claude:2770 ]] && ok "R1 unlock marker keeps the old root:claude 2770 shape" \
    || bad "R1 old shape: $(stat -c %G:%a /var/lib/5dive/tasks)"
  for i in 1 2 3; do as "5dive task add 'bd fixture $i' --assignee=bdt1 >/dev/null"; done
  as "sqlite3 /var/lib/5dive/tasks/tasks.db \"update tasks set priority='urgent' where title='bd fixture 3'\"" \
    && ok "R2 baseline: before the lockdown a seat CAN write the board with its own sqlite3" \
    || bad "R2 baseline direct write failed (the refusal below would prove nothing)"
  before=$(sqlite3 /var/lib/5dive/tasks/tasks.db "select count(*)||':'||group_concat(ident||title||priority,',') from tasks")
  # 2. the update step.
  rm -f /etc/5dive/board-unlocked
  5dive task init >/dev/null 2>&1 || bad "R3 task init (lockdown) failed"
  after=$(sqlite3 /var/lib/5dive/tasks/tasks.db "select count(*)||':'||group_concat(ident||title||priority,',') from tasks")
  [[ "$(stat -c %U:%G:%a /var/lib/5dive/tasks)" == root:5dive-board:2770 && "$(stat -c %G /var/lib/5dive/tasks/tasks.db)" == 5dive-board ]] \
    && visudo -cf /etc/sudoers.d/5dive-board >/dev/null 2>&1 \
    && [[ -L /usr/local/lib/5dive/5dive-board && /usr/local/lib/5dive/5dive-board -ef /usr/local/bin/5dive ]] \
    && ok "R3 update step: dir root:5dive-board 2770, db in the group, sudoers rule valid" \
    || bad "R3 lockdown shape: $(stat -c %U:%G:%a /var/lib/5dive/tasks) db=$(stat -c %G /var/lib/5dive/tasks/tasks.db)"
  [[ -n "$before" && "$before" == "$after" ]] && ok "R4 every row survives the upgrade (${before%%:*} rows, same idents/titles/priority)" \
    || bad "R4 rows changed: before=[$before] after=[$after]"
  # 3. the seat cannot open it.
  o=$(as "sqlite3 /var/lib/5dive/tasks/tasks.db \"update tasks set assignee='bdt1'\"" 2>&1); r1=$?
  o2=$(as "python3 -c \"import sqlite3; sqlite3.connect('file:/var/lib/5dive/tasks/tasks.db?mode=rw', uri=True).execute('select 1')\"" 2>&1); r2=$?
  o3=$(as "cat /var/lib/5dive/tasks/tasks.db >/dev/null" 2>&1); r3=$?
  (( r1 != 0 && r2 != 0 && r3 != 0 )) && has 'ermission denied' "$o3" \
    && ok "R5 as the seat: sqlite3, python3 and cat are all refused (cat: $(tr '\n' ' ' <<<"$o3"))" \
    || bad "R5 seat reached the file: sqlite3 rc=$r1 [$o] python rc=$r2 [$o2] cat rc=$r3"
  # 4. the CLI still works, and stamps the real caller.
  id4=$(as "5dive task add 'bd after lockdown' --assignee=bdt1 --json" 2>/dev/null | jq -r '.data.ident // .data.id // empty')
  as "5dive task start $id4 >/dev/null 2>&1"
  as "5dive task assign $id4 bdt1 >/dev/null 2>&1"; ra=$?
  as "5dive task done $id4 --result='bd fixture closed through the CLI' >/dev/null 2>&1"; rd=$?
  row=$(sqlite3 /var/lib/5dive/tasks/tasks.db "select created_by||'|'||status from tasks where ident='$id4'")
  [[ -n "$id4" && $ra -eq 0 && $rd -eq 0 && "$row" == "bdt1|done" ]] \
    && ok "R6 as the seat through the CLI: add/assign/done work; created_by=bdt1 (the uid, not root, not 'cli')" \
    || bad "R6 CLI path: id=$id4 assign rc=$ra done rc=$rd row=[$row]"
  # 5. the hop cannot be turned into anything else.
  o=$(as "sudo -n -g 5dive-board /usr/local/lib/5dive/5dive-board gh pr view 1" 2>&1); r1=$?
  o4=$(as "sudo -n -g 5dive-board /usr/local/lib/5dive/5dive-board --board-hopped gh pr view 1" 2>&1); r4=$?
  o2=$(as "sudo -n -g 5dive-board /usr/bin/sqlite3 /var/lib/5dive/tasks/tasks.db 'select 1'" 2>&1); r2=$?
  o3=$(as "sudo -n -g 5dive-board /usr/local/bin/5dive task ls" 2>&1); r3=$?
  (( r1 != 0 && r1 != 10 )) && ! has 'task-board group' "$o" && (( r4 == 10 )) && has 'task-board group' "$o4" \
    && (( r2 != 0 && r3 != 0 )) \
    && ok "R7 sudo -g gives only '<hop> --board-hopped', and inside it only board verbs (hop without --board-hopped, raw sqlite3 and the bare binary refused by sudo; --board-hopped gh refused 10)" \
    || bad "R7 hop widened: no-flag gh rc=$r1 [$o] flagged gh rc=$r4 [$o4] sqlite3 rc=$r2 [$o2] bare rc=$r3 [$o3]"
  as "printf '%s\n' \"UPDATE tasks SET title='PWNED';\" > ~/.sqliterc"
  as "5dive task ls >/dev/null 2>&1"
  pw=$(sqlite3 /var/lib/5dive/tasks/tasks.db "select count(*) from tasks where title='PWNED'")
  [[ "$pw" == 0 ]] && ok "R8 a seat's ~/.sqliterc does not run inside the hop" \
    || bad "R8 ~/.sqliterc ran inside the hop: $pw rows retitled"
  as "rm -f ~/.sqliterc"
  # 6. cost of the hop, reported (not asserted: runners vary).
  t0=$(date +%s%N); as "5dive task ls >/dev/null 2>&1"; t1=$(date +%s%N)
  echo "info - R hopped 'task ls' took $(( (t1 - t0) / 1000000 ))ms end to end"
  # 7. the way back.
  touch /etc/5dive/board-unlocked
  5dive task init >/dev/null 2>&1
  as "sqlite3 /var/lib/5dive/tasks/tasks.db 'select count(*) from tasks' >/dev/null" \
    && [[ "$(stat -c %G /var/lib/5dive/tasks)" == claude ]] \
    && ok "R9 the unlock marker puts the old shape back and seats reach the board again" \
    || bad "R9 unlock: $(stat -c %G:%a /var/lib/5dive/tasks)"
  rm -f /etc/5dive/board-unlocked
fi

echo
(( fails == 0 )) || { echo "FAILED: $fails"; exit 1; }
echo "all passed"
