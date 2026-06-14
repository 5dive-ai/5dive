
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
  5dive agent import <pack> --as=<name> [--channels=...] [--telegram-token=...]
                                  # recreate an agent from a pack (coming in the import slice)

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
  # The import slice (recreate from manifest + re-add skills + template into a
  # fresh project dir) is the next build; refuse clearly until then rather than
  # half-create an agent.
  fail "$E_USAGE" "agent import is not built yet (DIVE-39 import slice next). Export side is live: 5dive agent export <name>."
}
