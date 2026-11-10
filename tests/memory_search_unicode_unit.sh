#!/usr/bin/env bash
# DIVE-8108 unit harness: `memory search` in the owner's language.
# The tokenizer kept only a-z0-9, so a Russian or Chinese query tokenized to
# nothing and returned a well-formed EMPTY result — which the router teaches an
# agent to read as "the fact does not exist". Synthetic store in a tempdir; no
# root, no network, no real agent store touched.
# Run: bash tests/memory_search_unicode_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

command -v node >/dev/null 2>&1 || { echo "SKIP: node absent"; exit 0; }
TMP="$(mktemp -d /tmp/mem-unicode-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source "$SRC/$f"; done
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { grep -q -- "$2" <<<"$1"; }

STORE="$TMP/memory"; mkdir -p "$STORE"
mk() { # mk <slug> <description> <body>
  printf -- '---\nname: %s\ndescription: %s\nmetadata:\n  type: reference\n---\n\n%s\n' "$1" "$2" "$3" > "$STORE/$1.md"
}
mk ru_car      "Где стоит машина клиента"          "Машина стоит на стоянке у офиса. Ключи у охранника."
mk ru_parking  "Где правила парковки"              "Стоянка платная; стоянки во дворе заняты по средам."
mk zh_release  "发布流程"                           "这是发布清单的说明，每次上线前逐项核对。"
mk en_guard    "Night guard rotation for the lobby" "The guard swaps at 22:00; the wifi password is on the desk."
mk en_filler   "Unrelated plumbing fact"            "Pipes, valves and a boiler that has nothing to do with cars."

run() { _memory_search "$@" --roots="$STORE" 2>&1; }

# ── Cyrillic exact ─────────────────────────────────────────────────────────
out="$(run "машина")"
has "$out" 'ru_car' && ok_t 'ru: "машина" returns the atom that says машина' || bad_t 'ru: машина missing' "$out"
has "$out" 'en_filler' && bad_t 'ru: unrelated atom matched' "$out" || ok_t 'ru: unrelated atoms do not match'
out="$(run "машина" --index)"
has "$out" 'ru_car' && ok_t 'ru: --index "машина" returns the row' || bad_t 'ru: --index машина missing' "$out"
out="$(run "Машина")"
has "$out" 'ru_car' && ok_t 'ru: case-folded (Машина == машина)' || bad_t 'ru: case not folded' "$out"
out="$(run "машина guard")"
{ has "$out" 'ru_car' && has "$out" 'en_guard'; } && ok_t 'mixed: a Cyrillic word and a Latin word both score' || bad_t 'mixed query lost a script' "$out"

# ── Cyrillic stem → prefix fallback ───────────────────────────────────────
out="$(run "стоянк" --index)"
has "$out" 'ru_parking' && ok_t 'ru: stem "стоянк" finds стоянка/стоянки (prefix fallback)' || bad_t 'ru: stem fallback missed' "$out"
has "$out" 'words starting with' && ok_t 'ru: the output says it fell back to a prefix match' || bad_t 'ru: prefix fallback not labelled' "$out"
out="$(run "стоя")"
has "$out" 'ru_parking' && ok_t 'ru: a 4-character stem also falls back' || bad_t 'ru: 4-char stem missed' "$out"
out="$(run "сто")"
has "$out" 'ru_parking' && bad_t 'ru: a 3-character stem must NOT prefix-match' "$out" || ok_t 'ru: stems under 4 characters do not prefix-match'

# ── CJK bigrams ───────────────────────────────────────────────────────────
out="$(run "发布清单")"
has "$out" 'zh_release' && ok_t 'zh: "发布清单" finds "这是发布清单的说明" (bigrams)' || bad_t 'zh: 发布清单 missed' "$out"
out="$(run "清单" --index)"
has "$out" 'zh_release' && ok_t 'zh: a two-character word inside a sentence is found' || bad_t 'zh: 清单 missed' "$out"
out="$(run "单")"
has "$out" 'zh_release' && ok_t 'zh: a lone character falls back to bigrams starting with it' || bad_t 'zh: lone char missed' "$out"

# ── Latin unchanged; exact always wins over prefix ────────────────────────
out="$(run "guard")"
has "$out" 'en_guard' && ok_t 'en: "guard" still returns its atom' || bad_t 'en: guard missing' "$out"
has "$out" 'words starting with' && bad_t 'en: an exact hit must not take the prefix path' "$out" || ok_t 'en: exact hit stays on the exact path'
out="$(run "wifi password")"
has "$out" 'en_guard' && ok_t 'en: multi-word Latin query unchanged' || bad_t 'en: wifi password missing' "$out"

# ── nothing searchable → error, not an empty result ───────────────────────
for q in '!!! ???' '—' '★ ✓'; do
  out="$(_memory_search "$q" --roots="$STORE" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && has "$out" 'no searchable words' \
    && ok_t "no words ('$q'): exits $rc with 'no searchable words'" \
    || bad_t "no words ('$q'): rc=$rc" "$out"
  has "$out" 'hits across' && bad_t "no words ('$q'): printed a normal empty result" "$out" || ok_t "no words ('$q'): no normal result printed"
done
# stdout must be empty on that path (the message is stderr)
out="$(_memory_search '???' --roots="$STORE" 2>/dev/null)"
[ -z "$out" ] && ok_t 'no words: message goes to stderr, stdout empty' || bad_t 'no words: stdout not empty' "$out"

# ── router topic words see Cyrillic ───────────────────────────────────────
r="$(_memory_router --root="$STORE" --recent=0 2>&1)"
line="$(grep -F -- '**reference** — 5 atoms' <<<"$r")"
grep -q -- '[а-яё]' <<<"$line" \
  && ok_t "router: Cyrillic words appear among the topic words ($line)" \
  || bad_t 'router: no Cyrillic topic words' "$r"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
