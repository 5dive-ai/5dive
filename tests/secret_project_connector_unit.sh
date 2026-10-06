#!/usr/bin/env bash
# DIVE-5664: `secret write --connector=project-<app>` puts one variable into an
# app's own env file, so an agent never receives a key under a made-up tools name
# and copies it into the app by hand (exact-swallow, 2026-10-06: GOOGLE_MAPS_API
# was refused by --connector=tools and hand-copied into .env.local).
#   J1  a new key lands as KEY=value in <app>/.env (any name, e.g. GOOGLE_MAPS_API),
#       640, never echoed; --task clears the gate
#   J2  an existing .env.local wins over .env; other lines and the file's mode are
#       kept; a second write (and an `export KEY=` line) is replaced, not duplicated
#   J3  a value a .env line cannot hold as written is refused, nothing written
#   J4  a missing folder, a symlinked folder or a bare `project-` is refused BEFORE
#       the value is read (empty stdin would otherwise say "empty secret")
#   J5  a symlinked env file is refused and its target is untouched
#   J6  `task need` refuses to file a project gate for a folder that is not there,
#       and files one for a folder that is
#   J7  the --connector=tools refusal points at project-<app>
# Isolation: src/ sourced; a throwaway projects folder; `5dive` is a stub on PATH;
# no root, no network. The folder is owned by the running user, so the write runs
# directly; the runuser branch is graded only by J8 (source shape).
# Run: bash tests/secret_project_connector_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/secret-project-unit.XXXXXX)"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR" "$TMP/bin" "$TMP/projects"

cat > "$TMP/bin/5dive" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/answer.log"
EOF
chmod +x "$TMP/bin/5dive"
export PATH="$TMP/bin:$PATH"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_tool.sh cmd_secret.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
SECRET_PROJECTS_DIR="$TMP/projects"
TOOLS_WRITE_LOCK="$TMP/tool.lock"
SECRET_WRITE_LOCK="$TMP/secret.lock"
require_root() { :; }
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
put() { local v="$1"; shift; ( printf '%s\n' "$v" | _secret_write "$@" ) 2>&1; }

# --- J1: a new key lands in <app>/.env, any name ------------------------------
mkdir -p "$TMP/projects/maps"
: > "$TMP/answer.log"
out=$(put AIzaFAKE-maps_key.123 GOOGLE_MAPS_API --connector=project-maps --task=DIVE-7); rc=$?
E="$TMP/projects/maps/.env"
[[ $rc -eq 0 && "$(cat "$E" 2>/dev/null)" == "GOOGLE_MAPS_API=AIzaFAKE-maps_key.123" ]] \
  && ok_t "J1 GOOGLE_MAPS_API (no _KEY suffix) lands as one KEY=value line in <app>/.env" || bad_t "J1 write" "rc=$rc out=$out file=$(cat "$E" 2>&1)"
[[ "$(stat -c %a "$E" 2>/dev/null)" == 640 ]] && ok_t "J1 a new env file is 640" || bad_t "J1 mode" "$(stat -c %a "$E" 2>&1)"
[[ "$out" == *"$E"* && "$out" != *AIzaFAKE* ]] && ok_t "J1 says where it went, never the value" || bad_t "J1 message" "$out"
[[ "$(cat "$TMP/answer.log")" == "task answer DIVE-7 --human --from=drop" ]] \
  && ok_t "J1 --task clears the gate" || bad_t "J1 gate clear" "$(cat "$TMP/answer.log")"
[[ ! -e "$FIVEDIVE_CONNECTOR_DIR/project-maps.env" ]] && ! grep -qs GOOGLE_MAPS_API "$TOOLS_ENV_FILE" \
  && ok_t "J1 no connector file and nothing in tools.sh" || bad_t "J1 stray copy" "$(ls -A "$FIVEDIVE_CONNECTOR_DIR")"

# --- J2: .env.local wins; other lines and the mode survive; replace not append --
mkdir -p "$TMP/projects/web"
L="$TMP/projects/web/.env.local"
printf 'NEXT_PUBLIC_SITE=https://x.test\nexport GOOGLE_MAPS_API=old\nDB_URL=postgres://a\n' > "$L"
printf 'UNTOUCHED=1\n' > "$TMP/projects/web/.env"
chmod 600 "$L"
out=$(put AIzaNEW GOOGLE_MAPS_API --connector=project-web); rc=$?
want=$'NEXT_PUBLIC_SITE=https://x.test\nDB_URL=postgres://a\nGOOGLE_MAPS_API=AIzaNEW'
[[ $rc -eq 0 && "$(cat "$L")" == "$want" ]] \
  && ok_t "J2 .env.local is used when it exists; the old export line is replaced and the rest kept" || bad_t "J2 content" "rc=$rc $(cat "$L")"
[[ "$out" == *updated* ]] && ok_t "J2 reports updated" || bad_t "J2 action" "$out"
[[ "$(stat -c %a "$L")" == 600 ]] && ok_t "J2 the file's own mode (600) is kept" || bad_t "J2 mode" "$(stat -c %a "$L")"
[[ "$(cat "$TMP/projects/web/.env")" == "UNTOUCHED=1" ]] && ok_t "J2 .env is not touched when .env.local exists" || bad_t "J2 .env changed"
put AIzaTHIRD GOOGLE_MAPS_API --connector=project-web >/dev/null
[[ "$(grep -c '^GOOGLE_MAPS_API=' "$L")" == 1 && "$(grep '^GOOGLE_MAPS_API=' "$L")" == "GOOGLE_MAPS_API=AIzaTHIRD" ]] \
  && ok_t "J2 a second write replaces, never duplicates" || bad_t "J2 duplicate" "$(cat "$L")"
ls "$TMP/projects/web" | grep -q '\.env\.local\.' && bad_t "J2 temp file left behind" "$(ls -A "$TMP/projects/web")" || ok_t "J2 no temp file left behind"

# --- J3: a value a .env line cannot hold as written is refused ----------------
before=$(cat "$L")
for bad in 'has space' "it's" 'a$HOME' 'x#y' 'q"q'; do
  out=$(put "$bad" GOOGLE_MAPS_API --connector=project-web); rc=$?
  [[ $rc -ne 0 && "$(cat "$L")" == "$before" && "$out" == *"nothing was saved"* ]] \
    && ok_t "J3 refused, file unchanged: $bad" || bad_t "J3 must refuse: $bad" "rc=$rc out=$out"
done
out=$(put $'line1\nEVIL=1' GOOGLE_MAPS_API --connector=project-web); rc=$?
[[ $rc -ne 0 && "$(cat "$L")" == "$before" && ! -e "$FIVEDIVE_CONNECTOR_DIR/project-web.d" ]] \
  && ok_t "J3 a multi-line value is refused; no .d value file" || bad_t "J3 multi-line" "rc=$rc $(ls -A "$FIVEDIVE_CONNECTOR_DIR")"

# --- J4: no folder, a symlinked folder, a bare project- -> refused before stdin --
ln -s "$TMP/elsewhere" "$TMP/projects/linked"; mkdir -p "$TMP/elsewhere"
for c in project-nope project-linked project-; do
  # Empty stdin: had the value been read first, the refusal would be "empty
  # secret on stdin". The folder must be the reason.
  out=$( ( _secret_write GOOGLE_MAPS_API --connector="$c" < /dev/null ) 2>&1 ); rc=$?
  [[ $rc -ne 0 && "$out" == *"no project folder"* && "$out" != *"empty secret"* ]] \
    && ok_t "J4 $c refused before the value is read" || bad_t "J4 $c" "rc=$rc out=$out"
done
[[ -z "$(ls -A "$TMP/elsewhere")" ]] && ok_t "J4 nothing written through the symlinked folder" || bad_t "J4 wrote through link" "$(ls -A "$TMP/elsewhere")"

# --- J5: a symlinked env file is refused, its target untouched -----------------
mkdir -p "$TMP/projects/sneaky"
printf 'ROOT_ONLY=1\n' > "$TMP/target.conf"
ln -s "$TMP/target.conf" "$TMP/projects/sneaky/.env.local"
out=$(put AIzaX GOOGLE_MAPS_API --connector=project-sneaky); rc=$?
[[ $rc -ne 0 && "$(cat "$TMP/target.conf")" == "ROOT_ONLY=1" && -L "$TMP/projects/sneaky/.env.local" ]] \
  && ok_t "J5 a symlinked .env.local is refused; the file it points at is unchanged" || bad_t "J5 symlink" "rc=$rc out=$out target=$(cat "$TMP/target.conf")"

# --- J6: task need checks the folder at filing --------------------------------
for f in lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
SECRET_PROJECTS_DIR="$TMP/projects"
GATE_SEAM_INPROCESS=1
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" 2>/dev/null || true
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; JSON_MODE=1
tasks_db_init >/dev/null 2>&1
task_need_notify() { return 0; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-9101','t','todo','main'), ('DIVE-9102','t','todo','main');"
out=$(cmd_task_need DIVE-9101 --type=secret --ask="the Google Maps key for the site" --secret-key=GOOGLE_MAPS_API --connector=project-nope 2>&1); rc=$?
[[ $rc -eq 3 && "$out" == *"--connector=project-nope"* && "$out" == *"no project folder"* && "$(field DIVE-9101 need_type)" == "∅" ]] \
  && ok_t "J6 a gate for a missing project folder is refused at filing, no gate written" || bad_t "J6 refuse" "rc=$rc need_type=$(field DIVE-9101 need_type) out=$out"
cmd_task_need DIVE-9102 --type=secret --ask="the Google Maps key for the site" --secret-key=GOOGLE_MAPS_API --connector=project-maps >/dev/null 2>&1
got="$(field DIVE-9102 need_type)|$(field DIVE-9102 secret_key)|$(field DIVE-9102 connector)"
[[ "$got" == "secret|GOOGLE_MAPS_API|project-maps" ]] \
  && ok_t "J6 a gate for an existing folder files, with any variable name" || bad_t "J6 file" "got: $got"

# --- J7: the tools refusal names the way out ----------------------------------
out=$(put AIzaX GOOGLE_MAPS_API --connector=tools); rc=$?
[[ $rc -ne 0 && "$out" == *"--connector=project-<app>"* ]] \
  && ok_t "J7 --connector=tools refuses GOOGLE_MAPS_API and points at project-<app>" || bad_t "J7 hint" "rc=$rc out=$out"

# --- J8: the write drops to the folder owner, never root ----------------------
grep -qE 'runuser -u "\$powner" -- bash -c' src/cmd_secret.sh \
  && grep -qE 'stat -c %u "\$d"' src/lib/validation.sh \
  && ok_t "J8 a root caller writes as the folder owner (runuser), and a root-owned folder is refused" \
  || bad_t "J8 owner drop" "runuser branch or root-owned refusal missing"

printf '\nsecret project connector unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
