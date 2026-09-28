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

# ---------------------------------------------------------------------------
# Alias-mapping accounts (DIVE-5163).
#
# A non-Anthropic claude account (the seeded OpenRouter one on a partner box, a
# client's own DeepSeek, any `--provider`/`--base-url` profile) carries an
# ANTHROPIC_BASE_URL plus ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL: its own
# answer to "sonnet". Claude Code applies that map to ALIASES only — a full
# claude-* id goes out as-is, and OpenRouter serves claude-sonnet-5 as real
# Claude Sonnet at API price. So resolve_model_alias above is wrong for these
# accounts: an OINOA pack's "sonnet" became a Claude Sonnet bill on a box whose
# account says sonnet = deepseek/deepseek-v4.1-flash.
#
# On such an account the family resolves to the account's MAPPED id instead. A
# full vendor id, never the bare alias: the create/import config dir is fresh,
# and migration 13 (header of this file) strips a bare alias there. An Anthropic
# account (no base url) keeps resolve_model_alias, i.e. today's DIVE-506 id.
#
# The family is also recorded as the registry's `.agents[<n>].modelFamily`, so
# `agent set-account` can re-derive the model for the new account: the mapped
# id alone cannot say which family it came from (all three OpenRouter tiers map
# to the same slug).
# ---------------------------------------------------------------------------

# profile_alias_model <profile> <family> -> the id the profile maps <family> to,
# or "" when the profile is an Anthropic account, has no map for that family
# (fable has no ANTHROPIC_DEFAULT_* variable), or maps it to a bare alias.
profile_alias_model() {
  local profile="${1:-}" fam="${2:-}" var mapped
  case "$fam" in
    opus|sonnet|haiku) var="ANTHROPIC_DEFAULT_${fam^^}_MODEL" ;;
    *) return 0 ;;
  esac
  [[ -n "$profile" && -n "$(profile_env_value "$profile" ANTHROPIC_BASE_URL)" ]] || return 0
  mapped=$(profile_env_value "$profile" "$var")
  # A map entry that is itself a family alias would be written bare into a fresh
  # config dir and stripped: not an answer, so fall back to the resolver.
  model_latest "$mapped" >/dev/null && return 0
  printf '%s' "$mapped"
}

# resolve_model_for_profile <alias-or-id> <profile> -> the id to write for an
# agent bound to <profile>: the account's mapped id for a family alias on an
# alias-mapping account, else exactly resolve_model_alias.
resolve_model_for_profile() {
  local want="${1:-}" profile="${2:-}" mapped
  if model_latest "$want" >/dev/null; then
    mapped=$(profile_alias_model "$profile" "$want")
    [[ -n "$mapped" ]] && { printf '%s' "$mapped"; return 0; }
  fi
  resolve_model_alias "$want"
}

# model_family_of <model> -> the family a model value stands for when that can
# be read off the value itself: a bare alias, or a family's CURRENT claude-* id.
# Empty for anything else (a vendor slug, an older pinned id).
model_family_of() {
  local m="${1:-}" fam fams
  [[ -n "$m" ]] || return 0
  fams=$(model_families)
  while read -r fam; do
    if [[ "$m" == "$fam" || "$m" == "$(model_latest "$fam")" ]]; then
      printf '%s' "$fam"; return 0
    fi
  done <<<"$fams"
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
