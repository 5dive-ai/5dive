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
    opus)   printf '%s' "claude-opus-5" ;;
    sonnet) printf '%s' "claude-sonnet-5" ;;
    fable)  printf '%s' "claude-fable-5" ;;
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

# models_json -> {"opus":"claude-opus-5",...}. This is what the telegram plugin
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
