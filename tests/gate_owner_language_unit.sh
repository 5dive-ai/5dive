#!/usr/bin/env bash
# DIVE-6433 — A HUMAN GATE SPEAKS ITS OWNER'S LANGUAGE.
#
# lodar, 2026-10-17: a partner's owners mostly write in Russian, and every gate reached
# them in English. The gate's chrome (header, Recommended line, buttons, CTAs)
# now follows the `lite-lang` file the telegram plugin writes beside the
# channel's access.json from the owner's Telegram language_code. The ask and the
# options stay the filing agent's words, so the agent is told which language to
# write them in: the dispatch line says so, and `task need` warns on an ask with
# no Russian in it.
#
# Properties, each against a control:
#   1. en (no lite-lang, or lite-lang=en) renders the pre-DIVE-6433 literals, and
#      the two en sources render byte-identically.
#   2. ru renders a Russian header, Recommended line and buttons.
#   3. callback_data is byte-identical across languages, so a tap on the Russian
#      button answers the gate the same way (the plugin half is pinned in
#      5dive-plugins test/dive6433-gate-language.test.ts).
#   4. every _gate_t key has a ru arm AND an en arm.
#   5. `task need` warns on a ru box when the ask has no Cyrillic; not otherwise.
#   6. the dispatch line tells a ru seat to write the ask in Russian; an en seat's
#      line is unchanged.
# Run: bash tests/gate_owner_language_unit.sh   (no root, no network)
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
export _5DIVE_GATE_UNDO_WINDOW_SECS=0

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-owner-language-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e

export FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"; : >"$FIVEDIVE_GATE_NOTIFY_LOG"
AUDIT_LOG_FILE="$TMP/audit.log"; : >"$AUDIT_LOG_FILE"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }
5dive() { return 0; }

# The channel lives at $CH/access.json; lite-lang beside it is what the plugin writes.
CH="$TMP/home/agent-marketing/claude"; mkdir -p "$CH"; echo '{"allowFrom":[]}' >"$CH/access.json"
_tg_access_state_dir() { printf '%s/home/%s/%s' "$TMP" "$1" "$2"; }
SENT="$TMP/sent.txt"; : >"$SENT"
# $4 is the keyboard-less fallback text (DIVE-4412): the one variant that always
# carries the Recommended line, because there no ⭐ button says it.
_task_send_owner() { printf '%s\n--MARKUP--\n%s\n--PLAIN--\n%s\n' "$1" "$2" "${4:-}" >>"$SENT"; return 0; }
_task_owner_channel() { TASK_CH_TOKEN="t"; TASK_CH_ACCESS="$CH/access.json"; TASK_CH_TYPE="claude"; TASK_CH_AGENT="marketing"; return 0; }
set_lang() { if [[ -z "$1" ]]; then rm -f "$CH/lite-lang"; else printf '%s' "$1" >"$CH/lite-lang"; fi; }
# <ident> <type> <ask> <options> <recommend>
alert_of() { : >"$SENT"; _task_need_notify_deliver "$1" "$2" "$3" "$4" "$5" >/dev/null 2>&1; cat "$SENT"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }
JSON_MODE=0

tasks_db_init
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('marketing','main','builder');"
seed() { db "INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('$1','t','todo','main','marketing');"; }
seed DIVE-9101; seed DIVE-9102
cmd_task_need DIVE-9101 --type=decision --from=marketing --ask="Какой тариф включить?" --options="Базовый|Плюс" --recommend="Плюс" >/dev/null 2>&1
cmd_task_need DIVE-9102 --type=approval --from=marketing --ask="Отправить письмо клиенту?" --recommend="approved" >/dev/null 2>&1
id1=$(db "SELECT id FROM tasks WHERE ident='DIVE-9101';"); id2=$(db "SELECT id FROM tasks WHERE ident='DIVE-9102';")

# ---------------------------------------------------------------------------
# 1. en: the old literals, and no-file == lite-lang=en byte for byte.
# ---------------------------------------------------------------------------
set_lang "";  EN0_D=$(alert_of DIVE-9101 decision "Какой тариф включить?" "Базовый|Плюс" "Плюс"); EN0_A=$(alert_of DIVE-9102 approval "Отправить письмо клиенту?" "" approved)
set_lang en;  EN1_D=$(alert_of DIVE-9101 decision "Какой тариф включить?" "Базовый|Плюс" "Плюс"); EN1_A=$(alert_of DIVE-9102 approval "Отправить письмо клиенту?" "" approved)
check "1a: en header is '🙋 [DIVE-9101] needs you'" '[[ "$EN0_D" == "🙋 [DIVE-9101] needs you"* ]]' "$EN0_D"
check "1b: en approval: '✅ Recommended: approved' (fallback text) and the Approve/Deny buttons" \
  '[[ "$EN0_A" == *"✅ Recommended: approved"* && "$EN0_A" == *"⭐ ✅ Approve"* && "$EN0_A" == *"🚫 Deny"* ]]' "$EN0_A"
check "1c: no lite-lang and lite-lang=en render byte-identically" '[[ -n "$EN0_D" && "$EN0_D" == "$EN1_D" && "$EN0_A" == "$EN1_A" ]]'
set_lang de;  DE_A=$(alert_of DIVE-9102 approval "Отправить письмо клиенту?" "" approved)
check "1d: any other language falls back to en" '[[ "$DE_A" == "$EN0_A" ]]'

# ---------------------------------------------------------------------------
# 2. ru: header, Recommended line, buttons.
# ---------------------------------------------------------------------------
set_lang ru-RU; RU_D=$(alert_of DIVE-9101 decision "Какой тариф включить?" "Базовый|Плюс" "Плюс"); RU_A=$(alert_of DIVE-9102 approval "Отправить письмо клиенту?" "" approved)
check "2a: ru header" '[[ "$RU_D" == "🙋 [DIVE-9101] ждёт вашего ответа"* ]]' "$RU_D"
check "2b: ru approval: the Recommended line (fallback text) names the choice in Russian" '[[ "$RU_A" == *"✅ Рекомендую: одобрить"* ]]' "$RU_A"
check "2c: ru approval buttons" '[[ "$RU_A" == *"⭐ ✅ Одобрить"* && "$RU_A" == *"🚫 Отклонить"* ]]' "$RU_A"
check "2d: ru decision ⭐ button carries the recommended option" '[[ "$RU_D" == *"⭐ Плюс"* ]]' "$RU_D"
check "2e: ru message carries none of the en chrome" \
  '[[ "$RU_A$RU_D" != *"needs you"* && "$RU_A$RU_D" != *"Recommended:"* && "$RU_A$RU_D" != *"Approve"* ]]' "$RU_A"
ru_plain=$(TASK_CH_ACCESS="$CH/access.json" _gate_t onbox_decision DIVE-9101)
check "2f: the on-box line keeps the English command" '[[ "$ru_plain" == *"sudo 5dive task answer DIVE-9101 --value="* ]]' "$ru_plain"

# ---------------------------------------------------------------------------
# 3. callback_data is language-neutral.
# ---------------------------------------------------------------------------
cb() { grep -o 'tna:[0-9]*:[a-z0-9]*' <<<"$1" | sort | tr '\n' ' '; }
check "3a: decision callback_data identical en vs ru" '[[ -n "$(cb "$EN0_D")" && "$(cb "$EN0_D")" == "$(cb "$RU_D")" ]]' "en=$(cb "$EN0_D") ru=$(cb "$RU_D")"
check "3b: approval callback_data identical en vs ru" '[[ -n "$(cb "$EN0_A")" && "$(cb "$EN0_A")" == "$(cb "$RU_A")" ]]' "en=$(cb "$EN0_A") ru=$(cb "$RU_A")"
set_lang ru
for t in manual secret; do
  m_ru=$(TASK_CH_ACCESS="$CH/access.json" _task_gate_reply_markup "$id2" "$t" "" "" "" claude)
  set_lang en; m_en=$(TASK_CH_ACCESS="$CH/access.json" _task_gate_reply_markup "$id2" "$t" "" "" "" claude); set_lang ru
  check "3c/$t: callback_data identical en vs ru" '[[ "$(cb "$m_en")" == "$(cb "$m_ru")" ]]' "en=$m_en ru=$m_ru"
done

# ---------------------------------------------------------------------------
# 4. every key has both arms (a key added to one table only reads empty).
# ---------------------------------------------------------------------------
keys=$(sed -n '/^_gate_t() {/,/^}/p' src/task/notify.sh | grep -oE '^ +[a-z_]+\)' | tr -d ' )' | sort | uniq -c)
lone=$(awk '$1 != 2 {print $2}' <<<"$keys" | tr '\n' ' ')
check "4: every _gate_t key has a ru and an en arm ($(wc -l <<<"$keys") keys)" '[[ -z "$lone" && $(wc -l <<<"$keys") -ge 30 ]]' "one-armed: $lone"

# ---------------------------------------------------------------------------
# 5. task need warns on an English ask when the owner writes in Russian, and only then.
# ---------------------------------------------------------------------------
actor_routing_agent() { printf marketing; }
need_warn() { seed "$1"; cmd_task_need "$1" --type=approval --from=marketing --ask="$2" 2>&1 >/dev/null | grep -c 'owner reads Russian'; }
set_lang ru; w1=$(need_warn DIVE-9111 "Send the reply to the customer?"); w2=$(need_warn DIVE-9112 "Отправить ответ клиенту?")
set_lang en; w3=$(need_warn DIVE-9113 "Send the reply to the customer?")
check "5a: ru owner + English ask -> warned" '[[ "$w1" == 1 ]]' "count=$w1"
check "5b: ru owner + Russian ask -> silent" '[[ "$w2" == 0 ]]' "count=$w2"
check "5c: en owner + English ask -> silent" '[[ "$w3" == 0 ]]' "count=$w3"

# ---------------------------------------------------------------------------
# 6. the dispatch line.
# ---------------------------------------------------------------------------
set_lang en; n_en=$(_hb_nudge_text marketing "$id1" DIVE-9101 2>/dev/null)
set_lang ru; n_ru=$(_hb_nudge_text marketing "$id1" DIVE-9101 2>/dev/null)
rm -f "$CH/lite-lang"; n_none=$(_hb_nudge_text marketing "$id1" DIVE-9101 2>/dev/null)
check "6a: a ru seat's dispatch says to write the ask in Russian" '[[ "$n_ru" == *"Your owner reads Russian"* ]]' "$n_ru"
check "6b: an en seat's dispatch is unchanged" '[[ -n "$n_en" && "$n_en" == "$n_none" && "$n_en" != *"Russian"* ]]'

# ---------------------------------------------------------------------------
# 7. DIVE-6856: a partner box (TELEGRAM_ACCOUNT_URL in the channel .env). The
#    secret ask is the ask, one plain line and a button: no "5dive", no task id,
#    no /task_N, no command — first alert and reminder alike. Control: the same
#    gate on a box with no partner link still renders the 5dive copy.
# ---------------------------------------------------------------------------
APP="https://t.me/ExampleAppBot?startapp"
set_partner() { if [[ -n "$1" ]]; then printf 'TELEGRAM_BOT_TOKEN=t\nTELEGRAM_ACCOUNT_URL=%s\n' "$1" >"$CH/.env"; else rm -f "$CH/.env"; fi; }
MINT=""; _task_mint_drop_link() { printf '%s' "$MINT"; }
_secret_drop_live_for() { return 1; }
clean() { [[ "$1" != *5dive* && "$1" != *DIVE-* && "$1" != */task* && "$1" != *sudo* && "$1" != *tna:* ]]; }
set_lang ru; seed DIVE-9121; seed DIVE-9122
cmd_task_need DIVE-9121 --type=secret --from=marketing --ask="Нужен ключ HeyGen для видео." --secret-key=HEYGEN_API_KEY --connector=tools >/dev/null 2>&1
cmd_task_need DIVE-9122 --type=manual --from=marketing --ask="Подключите домен." >/dev/null 2>&1
id21=$(db "SELECT id FROM tasks WHERE ident='DIVE-9121';")
set_partner "$APP"; MINT="";                                 P_APP=$(: >"$SENT"; _task_need_notify_deliver DIVE-9121 secret "Нужен ключ HeyGen для видео." "" "" HEYGEN_API_KEY tools >/dev/null 2>&1; cat "$SENT")
MINT="https://secrets.example.test/tok123|30";               P_LNK=$(: >"$SENT"; _task_need_notify_deliver DIVE-9121 secret "Нужен ключ HeyGen для видео." "" "" HEYGEN_API_KEY tools >/dev/null 2>&1; cat "$SENT")
set_partner "";  MINT="";                                    C_APP=$(: >"$SENT"; _task_need_notify_deliver DIVE-9121 secret "Нужен ключ HeyGen для видео." "" "" HEYGEN_API_KEY tools >/dev/null 2>&1; cat "$SENT")
check "7a: partner, no link: the ask + one plain line, nothing that names 5dive, a task or a command" \
  'clean "$P_APP" && [[ "$P_APP" == "Нужен ключ HeyGen для видео."* && "$P_APP" == *"HEYGEN_API_KEY"*"Открыть защищённую ссылку"* ]]' "$P_APP"
check "7b: partner, no link: the one button opens the partner's app (from its config), the plain fallback carries the link" \
  '[[ $(jq -r ".inline_keyboard[0][0].url" <<<"$(sed -n "/^--MARKUP--$/{n;p;}" <<<"$P_APP")") == "$APP" && "$(sed -n "/^--PLAIN--$/,\$p" <<<"$P_APP")" == *"$APP"* ]]' "$P_APP"
check "7c: partner, link minted: the line, the link and a button that opens it, still clean" \
  'clean "$P_LNK" && [[ "$P_LNK" == *"https://secrets.example.test/tok123"* && $(jq -r ".inline_keyboard[0][0].url" <<<"$(sed -n "/^--MARKUP--$/{n;p;}" <<<"$P_LNK")") == "https://secrets.example.test/tok123" ]]' "$P_LNK"
check "7d: control — the same gate with no partner link keeps the 5dive copy" '[[ "$C_APP" == *"5dive"* && "$C_APP" == *"DIVE-9121"* ]]' "$C_APP"
set_partner "$APP"
check "7e: partner manual CTA has no command" '[[ "$(TASK_CH_ACCESS="$CH/access.json" _gate_t manual_cta DIVE-9122)" != *sudo* ]]'
check "7f: a malformed partner link is not a partner link" \
  '[[ "$(set_partner "https://x.test/a\"b"; TASK_CH_ACCESS="$CH/access.json" _task_partner_app_url)" == "" ]]'
set_partner "$APP"   # 7f wrote a malformed one to disk
_task_agent_channel() { TASK_CH_TOKEN="t"; TASK_CH_ACCESS="$CH/access.json"; TASK_CH_TYPE="claude"; TASK_CH_AGENT="$1"; return 0; }
db "UPDATE tasks SET gate_pinged_at=NULL WHERE id=${id21};"
MINT="";  : >"$SENT"; _hb_gate_renag_batch_one marketing "$id21" "marketing" >/dev/null 2>&1; R_APP=$(cat "$SENT")
db "UPDATE tasks SET gate_pinged_at=datetime('now') WHERE id=${id21};"
MINT="https://secrets.example.test/tok456|30"; : >"$SENT"; _hb_gate_renag_batch_one marketing "$id21" "marketing" >/dev/null 2>&1; R_LNK=$(cat "$SENT")
check "7g: partner first contact via the reminder path: clean, and the app button rides it" \
  'clean "$R_APP" && [[ "$R_APP" == *"Нужен ключ HeyGen"* && "$R_APP" == *"$APP"* ]] && grep -qF "\"url\":\"$APP\"" <<<"$R_APP"' "$R_APP"
check "7h: partner reminder with a fresh link: clean, and the link is in it" \
  'clean "$R_LNK" && [[ "$R_LNK" == *"https://secrets.example.test/tok456"* ]]' "$R_LNK"
set_partner ""

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
