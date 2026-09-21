#!/usr/bin/env bash
# DIVE-4779 step 1 — THE BOARD READ CONTRACT, graded as a contract and not as a verb.
#
# WHY THIS HARNESS EXISTS. The plugin port of `5dive ui` reads core's private
# sqlite store through five query strings naming ~30 columns. A string coupling is
# invisible to core: rename a column and the plugin still builds, still installs,
# and fails in a browser. `5dive board` replaces that with one versioned document
# — and a versioned document is only worth anything if something REDS when the
# version and the document drift apart. That is most of what is below.
#
# THE THREE PROPERTIES, in the order they matter:
#   1. NEGOTIATION IS TOTAL AND STORE-FREE. `--contract-version` must answer on a
#      box whose store is absent or unreadable, because those are exactly the
#      boxes where a consumer most needs the answer before it renders anything.
#   2. THE DOCUMENT IS THE CONTRACT. Every key version 1 promises is present in
#      BOTH emit paths — the populated board and the store-absent board, which is
#      a separate jq expression and therefore a separate chance to forget one.
#   3. THE VERSION CANNOT DRIFT FROM ITS DOCUMENTATION. The constant in
#      src/cmd_board.sh and the number in docs/board-contract.md are two copies of
#      one fact, so a mismatch is a red, not a review comment.
#
# Run: bash tests/board_contract_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/dive4779.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# A REAL BUNDLE, not a sourced tree. The consumer this contract exists for is a
# separate executable that runs `5dive board` — so the thing under test is the
# built binary's behaviour, including that cmd_board.sh is actually concatenated
# into it. Sourcing src/ would grade a file the plugin never sees.
BIN="$TMP/5dive"
BUILD_OUT="$BIN" ./build.sh >/dev/null 2>&1 \
  || { printf 'FATAL: build.sh failed; nothing below can be graded.\n' >&2; exit 1; }
[[ -x "$BIN" ]] || { printf 'FATAL: no bundle at %s\n' "$BIN" >&2; exit 1; }

# The keys version 1 promises. Kept as ONE list so a key added to the document
# without being added here is not silently ungraded.
V1_KEYS="contract scope store host generated_at org queue gates flows triggers deliveries stats"
V1_STATS="agents open gates delegated agent_to_agent human_touch awaiting_verify in_review triggers trigger_deliveries"

echo "── A: the constant, and the one thing that keeps it honest ──"
SRC_V=$(grep -E '^FIVEDIVE_BOARD_CONTRACT_VERSION=' src/cmd_board.sh | head -1 | cut -d= -f2)
[[ "$SRC_V" =~ ^[0-9]+$ ]] && ok_t "A1 src/cmd_board.sh declares an integer contract version ($SRC_V)" \
  || bad_t "A1 contract version is an integer" "got '$SRC_V'"
BIN_V=$("$BIN" board --contract-version 2>/dev/null)
[[ "$BIN_V" == "$SRC_V" ]] && ok_t "A2 the built bundle reports the same version ($BIN_V) — cmd_board.sh IS in build.sh" \
  || bad_t "A2 bundle version matches source" "bundle said '$BIN_V', source says '$SRC_V' — if the bundle is empty, cmd_board.sh is missing from build.sh's file list"
# THE DRIFT TRIPWIRE. The version lives in two places by necessity (a consumer
# reads the code, a human reads the doc) and two copies of one fact is a defect
# waiting for a release. Graded, not trusted.
DOC_V=$(grep -oE '^\| [0-9]+ \|' docs/board-contract.md | grep -oE '[0-9]+' | sort -rn | head -1)
[[ "$DOC_V" == "$SRC_V" ]] \
  && ok_t "A3 docs/board-contract.md's newest change-log row is version $DOC_V — no drift" \
  || bad_t "A3 doc and code agree on the version" "doc's newest row is '$DOC_V', code says '$SRC_V'; bumping one without the other is the whole failure this verb exists to prevent"
grep -q '^\*\*Status:\*\* accepted' docs/board-contract.md \
  && ok_t "A4 the decision record is marked accepted (it is a decision, not a proposal)" \
  || bad_t "A4 decision record status"
for alt in "read-only SQL view" "schema-version floor"; do
  grep -qi "$alt" docs/board-contract.md \
    && ok_t "A5 the record names the alternative not taken: $alt" \
    || bad_t "A5 alternative recorded: $alt" "the row required the alternative not taken to be written down"
done

echo "── B: negotiation is TOTAL and touches no store ──"
# Point the bundle at a directory that does not exist, then at one that is not
# readable. `--contract-version` must answer both times: a consumer asks this
# BEFORE it knows whether it can read anything.
MISSING="$TMP/no-such-state"
v=$(STATE_DIR="$MISSING" TASKS_DIR="$MISSING/tasks" TASKS_DB="$MISSING/tasks/tasks.db" "$BIN" board --contract-version 2>/dev/null); rc=$?
[[ "$rc" == "0" && "$v" == "$SRC_V" ]] \
  && ok_t "B1 --contract-version answers with NO STORE AT ALL (rc=0, '$v')" \
  || bad_t "B1 store-free negotiation" "rc=$rc out='$v' — a consumer on a fresh box could not negotiate"
UNREADABLE="$TMP/locked"; mkdir -p "$UNREADABLE/tasks"; : >"$UNREADABLE/tasks/tasks.db"; chmod 000 "$UNREADABLE/tasks/tasks.db"
v=$(STATE_DIR="$UNREADABLE" TASKS_DIR="$UNREADABLE/tasks" TASKS_DB="$UNREADABLE/tasks/tasks.db" "$BIN" board --contract-version 2>/dev/null); rc=$?
chmod 644 "$UNREADABLE/tasks/tasks.db" 2>/dev/null
[[ "$rc" == "0" && "$v" == "$SRC_V" ]] \
  && ok_t "B2 ...and with an UNREADABLE store (rc=0, '$v')" \
  || bad_t "B2 negotiation survives an unreadable store" "rc=$rc out='$v'"
# The bare integer, not an envelope: a shell consumer must not need jq on its
# negotiation path.
[[ "$("$BIN" board --contract-version 2>/dev/null)" =~ ^[0-9]+$ ]] \
  && ok_t "B3 it prints a BARE integer — no JSON envelope, no jq needed to negotiate" \
  || bad_t "B3 bare integer" "got: $("$BIN" board --contract-version 2>&1 | head -1)"
[[ "$("$BIN" board --contract-name 2>/dev/null)" == "5dive.board" ]] \
  && ok_t "B4 --contract-name identifies the contract (5dive.board)" || bad_t "B4 contract name"

echo "── C: the document, on a POPULATED board ──"
doc=$("$BIN" board --json 2>/dev/null)
[[ -n "$doc" ]] && printf '%s' "$doc" | jq -e . >/dev/null 2>&1 \
  && ok_t "C1 \`board --json\` emits parseable JSON" || bad_t "C1 parseable JSON" "$(printf '%s' "$doc" | head -3)"
[[ "$(printf '%s' "$doc" | jq -r '.ok')" == "true" ]] && ok_t "C2 ok:true envelope" || bad_t "C2 envelope"
[[ "$(printf '%s' "$doc" | jq -r '.data.contract.version')" == "$SRC_V" \
   && "$(printf '%s' "$doc" | jq -r '.data.contract.name')" == "5dive.board" ]] \
  && ok_t "C3 the document CARRIES its own contract block (a consumer that only has the document can still check)" \
  || bad_t "C3 contract block in the document" "got $(printf '%s' "$doc" | jq -c '.data.contract')"
miss=""
for k in $V1_KEYS; do printf '%s' "$doc" | jq -e --arg k "$k" '.data | has($k)' >/dev/null 2>&1 || miss="$miss $k"; done
[[ -z "$miss" ]] && ok_t "C4 every version-1 key is present on a populated board" \
  || bad_t "C4 version-1 keys present" "missing:$miss"
smiss=""
for k in $V1_STATS; do printf '%s' "$doc" | jq -e --arg k "$k" '.data.stats | has($k)' >/dev/null 2>&1 || smiss="$smiss $k"; done
[[ -z "$smiss" ]] && ok_t "C5 every version-1 stats key is present" || bad_t "C5 stats keys" "missing:$smiss"
for k in org queue gates flows triggers deliveries; do
  [[ "$(printf '%s' "$doc" | jq -r --arg k "$k" '.data[$k] | type')" == "array" ]] \
    && ok_t "C6 .data.$k is an array (type is part of the contract, not just the key)" \
    || bad_t "C6 .data.$k type" "got $(printf '%s' "$doc" | jq -r --arg k "$k" '.data[$k] | type')"
done

echo "── D: the STORE-ABSENT document is a separate expression, so grade it separately ──"
# The producer builds the empty board with its own jq -n literal. A key added to
# the populated branch and forgotten here is a consumer crash on a fresh box —
# the single most likely shape of contract bug in this file.
adoc=$(STATE_DIR="$MISSING" TASKS_DIR="$MISSING/tasks" TASKS_DB="$MISSING/tasks/tasks.db" "$BIN" board --json 2>/dev/null)
[[ -n "$adoc" ]] && printf '%s' "$adoc" | jq -e . >/dev/null 2>&1 \
  && ok_t "D1 a box with NO store still serves the document (not an error)" || bad_t "D1 empty board served" "$adoc"
[[ "$(printf '%s' "$adoc" | jq -r '.data.store')" == "absent" ]] \
  && ok_t "D2 ...and NAMES the state: store='absent' — 'nowhere to queue anything', not 'nothing queued'" \
  || bad_t "D2 store=absent" "got $(printf '%s' "$adoc" | jq -r '.data.store')"
amiss=""
for k in $V1_KEYS; do printf '%s' "$adoc" | jq -e --arg k "$k" '.data | has($k)' >/dev/null 2>&1 || amiss="$amiss $k"; done
[[ -z "$amiss" ]] && ok_t "D3 EVERY version-1 key is present on the store-absent board too" \
  || bad_t "D3 keys on the empty board" "missing:$amiss — a consumer on a fresh box crashes on these"
asmiss=""
for k in $V1_STATS; do printf '%s' "$adoc" | jq -e --arg k "$k" '.data.stats | has($k)' >/dev/null 2>&1 || asmiss="$asmiss $k"; done
[[ -z "$asmiss" ]] && ok_t "D4 ...including every stats key" || bad_t "D4 empty-board stats keys" "missing:$asmiss"
[[ "$(printf '%s' "$adoc" | jq -r '.data.contract.version')" == "$SRC_V" ]] \
  && ok_t "D5 ...and the contract block" || bad_t "D5 contract block on the empty board"

echo "── E: THE NAME IS RELEASED — ui left core, and the shim is a FALLTHROUGH ──"
# DIVE-4783 steps 2-3. `board` is now the ONLY producer of this document in core;
# the UI is `5dive-ai/5dive-ui` and reads it. What this section grades is not the
# document but the thing that lets the plugin exist at all: core must have given
# the NAME up, in both enumerations at once. A shim that kept `ui` as a case
# label would keep it in FIVEDIVE_BUILTIN_VERBS (T5 asserts set equality), and
# _plugin_verb_is_builtin would then refuse `plugin add 5dive-ai/5dive-ui` on
# every box forever — the plugin would be inert and the refusal would be correct.
grep -q ' ui ' <(grep -E '^readonly FIVEDIVE_BUILTIN_VERBS=' src/cmd_plugin.sh) \
  && bad_t "E1 the name is released" "\`ui\` is back in FIVEDIVE_BUILTIN_VERBS — _plugin_verb_is_builtin will refuse the plugin's own verb claim" \
  || ok_t "E1 \`ui\` is gone from FIVEDIVE_BUILTIN_VERBS, so the plugin's verb claim resolves"
awk 'f&&/^}$/{exit} /^main\(\) \{$/{f=1} f' src/main.sh | grep -qE '^    ui\)' \
  && bad_t "E2 no dispatch label" "main() still answers \`ui\` itself — a builtin always wins over a plugin verb" \
  || ok_t "E2 ...and out of main()'s case table too (the two enumerations moved together)"
[[ -e src/cmd_ui.sh ]] \
  && bad_t "E3 the file is gone" "src/cmd_ui.sh is still in the tree" \
  || ok_t "E3 src/cmd_ui.sh is deleted — one producer, in one repo"
ushim=$("$BIN" ui 2>&1 >/dev/null); urc=0; "$BIN" ui >/dev/null 2>&1 || urc=$?
[[ "$urc" != "0" ]] && printf '%s' "$ushim" | grep -q '5dive plugin add 5dive-ai/5dive-ui' \
  && ok_t "E4 an un-migrated box gets the install line and a non-zero exit (rc=$urc), not \"unknown command\" alone" \
  || bad_t "E4 the moved-verb notice" "rc=$urc, stderr: $(printf '%s' "$ushim" | tr '\n' ' ')"

# The usage text is a cat <<USAGE heredoc, which SUBSTITUTES `cmd`. A backtick
# around a verb name in there runs that verb on every --help — silently, and for
# a MOVED verb it runs the shim, so the notice lands on the stderr of a person
# who only asked for help. Cheap arm, whole class.
helpout=$("$BIN" --help 2>"$TMP/help.err"); helperr=$(cat "$TMP/help.err")
printf '%s' "$helpout" | grep -q '5dive plugin add 5dive-ai/5dive-ui' \
  && ok_t "E5 --help tells you where the UI went" \
  || bad_t "E5 --help names the plugin" "the install line is not in the usage text"
[[ -z "$helperr" ]] \
  && ok_t "E6 ...and --help writes NOTHING to stderr (no backticked verb ran inside the heredoc)" \
  || bad_t "E6 --help is quiet on stderr" "got: $(printf '%s' "$helperr" | tr '\n' ' ')"

echo "── F: the verb is reachable and refuses what it should ──"
grep -qE '^\s+board\)' src/main.sh && ok_t "F1 registered in main.sh's dispatch" || bad_t "F1 registered"
grep -q ' board ' <(grep -E '^readonly FIVEDIVE_BUILTIN_VERBS=' src/cmd_plugin.sh) \
  && ok_t "F2 declared a BUILTIN verb — a plugin cannot shadow the contract it reads" \
  || bad_t "F2 builtin verb" "a plugin could claim \`board\` and answer for core"
"$BIN" board --nonsense >/dev/null 2>&1 && bad_t "F3 unknown flag refused" "it accepted --nonsense" \
  || ok_t "F3 an unknown flag is refused"
"$BIN" board extra-arg >/dev/null 2>&1 && bad_t "F4 positional refused" "it accepted a positional" \
  || ok_t "F4 a positional argument is refused"
"$BIN" board --json >/dev/null 2>&1 && ok_t "F5 --json is accepted as a no-op (habit must not be a usage error)" \
  || bad_t "F5 --json accepted"
"$BIN" board -h 2>/dev/null | grep -q 'contract-version' \
  && ok_t "F6 --help names the negotiation flag" || bad_t "F6 help names it"

echo "── M: MUTATION ARMS — revert each divergence, assert the property reds ──"
# MUTATION IN PLACE, AND RESTORED FROM A BYTE COPY. An earlier version copied the
# tree to $TMP and built there; build.sh needs a git repo to stamp BUILD_SHA, so
# every copied build failed — and the arm counted a build failure as RED. Four of
# five arms scored green having graded nothing. A build failure is now a HARNESS
# ERROR, loudly, because it is the one outcome that cannot distinguish a working
# mutation from a broken one.
MUTBIN="$TMP/5dive-mut"
# MUT_LINES is the arm's declared BLAST RADIUS: how many source lines the sed is
# supposed to hit. It exists because "it applied somewhere" is not the same as
# "it applied everywhere the property lives". DIVE-4779 iteration 1 shipped a
# mutation anchored on one of the contract block's TWO emit paths; it applied,
# the tree changed, and the arm then graded whichever document the box happened
# to serve — green in CI (no store, absent path, unmutated) and red here (a
# populated store). A count is the only thing that tells those two apart.
mut() { # [MUT_LINES=n] <name> <sed-expr> <file> <check-cmd...>
  local name="$1" expr="$2" file="$3"; shift 3
  local want="${MUT_LINES:-1}"; unset MUT_LINES   # one arm at a time; never leaks to the next
  local bak="$TMP/bak-$RANDOM"; cp "$file" "$bak"
  sed -i "$expr" "$file"
  if cmp -s "$bak" "$file"; then
    cp "$bak" "$file"
    bad_t "M:$name THE MUTATION DID NOT APPLY" "the sed matched nothing in $file, so this arm would grade the UNMUTATED tree — a vacuous green, not a pass"
    return
  fi
  local hit; hit=$(diff "$bak" "$file" | grep -c '^<')
  if [[ "$hit" != "$want" ]]; then
    cp "$bak" "$file"
    bad_t "M:$name THE MUTATION HIT $hit SITE(S), THE ARM DECLARES $want" "a partial mutation greens wherever the untouched site is the one that answers — that is environment-dependent grading, not a pass. Re-anchor the sed or correct MUT_LINES."
    return
  fi
  local built=1
  BUILD_OUT="$MUTBIN" ./build.sh >/dev/null 2>&1 || built=0
  if (( built )); then
    ( MUTBIN="$MUTBIN" "$@" ) >/dev/null 2>&1
    local rc=$?
    cp "$bak" "$file"
    [[ "$rc" != "0" ]] && ok_t "M:$name reverting it turns the property RED (rc=$rc)" \
      || bad_t "M:$name the property survived its own mutation" "green on a tree without the fix — this arm grades nothing"
  else
    cp "$bak" "$file"
    bad_t "M:$name THE MUTATED TREE DID NOT BUILD" "a build failure is not evidence the property is guarded — it means this arm graded nothing. Fix the mutation so it produces a buildable tree."
  fi
}
# M1 — the drift tripwire itself. Bump the code's version and leave the doc alone;
# arm A3's comparison must red, or "two copies of one fact" is unguarded.
mut "version-drift" 's|^FIVEDIVE_BOARD_CONTRACT_VERSION=1|FIVEDIVE_BOARD_CONTRACT_VERSION=2|' 'src/cmd_board.sh' \
    bash -c 'v=$(grep -E "^FIVEDIVE_BOARD_CONTRACT_VERSION=" src/cmd_board.sh | cut -d= -f2); d=$(grep -oE "^\| [0-9]+ \|" docs/board-contract.md | grep -oE "[0-9]+" | sort -rn | head -1); [[ "$v" == "$d" ]]'
# M2 — store-free negotiation. Let --contract-version fall through to the producer
# and it stops answering on a box with no store, so the consumer's only pre-flight
# check becomes a store read — the exact property the refused view option lacked.
mut "store-free-negotiation" '/--contract-version) printf/s|.*|      --contract-version) : ;;|' 'src/cmd_board.sh' \
    bash -c 'm=$(mktemp -d); STATE_DIR="$m/none" TASKS_DIR="$m/none/tasks" TASKS_DB="$m/none/tasks/tasks.db" "$MUTBIN" board --contract-version 2>/dev/null | grep -qE "^[0-9]+$"'
# M3 — the moved-verb notice. Drop `ui` from the fallthrough table: the verb is
# still gone from core, still non-zero, and a human is told it never existed.
# That is the silent-nothing outcome acceptance names, and arm E4 must red on it.
mut "moved-verb-notice" '/^    ui) printf .5dive-ai\/5dive-ui/s|.*|    __never_a_verb__) return 1 ;;|' 'src/main.sh' \
    bash -c 'out=$("$MUTBIN" ui 2>&1 >/dev/null); "$MUTBIN" ui >/dev/null 2>&1 && exit 1; printf "%s" "$out" | grep -q "5dive plugin add 5dive-ai/5dive-ui"'
# M4 — the contract block inside the document. A consumer handed only the document
# must be able to check the version without a second exec.
# BOTH emit paths, and the property asserted on BOTH documents. The populated
# board and the store-absent board are separate jq expressions (property 2 in the
# header), so a single-site mutation is graded by whichever one the environment
# serves — and CI has no store. MUT_LINES=2 makes that a loud harness failure
# rather than a silent vacuous green.
MUT_LINES=2 mut "contract-in-document" 's|contract: {name: \$cn, version: \$cv},||g' 'src/cmd_board.sh' \
    bash -c 'm=$(mktemp -d); "$MUTBIN" board --json 2>/dev/null | jq -e ".data.contract.version" >/dev/null \
             && STATE_DIR="$m/none" TASKS_DIR="$m/none/tasks" TASKS_DB="$m/none/tasks/tasks.db" \
                "$MUTBIN" board --json 2>/dev/null | jq -e ".data.contract.version" >/dev/null'
# M5 — the bundle actually carries the file. Drop cmd_board.sh from build.sh's
# list: the source is perfect and the verb does not exist on a box.
mut "in-the-bundle" '\|^  src/cmd_board.sh$|d' 'build.sh' \
    bash -c '"$MUTBIN" board --contract-version 2>/dev/null | grep -qE "^[0-9]+$"'
# The tree must be byte-identical to how it started, or a later arm (or a commit)
# carries a mutation. Asserted, not assumed.
BUILD_OUT="$TMP/5dive-restored" ./build.sh >/dev/null 2>&1 \
  && [[ "$("$TMP/5dive-restored" board --contract-version 2>/dev/null)" == "$SRC_V" ]] \
  && ok_t "M6 the tree is restored after every mutation (the bundle rebuilds and reports $SRC_V)" \
  || bad_t "M6 tree restored" "a mutation was left in the working tree — do not commit this"

printf '\n%s\n' "── $PASS pass, $FAIL fail ──"
[[ "$FAIL" -eq 0 ]]
