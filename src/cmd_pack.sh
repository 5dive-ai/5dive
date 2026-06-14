
# -------- 5dive agent export / import — portable agent packs (DIVE-39) -----
#
# A pack is a versioned tarball capturing an agent's portable IDENTITY so it can
# be shared cross-user / published (unlike `agent clone`, which is a same-host
# full-fidelity copy — DIVE-331). Two flavours, user's choice at export:
#   - config pack (default)      : manifest + per-agent CLAUDE.md + skill refs +
#                                  a sanitized settings subset + optional template/
#   - with-memory pack (--with-memory): the above PLUS the agent's persona memory,
#                                  but ONLY through the opt-in + redaction + a
#                                  MANDATORY human review gate (never auto-publish).
#
# SECURITY: a pack NEVER carries secrets. Hard-excluded: channel tokens, API
# keys, SSH keys, .credentials.json, sessions/history/transcripts, caches. We
# build the manifest from a sanitized view of the registry + settings, and copy
# only an allowlist of files — never a blanket dir.
#
# Reuses the Claude Code plugin/skill spec for skills (we record source refs and
# re-add on import) rather than inventing a format.

PACK_FORMAT_VERSION=1

_pack_usage() {
  cat <<USAGE
5dive agent export / import — portable agent packs (DIVE-39)

  5dive agent export <name> [--with-memory] [--out=<path>]
                                  # write a shareable pack (.tar.gz). Default = config only.
  5dive agent import <pack> --as=<name> [--channels=none|telegram|discord]
                            [--telegram-token=<tok>] [--discord-token=<tok>]
                            [--auth-profile=<name>] [--workdir=<path>]
                                  # recreate an agent from a pack into a FRESH name.
                                  # Packs carry no secrets: supply the new agent's own
                                  # token/auth-profile here. Skills are re-added from their
                                  # recorded refs (skills not in a published repo are skipped
                                  # + reported). Memory is never in a config pack.

  A pack carries an agent's portable identity (instructions, skills, settings subset),
  NEVER secrets (tokens/keys/sessions/transcripts are hard-excluded). --with-memory adds
  redacted persona memory through a mandatory review gate. `agent clone` (same-host
  full-fidelity copy) is the local-duplicate path; a pack is for cross-user sharing.
USAGE
}

# Sanitized per-agent config from the registry — config only, never tokens.
_pack_agent_config() {
  local name="$1" reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n]' <<<"$reg" >/dev/null 2>&1 \
    || fail "$E_NOT_FOUND" "no agent '$name'"
  jq -c --arg n "$name" '.agents[$n] | {
    type, isolation,
    channels: (.channels // "none"),
    workdir,
    authProfile: (.authProfile // null)
  }' <<<"$reg"
}

cmd_export() {
  require_root
  local name="" with_memory=0 out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-memory) with_memory=1 ;;
      --out=*)       out="${1#--out=}" ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent export <name> [--with-memory] [--out=<path>]"
  require_agent "$name"
  local user="agent-${name}" cdir="/home/agent-${name}/.claude"

  # The with-memory path is the public-leak surface: it must run opt-in tagging
  # + LLM redaction + a mandatory human review-and-approve gate before any
  # persona memory enters a pack. That pipeline is the next slice; until it
  # lands we refuse rather than ship un-reviewed memory. (DIVE-39 v2)
  if (( with_memory )); then
    fail "$E_USAGE" "--with-memory needs the redaction + review gate (DIVE-39 v2, not built yet). Export the config pack now by dropping --with-memory."
  fi

  # Stage an allowlist of identity files — NEVER a blanket copy (that would risk
  # sweeping in tokens/sessions/transcripts).
  local stage; stage=$(mktemp -d)
  local cfg model effort plugins
  cfg=$(_pack_agent_config "$name")
  # model/effort/plugins come from the agent's settings.json (no secrets there).
  model=$(jq -r '.model // empty'        "$cdir/settings.json" 2>/dev/null || true)
  effort=$(jq -r '.effortLevel // empty' "$cdir/settings.json" 2>/dev/null || true)
  plugins=$(jq -c '.enabledPlugins // []' "$cdir/settings.json" 2>/dev/null || echo '[]')

  # Per-agent instructions (the identity doc) — copied verbatim if present.
  if [[ -f "$cdir/CLAUDE.md" ]]; then
    cp "$cdir/CLAUDE.md" "$stage/CLAUDE.md"
  fi
  # Skills as source refs (reuse the skills spec; import re-adds them) — names only.
  local skills='[]'
  if [[ -d "$cdir/skills" ]]; then
    # Skills install as real dirs OR symlinks (per-agent skill layout), so match
    # both — -type d alone misses the symlinked majority.
    skills=$(find "$cdir/skills" -maxdepth 1 -mindepth 1 \( -type d -o -type l \) -printf '%f\n' 2>/dev/null \
             | sort | jq -R . | jq -cs '.' 2>/dev/null || echo '[]')
  fi
  # Hooks subset from settings (structure only; if a hook command embeds a
  # secret that is on the operator — we copy the hooks block verbatim from
  # settings, which by convention holds no tokens).
  local hooks; hooks=$(jq -c '.hooks // {}' "$cdir/settings.json" 2>/dev/null || echo '{}')

  # Build the manifest.
  jq -n \
    --argjson fmt "$PACK_FORMAT_VERSION" \
    --arg name "$name" \
    --arg ver "$FIVE_VERSION" \
    --argjson cfg "$cfg" \
    --arg model "$model" --arg effort "$effort" \
    --argjson plugins "$plugins" --argjson skills "$skills" --argjson hooks "$hooks" \
    '{
      packFormat: $fmt,
      agentName: $name,
      createdWith: $ver,
      includes: { memory: false },
      config: ($cfg + {
        model: (if $model=="" then null else $model end),
        effort: (if $effort=="" then null else $effort end)
      }),
      plugins: $plugins,
      skills: $skills,
      hooks: $hooks
    }' > "$stage/manifest.json"

  # A pack NEVER contains a token/key/credential — assert before we tar so a
  # future change that widens the allowlist can't silently leak. (Belt + braces.)
  if grep -rilE 'BOT_TOKEN|API_KEY|-----BEGIN|credentials|sk-[A-Za-z0-9]|[0-9]{8,}:[A-Za-z0-9_-]{30,}' "$stage" 2>/dev/null | grep -q .; then
    rm -rf "$stage"
    fail "$E_GENERIC" "refusing to export: a staged file looks like it contains a secret (safety tripwire). Nothing written."
  fi

  [[ -n "$out" ]] || out="/tmp/${name}-pack-v${PACK_FORMAT_VERSION}.tar.gz"
  tar -czf "$out" -C "$stage" . 2>/dev/null || { rm -rf "$stage"; fail "$E_GENERIC" "failed to write pack tarball"; }
  chmod 644 "$out"
  rm -rf "$stage"

  ok "exported '$name' (config pack, no memory) -> $out" \
     '{name:$n, pack:$o, withMemory:false, skills:$s}' \
     --arg n "$name" --arg o "$out" --argjson s "$skills"
}

cmd_import() {
  require_root
  local pack="" as="" channels="" tg_token="" dc_token="" profile="" workdir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as=*)              as="${1#--as=}" ;;
      --channels=*)        channels="${1#--channels=}" ;;
      --telegram-token=*)  tg_token="${1#--telegram-token=}" ;;
      --discord-token=*)   dc_token="${1#--discord-token=}" ;;
      --auth-profile=*)    profile="${1#--auth-profile=}" ;;
      --workdir=*)         workdir="${1#--workdir=}" ;;
      -*)                  fail "$E_USAGE" "unknown flag: $1" ;;
      *)                   [[ -z "$pack" ]] && pack="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$pack" ]] || fail "$E_USAGE" "usage: 5dive agent import <pack> --as=<name> [--channels=...] [--telegram-token=...] [--discord-token=...] [--auth-profile=...] [--workdir=...]"
  [[ -n "$as" ]]   || fail "$E_USAGE" "--as=<name> is required (the new agent's name)"
  [[ -f "$pack" ]] || fail "$E_NOT_FOUND" "pack not found: $pack"

  # Reject an existing target up front — import recreates, it never overlays.
  local reg; reg=$(registry_read)
  jq -e --arg n "$as" '.agents[$n]' <<<"$reg" >/dev/null 2>&1 \
    && fail "$E_VALIDATION" "agent '$as' already exists — pick a fresh --as=<name> (import never overlays an existing agent)"

  # Unpack into an isolated stage and validate the manifest before touching anything.
  local stage; stage=$(mktemp -d)
  tar -xzf "$pack" -C "$stage" 2>/dev/null \
    || { rm -rf "$stage"; fail "$E_GENERIC" "could not read pack (expected a .tar.gz from 'agent export')"; }
  [[ -f "$stage/manifest.json" ]] \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "pack has no manifest.json — not a 5dive agent pack"; }

  local pf; pf=$(jq -r '.packFormat // empty' "$stage/manifest.json" 2>/dev/null)
  [[ "$pf" =~ ^[0-9]+$ ]] \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "pack manifest missing packFormat"; }
  (( pf <= PACK_FORMAT_VERSION )) \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "pack format v$pf is newer than this CLI supports (v$PACK_FORMAT_VERSION) — upgrade 5dive"; }

  # v1 imports config only. A with-memory pack must pass the export-side redaction
  # + review gate (not built yet), so one can never reach here; guard regardless.
  if [[ "$(jq -r '.includes.memory // false' "$stage/manifest.json")" == "true" ]]; then
    rm -rf "$stage"; fail "$E_USAGE" "this pack claims to carry memory; the with-memory import path isn't built yet (DIVE-39 v2)"
  fi

  # Derive create inputs from the manifest; explicit flags win.
  local type isolation m_workdir m_profile model effort
  type=$(jq -r '.config.type // empty'         "$stage/manifest.json")
  isolation=$(jq -r '.config.isolation // empty' "$stage/manifest.json")
  m_workdir=$(jq -r '.config.workdir // empty'    "$stage/manifest.json")
  m_profile=$(jq -r '.config.authProfile // empty' "$stage/manifest.json")
  model=$(jq -r '.config.model // empty'         "$stage/manifest.json")
  effort=$(jq -r '.config.effort // empty'       "$stage/manifest.json")
  [[ -n "$type" ]] || { rm -rf "$stage"; fail "$E_VALIDATION" "manifest has no agent type"; }
  [[ -n "$workdir" ]] || workdir="$m_workdir"
  [[ -n "$profile" ]] || profile="$m_profile"

  # Build the create argv. Skills are re-added afterwards (best-effort) so one
  # unresolvable ref can't abort the import. Channels default to none unless the
  # importer supplies a token (a pack never carries secrets).
  local -a cargs=("$as" "--type=$type" "--no-skills")
  [[ -n "$isolation" ]] && cargs+=("--isolation=$isolation")
  [[ -n "$workdir" ]]   && cargs+=("--workdir=$workdir")
  if [[ -n "$profile" ]]; then
    cargs+=("--auth-profile=$profile")
  else
    cargs+=("--defer-auth")   # no profile on this host → first-run UI signs in
  fi
  if [[ -n "$channels" ]]; then
    cargs+=("--channels=$channels")
  elif [[ -n "$tg_token" ]]; then
    cargs+=("--channels=telegram")
  elif [[ -n "$dc_token" ]]; then
    cargs+=("--channels=discord")
  else
    cargs+=("--channels=none")
  fi
  [[ -n "$tg_token" ]] && cargs+=("--telegram-token=$tg_token")
  [[ -n "$dc_token" ]] && cargs+=("--discord-token=$dc_token")

  # Recreate via the canonical create path (its ok-envelope suppressed so import
  # emits a single envelope). The registry lock is reentrant, so this is safe.
  step "Recreating agent '$as' from pack (type=$type)"
  ( cmd_create "${cargs[@]}" ) >/dev/null \
    || { rm -rf "$stage"; fail "$E_GENERIC" "create step failed while importing '$as'"; }

  local cdir="/home/agent-${as}/.claude"

  # Layer the identity doc.
  if [[ -f "$stage/CLAUDE.md" ]]; then
    install -o "agent-${as}" -g "agent-${as}" -m 644 "$stage/CLAUDE.md" "$cdir/CLAUDE.md" 2>/dev/null || true
  fi

  # Layer model/effort/hooks/plugins into settings.json (claude-only keys; others
  # ignore them). settings.json may not exist until first boot.
  if [[ "$type" == "claude" ]]; then
    local sfile="$cdir/settings.json" hooks plugins cur
    hooks=$(jq -c '.hooks // {}'     "$stage/manifest.json")
    plugins=$(jq -c '.plugins // []' "$stage/manifest.json")
    cur=$( [[ -f "$sfile" ]] && cat "$sfile" || echo '{}' )
    if jq -n --argjson cur "$cur" \
          --arg model "$model" --arg effort "$effort" \
          --argjson hooks "$hooks" --argjson plugins "$plugins" \
      '$cur
       + (if $model  != "" then {model:$model}        else {} end)
       + (if $effort != "" then {effortLevel:$effort} else {} end)
       + (if ($hooks   | length) > 0 then {hooks:$hooks}            else {} end)
       + (if ($plugins | length) > 0 then {enabledPlugins:$plugins} else {} end)' \
      > "$sfile.imp.$$" 2>/dev/null; then
      install -o "agent-${as}" -g "agent-${as}" -m 600 "$sfile.imp.$$" "$sfile" 2>/dev/null || true
    fi
    rm -f "$sfile.imp.$$"
  fi

  # Optional template/ bootstrap → a FRESH project dir only (never overlay).
  local templated="none"
  if [[ -d "$stage/template" && -n "$workdir" ]]; then
    if [[ ! -e "$workdir" ]]; then
      install -d -o "agent-${as}" -g "agent-${as}" "$workdir"
      cp -a "$stage/template/." "$workdir/" 2>/dev/null && chown -R "agent-${as}:agent-${as}" "$workdir"
      templated="$workdir"
    else
      templated="skipped (workdir exists — never overlay)"
    fi
  fi

  # Re-add skills best-effort. Config packs record refs, not bodies, so skills not
  # in a published repo can't be reinstalled cross-user — report what we skipped.
  local -a added=() skipped=()
  local sk pair src id
  while IFS= read -r sk; do
    [[ -z "$sk" ]] && continue
    pair=$(parse_skill_spec "$sk" 2>/dev/null) || { skipped+=("$sk"); continue; }
    src="${pair% *}"; id="${pair#* }"
    if ( cmd_skill_add "$as" --source="$src" --skill="$id" ) >/dev/null 2>&1; then
      added+=("$id")
    else
      skipped+=("$sk")
    fi
  done < <(jq -r '.skills[]? // empty' "$stage/manifest.json")

  rm -rf "$stage"

  local added_j skipped_j
  added_j=$(printf '%s\n'   "${added[@]+"${added[@]}"}"   | jq -R . | jq -cs 'map(select(. != ""))')
  skipped_j=$(printf '%s\n' "${skipped[@]+"${skipped[@]}"}" | jq -R . | jq -cs 'map(select(. != ""))')
  ok "imported '$as' from pack (config only, no memory). Skills added: ${#added[@]}, skipped: ${#skipped[@]}; template: $templated." \
     '{name:$n, type:$t, skillsAdded:$a, skillsSkipped:$s, template:$tpl}' \
     --arg n "$as" --arg t "$type" --argjson a "$added_j" --argjson s "$skipped_j" --arg tpl "$templated"
}
