# ---------------------------------------------------------------------------
# Model catalogue — the ONE place a Claude model release is recorded (DIVE-1883).
#
# Why this file exists: the latest id per family was hardcoded at three call
# sites in this CLI and again in the telegram plugin's MODEL_ALIASES map. Every
# copy drifted (the plugin sat a whole version behind), so `/model opus` over
# Telegram handed you a different model than `5dive compose` pinned at birth.
# A model release should now touch ONE line in model_latest() below.
#
# Why the create path resolves aliases to FULL ids instead of writing the bare
# alias: Claude Code >= 2.1.181 ships a startup migration (migrationVersion 13,
# fires on ANY launch) that STRIPS a bare `model: "opus"` from a FRESH config
# dir, so a newly created agent silently loses its pin on first boot and falls
# back to the default. Full resolved ids are left untouched. See DIVE-506/536.
#
# Note the asymmetry, and preserve it: the nightly heal in 5dive-api
# scripts/update.sh writes the BARE alias to EXISTING agents on purpose. Their
# config dir is not fresh, so the migration does not strip it and they float
# forward to whatever the runtime calls "opus" today. Only the create path needs
# a resolved id. Do not "unify" the two.
# ---------------------------------------------------------------------------

# The families we map. Order is display order (`5dive models`).
model_families() { printf 'opus\nsonnet\nfable\nhaiku\n'; }

# model_latest <family> -> current full model id on stdout; non-zero if the
# argument is not a known family. THIS IS THE SOURCE OF TRUTH — a new Claude
# release edits the right-hand side here and nowhere else.
model_latest() {
  case "${1:-}" in
    opus)   printf '%s' "claude-opus-5-5" ;;
    sonnet) printf '%s' "claude-sonnet-5" ;;
    fable)  printf '%s' "claude-fable-5-1" ;;
    haiku)  printf '%s' "claude-haiku-4-5-20251001" ;;
    *)      return 1 ;;
  esac
}

# resolve_model_alias <alias-or-id> -> full resolved id on stdout.
# A known family alias resolves to its current id; anything else (a full id, a
# BYO/OpenRouter `vendor/model` string, or empty) passes through untouched.
resolve_model_alias() {
  local want="${1:-}" resolved
  resolved=$(model_latest "$want") && { printf '%s' "$resolved"; return 0; }
  printf '%s' "$want"
}

# models_json -> {"opus":"claude-opus-5-5",...}. This is what the telegram plugin
# reads at boot so its /model picker can't drift from the CLI again.
models_json() {
  local fam id first=1 out='{'
  while read -r fam; do
    id=$(model_latest "$fam") || continue
    [[ $first == 1 ]] || out+=','
    first=0
    out+="\"$fam\":\"$id\""
  done < <(model_families)
  printf '%s}\n' "$out"
}

cmd_models() {
  local as_json=0 a
  for a in "$@"; do
    case "$a" in
      --json) as_json=1 ;;
      -h|--help)
        cat <<'EOF'
Usage: 5dive models [--json]

Print the current Claude model id for each short alias. This is the single
source of truth the CLI's agent-create path and the telegram plugin's /model
picker both resolve against — a model release is a one-line change in
src/lib/models.sh.
EOF
        return 0 ;;
      *) fail "$E_USAGE" "unknown argument '$a' (try: 5dive models --json)" ;;
    esac
  done

  # Standard {ok,data} envelope, same shape every other `--json` surface emits,
  # so the telegram plugin's read5diveJson() helper can consume it unchanged.
  if (( as_json )) || (( ${JSON_MODE:-0} )); then
    jq -cn --argjson m "$(models_json)" '{ok:true, data:$m}'
    return 0
  fi

  local fam
  while read -r fam; do
    printf '%-8s %s\n' "$fam" "$(model_latest "$fam")"
  done < <(model_families)
}

# ---------------------------------------------------------------------------
# Per-model reasoning effort (DIVE-4863).
#
# Claude Code >= 2.1.280 applies a user-settings top-level `effortLevel` ONLY to
# a fixed set of models it calls legacy (claude-opus-5, claude-sonnet-5, ...).
# Any newer model (claude-opus-5-5 is the first) ignores it and runs at the
# model's default, medium. The key it honours is
# `modelSettings.<canonical model id>.effortLevel` — what `/effort` writes. So
# every writer sets BOTH keys, and every reader prefers the per-model one.
#
# The per-model schema accepts low|medium|high|xhigh only: "max" is
# session-only in Claude Code, and an unknown value is dropped silently (the
# model then reads its default). So `max` is written per-model as `xhigh`, the
# highest level that persists; the top-level key keeps "max" for the legacy
# models that still read it.
# ---------------------------------------------------------------------------

# model_canonical <model> -> the id Claude Code keys modelSettings by: a
# trailing "[1m]"-style suffix dropped and a family alias resolved. Anything
# else (a full id, a BYO `vendor/model` string, empty) passes through.
model_canonical() {
  local m="${1:-}"
  m="${m%%\[*}"
  resolve_model_alias "$m"
}

# model_effort_ids_json [model] -> JSON array of the ids that get a per-model
# effortLevel: every family's current id — so a later `/model` switch keeps the
# level — plus the seat's own canonical model when it is a claude-* id the
# table does not list (a seat pinned to an older model).
model_effort_ids_json() {
  local fam id own
  own=$(model_canonical "${1:-}")
  {
    while read -r fam; do
      id=$(model_latest "$fam") && printf '%s\n' "$id"
    done < <(model_families)
    [[ "$own" == claude-* ]] && printf '%s\n' "$own"
  } | jq -R . | jq -sc 'unique'
}

# jq definitions shared by every settings.json effort writer and reader.
#   apply_effort($e; $ids)  set the top-level key and the per-model key of every
#                           id in $ids (overwrites: an explicit set is the truth).
#   heal_effort($ids)       fill ONLY the per-model keys that are missing, from
#                           the top-level value — never overwrite one, since a
#                           per-model value is what `/effort` chose last.
#   effective_effort($a)    what Claude Code runs: the per-model key for the
#                           seat's model ($a = models_json), else top-level.
# shellcheck disable=SC2016
MODEL_EFFORT_JQ='
def _pm_effort: if . == "max" then "xhigh" else . end;
def _ms: if (.modelSettings | type) == "object" then .modelSettings else {} end;
def apply_effort($e; $ids):
  .effortLevel = $e
  | .modelSettings = (reduce $ids[] as $id (_ms;
      .[$id] = ((if (.[$id] | type) == "object" then .[$id] else {} end) + {effortLevel: ($e | _pm_effort)})));
def heal_effort($ids):
  if (.effortLevel | type) == "string"
     and (.effortLevel | IN("low", "medium", "high", "xhigh", "max"))
     and ((.modelSettings == null) or ((.modelSettings | type) == "object"))
  then .effortLevel as $e
    | .modelSettings = (reduce $ids[] as $id (_ms;
        if (.[$id] | type) == "object" and .[$id].effortLevel != null then .
        else .[$id] = ((if (.[$id] | type) == "object" then .[$id] else {} end) + {effortLevel: ($e | _pm_effort)})
        end))
  else . end;
def _canon_model($a):
  ((if (.model | type) == "string" then .model else "" end) | sub("\\[[^\\]]*\\]$"; "")) as $s
  | ($a[$s] // $s);
def effective_effort($a):
  _canon_model($a) as $k
  | ((_ms[$k] | if type == "object" then .effortLevel else null end) // .effortLevel // empty);
'
