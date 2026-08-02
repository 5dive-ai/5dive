#!/usr/bin/env bash
# DIVE-2083 — the loop_id handle must be collision-PROOF, not collision-unlikely.
#
# `loop_runs.loop_id` is a PRIMARY KEY, so a repeated handle is not a cosmetic
# clash: the second INSERT dies and a live `loop spawn` surfaces a raw
#   Error: stepping, UNIQUE constraint failed: loop_runs.loop_id (19)
# instead of a handled condition. It reddened main once already (73752da).
#
# WHAT THIS GRADES, AND ON WHICH AXIS. Checking bash-side string uniqueness
# would grade the wrong thing — the constraint that fires is sqlite's, so every
# case here INSERTs its draws under the real schema and reads the row count back.
# `_loop_new_id` reads three inputs (the clock, the drawing process's pid, and a
# random source); a case that leaves all three free proves only that the clock
# moved. So the deterministic cases PIN THE CLOCK with a stub and grade what is
# left. That is the axis the pre-2083 form failed on: one-second epoch plus 4 hex
# of $RANDOM is 15 bits inside a 1-second bucket.
#
# Cases 4 and 5 are the mutation pair. They redefine the generator back to the
# pre-2083 form and REQUIRE a collision — without them, cases 2 and 3 would go
# green just as happily against a generator that had stopped drawing at all.
#
# Run: bash tests/loop_id_collision_unit.sh  (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/loop-id-collision.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# The pre-2083 generator, verbatim from src/cmd_loop.sh@73752da. This is the
# mutation: the real prior expression, not a re-derivation of it.
_loop_new_id_pre2083() { printf 'L-%s' "$(date +%s)$(printf '%04x' $((RANDOM)))"; }

# A `date` that never advances. Pinning the clock is what makes cases 2-5
# deterministic rather than a coin flip on how fast the box happens to be: with
# the clock free, whether the old form collides depends on how many draws land
# in one second, which is exactly the flakiness this ticket exists to remove.
mkdir -p "$TMP/frozenbin"
cat > "$TMP/frozenbin/date" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  +%s%N) printf '1785069865000000000\n' ;;
  *)     printf '1785069865\n' ;;
esac
STUB
chmod +x "$TMP/frozenbin/date"
REAL_PATH="$PATH"
freeze_clock()   { PATH="$TMP/frozenbin:$REAL_PATH"; }
unfreeze_clock() { PATH="$REAL_PATH"; }

# mint_seq <gen-fn> <n> <outfile> — sequential draws in ONE process. This is the
# real shape of the panel path: cmd_loop_panel mints its n graders in a
# sequential `for` loop (src/cmd_loop.sh), all in the same process.
mint_seq() {
  local gen="$1" n="$2" out="$3" i
  : > "$out"
  for (( i=0; i<n; i++ )); do "$gen" >> "$out"; printf '\n' >> "$out"; done
}

# mint_forked <gen-fn> <n> <outfile> — draws from FORKED background subshells,
# the shape `( cmd_loop_panel … ) &` produces. Batched so the box is not asked
# to hold n processes at once.
mint_forked() {
  local gen="$1" n="$2" out="$3" i batch=50
  : > "$out"
  for (( i=0; i<n; i++ )); do
    ( printf '%s\n' "$("$gen")" >> "$out" ) &
    (( (i + 1) % batch == 0 )) && wait
  done
  wait
}

# insert_ids <idfile> <errfile> — INSERT every drawn id under the real PRIMARY
# KEY and echo how many rows survived. No -bail, so sqlite reports each
# constraint failure and carries on; the shortfall IS the collision count.
insert_ids() {
  db "DELETE FROM loop_runs;" >/dev/null
  {
    echo "BEGIN;"
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      printf "INSERT INTO loop_runs (loop_id, topology, status, started_at, updated_at) VALUES ('%s','collide-probe','running',0,0);\n" "$id"
    done < "$1"
    echo "COMMIT;"
  } | sqlite3 -cmd ".timeout 5000" "$TASKS_DB" 2>"$2" >/dev/null
  db "SELECT COUNT(*) FROM loop_runs;"
}

N_SEQ=1000
N_FORK=1000
UNIQ_ERR='UNIQUE constraint failed: loop_runs.loop_id'

# --- C1: production shape — real clock, forked draws, current generator.
mint_forked _loop_new_id 300 "$TMP/c1.ids"
rows=$(insert_ids "$TMP/c1.ids" "$TMP/c1.err"); drawn=$(grep -c . "$TMP/c1.ids")
[[ "$rows" == "$drawn" && "$drawn" == "300" ]] && ! grep -q "$UNIQ_ERR" "$TMP/c1.err" \
  && ok_t "C1 production shape (real clock, 300 forked draws) → 300/300 rows, no UNIQUE error" \
  || bad_t "C1 production shape" "drawn=$drawn rows=$rows err=$(head -2 "$TMP/c1.err")"

# --- C2: clock PINNED, sequential draws. Grades the random source alone — one
# process, so the pid axis is constant too and /dev/urandom is all that is left.
freeze_clock
mint_seq _loop_new_id "$N_SEQ" "$TMP/c2.ids"
unfreeze_clock
rows=$(insert_ids "$TMP/c2.ids" "$TMP/c2.err"); drawn=$(grep -c . "$TMP/c2.ids")
[[ "$rows" == "$drawn" && "$drawn" == "$N_SEQ" ]] && ! grep -q "$UNIQ_ERR" "$TMP/c2.err" \
  && ok_t "C2 clock pinned, $N_SEQ sequential draws → $N_SEQ/$N_SEQ rows (entropy survives a frozen clock)" \
  || bad_t "C2 clock pinned, sequential" "drawn=$drawn rows=$rows err=$(head -2 "$TMP/c2.err")"

# --- C3: clock PINNED, forked draws. Grades pid + random together, the shape a
# fleet of concurrent `loop spawn`s actually produces inside one second.
freeze_clock
mint_forked _loop_new_id "$N_FORK" "$TMP/c3.ids"
unfreeze_clock
rows=$(insert_ids "$TMP/c3.ids" "$TMP/c3.err"); drawn=$(grep -c . "$TMP/c3.ids")
[[ "$rows" == "$drawn" && "$drawn" == "$N_FORK" ]] && ! grep -q "$UNIQ_ERR" "$TMP/c3.err" \
  && ok_t "C3 clock pinned, $N_FORK forked draws → $N_FORK/$N_FORK rows" \
  || bad_t "C3 clock pinned, forked" "drawn=$drawn rows=$rows err=$(head -2 "$TMP/c3.err")"

# --- C4/C5: MUTATION — the pre-2083 generator MUST fail both. A green here means
# C2/C3 have stopped discriminating and their pass says nothing about the fix.
freeze_clock
mint_seq _loop_new_id_pre2083 "$N_SEQ" "$TMP/c4.ids"
unfreeze_clock
rows=$(insert_ids "$TMP/c4.ids" "$TMP/c4.err"); drawn=$(grep -c . "$TMP/c4.ids")
[[ "$drawn" == "$N_SEQ" && "$rows" -lt "$N_SEQ" ]] && grep -q "$UNIQ_ERR" "$TMP/c4.err" \
  && ok_t "C4 mutation: pre-2083 generator collides sequentially ($rows/$N_SEQ rows, sqlite names loop_runs.loop_id)" \
  || bad_t "C4 mutation went quiet" "pre-2083 form did NOT collide (drawn=$drawn rows=$rows) — C2 is no longer discriminating"

freeze_clock
mint_forked _loop_new_id_pre2083 "$N_FORK" "$TMP/c5.ids"
unfreeze_clock
rows=$(insert_ids "$TMP/c5.ids" "$TMP/c5.err"); drawn=$(grep -c . "$TMP/c5.ids")
[[ "$drawn" == "$N_FORK" && "$rows" -lt "$N_FORK" ]] && grep -q "$UNIQ_ERR" "$TMP/c5.err" \
  && ok_t "C5 mutation: pre-2083 generator collides when forked too ($rows/$N_FORK rows)" \
  || bad_t "C5 mutation went quiet" "pre-2083 form did NOT collide when forked (drawn=$drawn rows=$rows) — C3 is no longer discriminating"

# --- C6: the frozen clock is doing what the cases above assume. Without this the
# whole matrix could be running on a live clock and nobody would know: C2-C5
# would still read plausibly, and C4/C5 would silently become a race again.
freeze_clock
a=$(date +%s); sleep 1; b=$(date +%s); n=$(date +%s%N)
unfreeze_clock
[[ "$a" == "$b" && "$n" == "1785069865000000000" ]] \
  && ok_t "C6 the clock stub really is frozen (same epoch across a 1s gap, %N honoured)" \
  || bad_t "C6 clock stub" "a=$a b=$b ns=$n — cases C2-C5 were NOT grading a pinned clock"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
