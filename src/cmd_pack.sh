
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

# -------- character-pack git registry (DIVE-473/509) -----------------------
# The marketplace is a curated GitHub repo (<org>/character-packs) that the CLI
# reads directly — no api.5dive.com dependency, same pattern as <org>/skills.
# A bare slug to `agent import` resolves here; `agent marketplace ls` browses it.

_marketplace_base() { echo "https://raw.githubusercontent.com/$(gh_org)/character-packs/main"; }

# DIVE-644: opt-in import telemetry (the ONLY api.5dive.com touchpoint on the
# pack path, and only when the user passes `agent import <slug> --report-import`;
# default OFF, so the marketplace stays a zero-backend git registry by default).
# We POST just the slug to an increment-only, ZERO-PII counter so the OpenAgent
# gallery can rank "Most-imported". Best-effort: short timeout, all errors
# swallowed — a down/blocked endpoint must never affect the import outcome.
_oa_api_base() { echo "${FIVE_API_BASE:-https://api.5dive.com}"; }
_report_import() {
  local slug="$1"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || return 1
  curl -fsS --max-time 5 -X POST "$(_oa_api_base)/openagent/imports" \
    -H "Content-Type: application/json" \
    -d "{\"slug\":\"$slug\"}" >/dev/null 2>&1
}

_marketplace_index() { curl -fsSL --max-time 20 "$(_marketplace_base)/index.json" 2>/dev/null; }

# Resolve registry pack <slug> → a local .tar.gz (same shape `agent export` writes,
# so cmd_import's existing flow is unchanged). Echoes the path; returns 1 if absent.
_marketplace_fetch_pack() {
  local slug="$1" base idx entry path
  base=$(_marketplace_base)
  idx=$(_marketplace_index) || return 1
  entry=$(jq -e --arg s "$slug" '.packs[] | select(.slug==$s)' <<<"$idx" 2>/dev/null) || return 1
  path=$(jq -r '.path // empty' <<<"$entry"); [[ -n "$path" ]] || return 1
  local dl; dl=$(mktemp -d)
  curl -fsSL --max-time 20 "$base/$path/manifest.json" -o "$dl/manifest.json" 2>/dev/null \
    || { rm -rf "$dl"; return 1; }
  local f
  for f in CLAUDE.md card.md avatar.png; do
    curl -fsSL --max-time 20 "$base/$path/$f" -o "$dl/$f" 2>/dev/null || true
  done
  # Bundled skill bodies (manifest.skills[] names → skills/<id>/SKILL.md), so a
  # pack imports self-contained even if a skill isn't in a published repo.
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    id="${id##*#}"; id="${id##*/}"
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    if curl -fsSL --max-time 20 "$base/$path/skills/$id/SKILL.md" -o "$dl/.probe" 2>/dev/null; then
      mkdir -p "$dl/skills/$id"; mv "$dl/.probe" "$dl/skills/$id/SKILL.md"
    fi
  done < <(jq -r '.skills[]? // empty' "$dl/manifest.json" 2>/dev/null)
  rm -f "$dl/.probe"
  # DIVE-472 distilled memory: curl can't list a dir, so the manifest names its
  # memory files (memoryFiles[]). Fetch them + the MEMORY.md index when the pack
  # declares distilled memory, so cmd_import seeds them into the new agent.
  if [[ "$(jq -r '.includes.memory // "false"' "$dl/manifest.json" 2>/dev/null)" == "distilled" ]]; then
    mkdir -p "$dl/memory"
    curl -fsSL --max-time 20 "$base/$path/memory/MEMORY.md" -o "$dl/memory/MEMORY.md" 2>/dev/null || true
    local mf
    while IFS= read -r mf; do
      mf="${mf##*/}"   # basename only — no path traversal
      [[ "$mf" =~ ^[A-Za-z0-9._-]+\.md$ ]] || continue
      curl -fsSL --max-time 20 "$base/$path/memory/$mf" -o "$dl/memory/$mf" 2>/dev/null || true
    done < <(jq -r '.memoryFiles[]? // empty' "$dl/manifest.json" 2>/dev/null)
  fi
  local out; out=$(mktemp --suffix=.tar.gz)
  tar -czf "$out" -C "$dl" . 2>/dev/null || { rm -rf "$dl" "$out"; return 1; }
  rm -rf "$dl"; echo "$out"
}

# Install a bundled skill (a local <dir>/SKILL.md) directly into the agent's
# skills dir — used on import when the pack carries the skill body.
_install_bundled_skill() {
  local name="$1" id="$2" srcdir="$3"
  [[ -f "$srcdir/SKILL.md" ]] || return 1
  local user="agent-${name}" home="/home/agent-${name}" type install_dir
  type=$(agent_type "$name"); [[ -n "$type" ]] || return 1
  install_dir="${SKILLS_INSTALL_DIR[$type]:-.claude/skills}"
  local dest="$home/$install_dir/$id"
  rm -rf "$dest"; mkdir -p "$home/$install_dir" || return 1
  cp -r "$srcdir" "$dest" || return 1
  chown -R "${user}:${user}" "$dest" 2>/dev/null || true
  return 0
}

# When the importer renames a pack (--as differs from the pack's own name), the
# persona files still call the agent by the pack's name (e.g. import dario
# --as=cris leaves "You are Dario" in CLAUDE.md). Rewrite the persona name across
# the identity + memory docs so the imported agent owns its chosen name. Both the
# Capitalized display form (Dario) and the lowercase slug form (dario) are
# replaced; word-boundary anchored so we don't mangle substrings.
_pack_rename_persona() {
  local dir="$1" old="$2" new="$3"
  local old_l="${old,,}" new_l="${new,,}"
  local old_c="${old_l^}" new_c="${new_l^}"
  [[ -n "$old_l" && "$old_l" != "$new_l" ]] || return 0
  local f
  for f in "$dir/CLAUDE.md" "$dir/card.md" "$dir/persona.yaml" "$dir"/memory/*.md; do
    [[ -f "$f" ]] || continue
    sed -i -E "s/\\b${old_c}\\b/${new_c}/g; s/\\b${old_l}\\b/${new_l}/g" "$f" 2>/dev/null || true
  done
}

# -------- OpenAgent persona → live agent (DIVE-658 #2) ---------------------
# Bridge the OpenAgent identity spec (github.com/5dive-ai/openagent) to actual
# provisioning: a `<id>.persona.yaml` carries IDENTITY (name, role, look, voice,
# behavior) but no 5dive RUNTIME config (type, model, isolation, channels), so
# this synthesizes a v1 character pack from the persona — manifest + a CLAUDE.md
# identity doc + the portrait as avatar.png — and hands it to the normal
# cmd_import flow. Runtime config comes from flags (sane defaults), identity
# from the persona. Self-author (the openagent skill) → self-PROVISION (here).

# Build a pack tarball from an OpenAgent persona file. Echoes the .tar.gz path.
# Args: <persona-file> <type> <isolation> <model> <effort>. Parsing/synthesis is
# done in python (pyyaml) since the persona is YAML; we keep the schema's
# required-field contract as a structural gate (full validation lives in the
# openagent CLI / skill — run it before provisioning).
# Render an OpenAgent persona file into a CLAUDE.md identity doc. SINGLE source of
# truth for persona -> identity rendering (DIVE-656), shared by `agent import
# --from-persona`, the synth path above, and `agent import <pack>` when the pack
# carries a persona.yaml. Args: <persona-file> <out-claude-md>. Non-zero on an
# invalid/unreadable persona so callers can fall back.
_persona_render_claudemd() {
  local persona="$1" out="$2"
  PERSONA_FILE="$persona" OUT_FILE="$out" python3 - <<'PY'
import os, sys
try:
    import yaml
except Exception as e:
    sys.stderr.write("pyyaml required: %s\n" % e); sys.exit(3)
with open(os.environ["PERSONA_FILE"]) as f:
    try:
        p = yaml.safe_load(f)
    except Exception as e:
        sys.stderr.write("persona is not valid YAML: %s\n" % e); sys.exit(2)
if not isinstance(p, dict):
    sys.stderr.write("persona must be a YAML mapping\n"); sys.exit(2)
name = p.get("name"); role = p.get("role"); behavior = p.get("behavior")
if not (name and role and behavior):
    sys.stderr.write("persona missing required name/role/behavior\n"); sys.exit(2)
face = p.get("face") or {}
voice = p.get("voice") or {}
written = voice.get("written") if isinstance(voice, dict) else None
audio = voice.get("audio") if isinstance(voice, dict) else None
written = written or {}; audio = audio or {}
lines = ["# %s" % name, "", "You are **%s**, %s." % (name, role), "", str(behavior).strip(), ""]
rules = (written.get("rules") if isinstance(written, dict) else None) or []
if rules:
    lines += ["## How you write"] + ["- %s" % r for r in rules] + [""]
sample = written.get("sample") if isinstance(written, dict) else None
if sample:
    lines += ['Sample line in your voice: "%s"' % sample, ""]
base = audio.get("base") if isinstance(audio, dict) else None
if base and base != "unset":
    style = audio.get("style")
    lines += ["## Voice (audio)", "Base: %s%s" % (base, (" — %s" % style) if style else ""), ""]
anchor = face.get("anchor") if isinstance(face, dict) else None
if anchor:
    lines += ["## Look", anchor, "Portrait: %s" % face.get("ref"), ""]
posts = p.get("posts_about") or []
if posts:
    lines += ["## You speak to", ", ".join(str(x) for x in posts), ""]
links = p.get("links") or {}
if isinstance(links, dict) and links:
    lines += ["## Links"] + ["- %s: %s" % (k, v) for k, v in links.items()] + [""]
lines += ["---",
          "Provisioned from an OpenAgent persona (id: `%s`, spec %s). "
          "Identity standard: github.com/5dive-ai/openagent" % (p.get("id", ""), p.get("openagent", "0.1"))]
with open(os.environ["OUT_FILE"], "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

# Emit a conforming OpenAgent persona.yaml from a live agent's staged identity
# (DIVE-656). Makes every `agent export` pack spec-valid by construction and
# feeds the gallery for free. Field values are best-effort extracted from the
# staged CLAUDE.md, falling back to a minimal-but-valid (Common-tier) persona.
# Args: <agent-name> <stage-dir> <has-avatar:0|1>. Non-zero only on a hard error.
_agent_to_persona() {
  local name="$1" stage="$2" has_avatar="$3"
  A_NAME="$name" A_STAGE="$stage" A_AVATAR="$has_avatar" python3 - <<'PY'
import os, re, sys
try:
    import yaml
except Exception as e:
    sys.stderr.write("pyyaml required: %s\n" % e); sys.exit(3)
name = os.environ["A_NAME"]
stage = os.environ["A_STAGE"]
has_avatar = os.environ.get("A_AVATAR") == "1"
md = ""
cpath = os.path.join(stage, "CLAUDE.md")
if os.path.exists(cpath):
    with open(cpath) as f:
        md = f.read()

# id: agent slug — already kebab on 5dive; sanitize defensively to ^[a-z0-9-]+$.
pid = re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-") or "agent"

# Display name + role: prefer a "You are **X**, <role>." line in the identity doc.
disp = (name[:1].upper() + name[1:]) if name else "Agent"
role = "5dive agent"
m = re.search(r"You are \*\*([^*]+)\*\*,\s*([^.\n]+)", md)
if m:
    disp = m.group(1).strip(); role = m.group(2).strip()
else:
    m2 = re.search(r"You are \*\*([^*]+)\*\*", md)
    if m2:
        disp = m2.group(1).strip()

# behavior: the CLAUDE.md body is the agent's operating instructions. Drop the
# leading "# Title" line; cap length so a persona stays a card, not a doc dump.
behavior = ""
if md:
    behavior = re.sub(r"^#[^\n]*\n", "", md.strip(), count=1).strip()
if not behavior:
    behavior = "%s is a 5dive agent. See the team conventions for how it operates." % disp
if len(behavior) > 1200:
    behavior = behavior[:1200].rstrip() + " …"

persona = {
    "openagent": "0.1",
    "id": pid,
    "name": disp,
    "role": role,
    "behavior": behavior,
    "face": {
        "ref": "avatar.png" if has_avatar else ("monogram:%s" % disp[:1].upper()),
        "anchor": "%s, a 5dive agent." % disp,
    },
    "voice": {
        "written": {
            "rules": ["Write in %s's consistent voice." % disp,
                      "Stay in role as %s." % role],
            "sample": "I'm %s — %s." % (disp, role),
        }
    },
}
with open(os.path.join(stage, "persona.yaml"), "w") as f:
    yaml.safe_dump(persona, f, sort_keys=False, allow_unicode=True, default_flow_style=False)
PY
}

_persona_to_pack() {
  local persona="$1" type="$2" isolation="$3" model="$4" effort="$5"
  [[ -f "$persona" ]] || { echo "persona file not found: $persona" >&2; return 1; }
  local stage; stage=$(mktemp -d)
  # Default skills every provisioned agent should carry — keep aligned with the
  # create-path defaults plus openagent so the new agent can iterate its own card.
  if ! PERSONA_FILE="$persona" P_TYPE="$type" P_ISO="$isolation" \
       P_MODEL="$model" P_EFFORT="$effort" P_VERSION="$FIVE_VERSION" P_STAGE="$stage" \
       python3 - <<'PY'
import os, sys, json, re
try:
    import yaml
except Exception as e:
    sys.stderr.write("python3 yaml (pyyaml) is required to import a persona: %s\n" % e); sys.exit(3)

stage = os.environ["P_STAGE"]
with open(os.environ["PERSONA_FILE"]) as f:
    try:
        p = yaml.safe_load(f)
    except Exception as e:
        sys.stderr.write("persona is not valid YAML: %s\n" % e); sys.exit(2)
if not isinstance(p, dict):
    sys.stderr.write("persona must be a YAML mapping\n"); sys.exit(2)

# Structural gate mirroring schema/persona.schema.json's required set.
def need(cond, msg):
    if not cond:
        sys.stderr.write("invalid persona: %s\n" % msg); sys.exit(2)

pid = p.get("id", "")
need(isinstance(pid, str) and re.match(r"^[a-z0-9-]+$", pid or ""), "id missing or not ^[a-z0-9-]+$")
name = p.get("name"); role = p.get("role"); behavior = p.get("behavior")
need(name and role and behavior, "name, role, behavior are all required")
face = p.get("face") or {}
need(isinstance(face, dict) and face.get("ref") and face.get("anchor"), "face.ref and face.anchor are required")
voice = p.get("voice") or {}
audio = voice.get("audio") or {}
written = voice.get("written") or {}
need(isinstance(voice, dict) and (audio or written), "voice needs audio and/or written")

# CLAUDE.md identity doc is rendered by _persona_render_claudemd (shared with the
# packed-persona import path, DIVE-656) after this python block returns.

# --- manifest.json: shape cmd_import consumes (packFormat 1) ---
cfg = {"type": os.environ["P_TYPE"], "isolation": os.environ["P_ISO"]}
if os.environ.get("P_MODEL"):  cfg["model"]  = os.environ["P_MODEL"]
if os.environ.get("P_EFFORT"): cfg["effort"] = os.environ["P_EFFORT"]
manifest = {
    "packFormat": 1,
    "agentName": name,
    "createdWith": os.environ["P_VERSION"],
    "source": "openagent-persona",
    "openagent": {"id": pid, "spec": str(p.get("openagent", "0.1"))},
    "includes": {"memory": False},
    "config": cfg,
    "plugins": [],
    # Resolved from <org>/skills by cmd_import; openagent lets the new agent
    # re-author/iterate its own persona card.
    "skills": ["find-skills", "5dive-cli", "compile-knowledge", "openagent"],
    "hooks": {},
    "avatar": None,
}
with open(os.path.join(stage, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
# Sidecar for the bash side: the portrait ref, to fetch if it's a URL.
with open(os.path.join(stage, ".faceref"), "w") as f:
    f.write(face.get("ref", "") or "")
PY
  then
    rm -rf "$stage"; echo "could not synthesize pack from persona" >&2; return 1
  fi

  # Render the identity doc from the persona (shared renderer, DIVE-656) and carry
  # the persona itself into the pack so it round-trips and stays spec-valid by
  # construction — cmd_import re-derives identity from it.
  if ! _persona_render_claudemd "$persona" "$stage/CLAUDE.md"; then
    rm -rf "$stage"; echo "could not render identity doc from persona" >&2; return 1
  fi
  cp "$persona" "$stage/persona.yaml" 2>/dev/null || true

  # Fetch the portrait into avatar.png when face.ref is a public URL (local-only
  # paths can't travel cross-user, so we skip them — the card falls back to a
  # monogram, same contract as the openagent skill). The sidecar is consumed
  # here and removed so it never lands in the pack.
  local ref; ref=$(cat "$stage/.faceref" 2>/dev/null); rm -f "$stage/.faceref"
  if [[ "$ref" =~ ^https?:// ]]; then
    if curl -fsSL --max-time 20 "$ref" -o "$stage/avatar.png" 2>/dev/null; then
      jq '.avatar="avatar.png"' "$stage/manifest.json" > "$stage/m.$$" \
        && mv "$stage/m.$$" "$stage/manifest.json" || rm -f "$stage/m.$$"
    else
      rm -f "$stage/avatar.png"
    fi
  fi

  local out; out=$(mktemp --suffix=.tar.gz)
  tar -czf "$out" -C "$stage" . 2>/dev/null || { rm -rf "$stage" "$out"; return 1; }
  rm -rf "$stage"; echo "$out"
}

# Extract a bundled ed25519 signing key from a persona's sanctioned ext namespace
# (ext.5dive.signing_key — vendor-namespaced; a bare ext.deploy.signing_key is
# also accepted) into <keyfile>, and STRIP it from the persona IN PLACE so the
# private key never lands in the pack, the rendered CLAUDE.md, or a re-rendered
# card. Now-empty ext namespaces are pruned. Nothing is written to stdout, so the
# key is never logged. Rarity is untouched: it derives from the PUBLIC key under
# provenance.created_by.key (left intact), so a persona that carries only the
# public key still keeps its rarity, sign-less. Returns 0 if a key was extracted
# to <keyfile>; 9 if the persona carried none (file left byte-for-byte untouched).
# (DIVE-840 — the deploy-with-key import path; keystore adoption = no re-mint.)
_persona_strip_signing_key() {
  local persona="$1" keyfile="$2"
  PERSONA_FILE="$persona" KEY_OUT="$keyfile" python3 - <<'PY'
import os, sys
try:
    import yaml
except Exception as e:
    sys.stderr.write("pyyaml required to adopt a signing key: %s\n" % e); sys.exit(3)
with open(os.environ["PERSONA_FILE"]) as f:
    p = yaml.safe_load(f)
if not isinstance(p, dict):
    sys.exit(9)
ext = p.get("ext")
key = None
if isinstance(ext, dict):
    for ns in ("5dive", "deploy"):
        blk = ext.get(ns)
        if isinstance(blk, dict) and isinstance(blk.get("signing_key"), str) and blk["signing_key"].strip():
            key = blk["signing_key"].strip()
            blk.pop("signing_key", None)
            if not blk:            # prune a namespace we just emptied
                ext.pop(ns, None)
            break
    if not ext:                    # prune ext if that was its only content
        p.pop("ext", None)
if key is None:
    sys.exit(9)
# 0600 is pre-set on KEY_OUT by the caller; write with a trailing newline.
with open(os.environ["KEY_OUT"], "w") as f:
    f.write(key if key.endswith("\n") else key + "\n")
# Rewrite the sanitized persona only on the extract path (safe_dump preserves the
# authored key order via sort_keys=False); a keyless persona is never rewritten.
with open(os.environ["PERSONA_FILE"], "w") as f:
    yaml.safe_dump(p, f, sort_keys=False, allow_unicode=True)
sys.exit(0)
PY
}

# `5dive agent marketplace [ls]` — browse the character-pack registry.
cmd_marketplace() {
  local sub="${1:-ls}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    ls|list|browse)
      local idx; idx=$(_marketplace_index) \
        || fail "$E_GENERIC" "could not reach the character-pack registry ($(_marketplace_base))"
      jq -e '.packs' >/dev/null 2>&1 <<<"$idx" \
        || fail "$E_GENERIC" "registry index is malformed"
      if (( JSON_MODE )); then
        ok "" '{registry:($org+"/character-packs"), packs:($idx.packs)}' \
           --arg org "$(gh_org)" --argjson idx "$idx"
      else
        echo "Character packs — import any with: 5dive agent import <slug> --as=<name>"
        echo
        jq -r '.packs[] | "  \(.slug)\t\(.name) — \(.tagline)"' <<<"$idx" | column -t -s $'\t'
      fi
      ;;
    *) fail "$E_USAGE" "usage: 5dive agent marketplace [ls]" ;;
  esac
}

_pack_usage() {
  cat <<USAGE
5dive agent export / import — portable agent packs (DIVE-39)

  5dive agent export <name> [--with-memory] [--approve-memory=<dir>] [--out=<path>]
                                  # write a shareable pack (.tar.gz). Default = config only.
                                  # --with-memory is a TWO-PHASE deny-by-default flow:
                                  #   1) export <name> --with-memory  -> writes a scoped persona
                                  #      DRAFT (only reference/project knowledge facts; private
                                  #      user/feedback facts excluded) for you to review + edit.
                                  #   2) export <name> --approve-memory=<draft dir>  -> seals the
                                  #      reviewed memory into the pack. Nothing is packed unreviewed.
  5dive agent marketplace [ls]    # browse the character-pack registry (<org>/character-packs)
  5dive agent import <pack|slug> --as=<name> [--channels=none|telegram|discord|dashboard[,ch...]]
                            [--telegram-token=<tok>] [--discord-token=<tok>]
                            [--auth-profile=<name>] [--workdir=<path>] [--report-import]
                                  # recreate an agent from a pack into a FRESH name.
                                  # <pack> = a .tar.gz file OR a bare registry slug
                                  # (e.g. `import lilbro --as=...`) pulled from the git registry.
                                  # --report-import (opt-in, default OFF): ping a public
                                  # increment-only, zero-PII counter with just the pack slug
                                  # so the gallery can rank Most-imported. Registry slugs only.
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

# Secret tripwire — refuse if any staged file looks like it holds a token/key.
# Returns 0 (clean) or 1 (hit); on hit, prints the offending paths to stderr.
# Belt + braces: the real safety is the allowlist + type-scoping, this catches
# a regression that widens either.
_pack_secret_tripwire() {
  local dir="$1" hits
  hits=$(grep -rilE 'BOT_TOKEN|API_KEY|-----BEGIN|credentials|sk-[A-Za-z0-9]|[0-9]{8,}:[A-Za-z0-9_-]{30,}' "$dir" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

# Locate an agent's persona-memory dir. Memory is keyed by project slug
# (~/.claude/projects/<slug>/memory/); a customer agent normally has one. If
# several exist we take the largest (the agent's primary working project).
_pack_memory_dir() {
  local name="$1" base="/home/agent-${name}/.claude/projects"
  [[ -d "$base" ]] || return 1
  find "$base" -maxdepth 2 -type d -name memory 2>/dev/null \
    | while read -r d; do printf '%s\t%s\n' "$(find "$d" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)" "$d"; done \
    | sort -rn | head -1 | cut -f2-
}

# DENY-BY-DEFAULT memory scoping (L1). Copies into <outdir> ONLY facts that are
# safe-by-construction to share: frontmatter metadata.type in {reference,project}
# (a character's KNOWLEDGE), never {user,feedback} (who the human is / how to work
# with them — private by definition). Honors an explicit opt-out
# (export:false / private:true / share:false) on any fact. Regenerates a clean
# MEMORY.md index from what survived; the source MEMORY.md is never copied (it
# indexes private facts too). Echoes "<kept> <excluded>" counts.
_pack_scope_memory() {
  local memdir="$1" outdir="$2" kept=0 excluded=0 f base type optout
  mkdir -p "$outdir"
  while IFS= read -r f; do
    base=$(basename "$f")
    [[ "$base" == "MEMORY.md" ]] && continue
    # Frontmatter type lives nested under metadata: (….type: <t>). Read the first
    # `type:` inside the leading frontmatter block.
    type=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^[[:space:]]*type:[[:space:]]*/{sub(/^[[:space:]]*type:[[:space:]]*/,""); gsub(/[[:space:]]+$/,""); print; exit}' "$f")
    optout=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^[[:space:]]*(export|share):[[:space:]]*false/{print "1"; exit} n==1 && /^[[:space:]]*private:[[:space:]]*true/{print "1"; exit}' "$f")
    if [[ "$type" == "reference" || "$type" == "project" ]] && [[ -z "$optout" ]]; then
      cp "$f" "$outdir/$base"; kept=$((kept+1))
    else
      excluded=$((excluded+1))
    fi
  done < <(find "$memdir" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
  # Clean index over only what we kept.
  {
    echo "# Memory Index (distilled persona pack)"
    echo
    for f in "$outdir"/*.md; do
      [[ -e "$f" ]] || continue
      [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
      local nm desc
      nm=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^name:[[:space:]]*/{sub(/^name:[[:space:]]*/,""); print; exit}' "$f")
      desc=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^description:[[:space:]]*/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$f")
      [[ -n "$nm" ]] && echo "- [$nm]($(basename "$f")) — ${desc}"
    done
  } > "$outdir/MEMORY.md"
  printf '%s %s\n' "$kept" "$excluded"
}

cmd_export() {
  require_root
  local name="" with_memory=0 out="" approve_memory=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-memory)      with_memory=1 ;;
      --approve-memory=*) approve_memory="${1#--approve-memory=}"; with_memory=1 ;;
      --out=*)            out="${1#--out=}" ;;
      -*)                 fail "$E_USAGE" "unknown flag: $1" ;;
      *)                  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent export <name> [--with-memory] [--approve-memory=<dir>] [--out=<path>]"
  require_agent "$name"
  local user="agent-${name}" cdir="/home/agent-${name}/.claude"

  # The with-memory path is the public-leak surface. Architecture = DISTILL-TO-
  # PERSONA, deny-by-default (DIVE-472): a pack never carries raw memory. The
  # privacy guarantee is DETERMINISTIC — only {reference,project} KNOWLEDGE facts
  # are eligible, private {user,feedback} facts are excluded at source — plus a
  # MANDATORY two-phase human approve-gate. It is NOT entrusted to an LLM's
  # redaction judgement. Phase 1 (no --approve-memory) writes a scoped draft and
  # stops; phase 2 (--approve-memory=<reviewed dir>) seals the reviewed dir in.
  local mem_src="" mem_tmp=""   # SEAL phase: scoped temp dir of approved memory to pack
  if (( with_memory )); then
    if [[ -z "$approve_memory" ]]; then
      # --- DRAFT phase: scope (L1) + tripwire (L3), write a review draft, STOP.
      local memdir; memdir=$(_pack_memory_dir "$name")
      [[ -n "$memdir" ]] || fail "$E_NOT_FOUND" "agent '$name' has no persona memory to export"
      local draft="/home/agent-${name}/.claude/pack-staging/memory-draft"
      rm -rf "$draft"; mkdir -p "$draft"
      local counts kept excluded
      counts=$(_pack_scope_memory "$memdir" "$draft")
      kept="${counts%% *}"; excluded="${counts##* }"
      if (( kept == 0 )); then
        rm -rf "$draft"
        fail "$E_GENERIC" "nothing shareable: 0 reference/project knowledge facts ($excluded private user/feedback or opted-out facts excluded). Nothing written."
      fi
      if ! _pack_secret_tripwire "$draft"; then
        rm -rf "$draft"
        fail "$E_GENERIC" "a scoped fact tripped the secret tripwire (paths above) — refusing. Tag it 'private: true' or remove the secret, then retry."
      fi
      chown -R "agent-${name}:agent-${name}" "/home/agent-${name}/.claude/pack-staging" 2>/dev/null || true
      ok "memory DRAFT ready for review — kept $kept knowledge fact(s), excluded $excluded private/opted-out (deny-by-default). REVIEW + EDIT: $draft — then SEAL: 5dive agent export $name --approve-memory=$draft. Nothing is packed until you approve." \
         '{name:$n, phase:"draft", draft:$d, kept:$k, excluded:$e}' \
         --arg n "$name" --arg d "$draft" --argjson k "$kept" --argjson e "$excluded"
      return 0
    else
      # --- SEAL phase: the human reviewed/edited this dir; re-validate + pack it.
      # CRITICAL: re-apply deny-by-default scoping here too, so the type-gate holds
      # no matter what dir is passed — even the agent's RAW memory dir, or a draft
      # the human re-added a private fact to. Human review edits CONTENT; the tool
      # always re-enforces the {reference,project}-only filter + secret tripwire.
      [[ -d "$approve_memory" ]] || fail "$E_NOT_FOUND" "--approve-memory dir not found: $approve_memory"
      find "$approve_memory" -maxdepth 1 -name '*.md' 2>/dev/null | grep -q . \
        || fail "$E_VALIDATION" "--approve-memory has no .md facts: $approve_memory"
      mem_tmp=$(mktemp -d)
      local scounts skept sexcl
      scounts=$(_pack_scope_memory "$approve_memory" "$mem_tmp")
      skept="${scounts%% *}"; sexcl="${scounts##* }"
      (( skept > 0 )) || { rm -rf "$mem_tmp"; fail "$E_GENERIC" "approved dir has 0 shareable knowledge facts after scoping ($sexcl excluded). Nothing sealed."; }
      if ! _pack_secret_tripwire "$mem_tmp"; then
        rm -rf "$mem_tmp"
        fail "$E_GENERIC" "approved memory tripped the secret tripwire (paths above) — refusing to seal. Remove/tag the secret and retry."
      fi
      (( sexcl > 0 )) && warn "seal dropped $sexcl non-shareable fact(s) from the approved dir (type-gate re-enforced)"
      mem_src="$mem_tmp"
    fi
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
  # Avatar (set on import/onboarding, DIVE-494) — carry it so the persona's
  # face.ref="avatar.png" round-trips and the gallery has a portrait.
  local has_avatar=0
  if [[ -f "$cdir/avatar.png" ]]; then
    cp "$cdir/avatar.png" "$stage/avatar.png" 2>/dev/null && has_avatar=1
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

  # Stage approved persona memory (SEAL phase only). Deny-by-default already
  # filtered it; copy the human-approved facts under memory/.
  local mem_inc="false"
  if [[ -n "$mem_src" ]]; then
    mkdir -p "$stage/memory"
    cp "$mem_src"/*.md "$stage/memory/" 2>/dev/null || true
    mem_inc="distilled"
  fi

  # Emit a conforming OpenAgent persona.yaml (DIVE-656) so the pack is spec-valid
  # by construction and feeds the gallery. Derived from the staged identity doc;
  # never fatal — a pack without a persona is still importable.
  local has_persona="false"
  if _agent_to_persona "$name" "$stage" "$has_avatar" 2>/dev/null && [[ -f "$stage/persona.yaml" ]]; then
    has_persona="true"
  fi

  # Build the manifest.
  jq -n \
    --argjson fmt "$PACK_FORMAT_VERSION" \
    --arg name "$name" \
    --arg ver "$FIVE_VERSION" \
    --argjson cfg "$cfg" \
    --arg model "$model" --arg effort "$effort" \
    --argjson plugins "$plugins" --argjson skills "$skills" --argjson hooks "$hooks" \
    --arg mem "$mem_inc" \
    --argjson persona "$has_persona" \
    '{
      packFormat: $fmt,
      agentName: $name,
      createdWith: $ver,
      includes: { memory: (if $mem=="false" then false else $mem end), persona: $persona },
      config: ($cfg + {
        model: (if $model=="" then null else $model end),
        effort: (if $effort=="" then null else $effort end)
      }),
      plugins: $plugins,
      skills: $skills,
      hooks: $hooks
    }' > "$stage/manifest.json"

  # A pack NEVER contains a token/key/credential — assert over the WHOLE stage
  # (incl. any memory/) before we tar so a future change can't silently leak.
  if ! _pack_secret_tripwire "$stage"; then
    rm -rf "$stage" "$mem_tmp"
    fail "$E_GENERIC" "refusing to export: a staged file looks like it contains a secret (safety tripwire). Nothing written."
  fi

  [[ -n "$out" ]] || out="/tmp/${name}-pack-v${PACK_FORMAT_VERSION}.tar.gz"
  tar -czf "$out" -C "$stage" . 2>/dev/null || { rm -rf "$stage" "$mem_tmp"; fail "$E_GENERIC" "failed to write pack tarball"; }
  chmod 644 "$out"
  rm -rf "$stage"
  [[ -n "$mem_tmp" ]] && rm -rf "$mem_tmp"

  if [[ "$mem_inc" == "distilled" ]]; then
    ok "exported '$name' (with distilled persona memory) -> $out" \
       '{name:$n, pack:$o, withMemory:true, memory:"distilled", skills:$s}' \
       --arg n "$name" --arg o "$out" --argjson s "$skills"
  else
    ok "exported '$name' (config pack, no memory) -> $out" \
       '{name:$n, pack:$o, withMemory:false, skills:$s}' \
       --arg n "$name" --arg o "$out" --argjson s "$skills"
  fi
}

cmd_import() {
  require_root
  local pack="" as="" channels="" tg_token="" dc_token="" profile="" workdir=""
  local report_import=0 import_slug=""
  # DIVE-658 #2: provision straight from an OpenAgent persona file. The persona
  # carries identity only; these flags supply the 5dive runtime config the pack
  # would otherwise hold (sane defaults; only consumed in --from-persona mode).
  local from_persona="" p_type="claude" p_iso="standard" p_model="" p_effort=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as=*)              as="${1#--as=}" ;;
      --channels=*)        channels="${1#--channels=}" ;;
      --telegram-token=*)  tg_token="${1#--telegram-token=}" ;;
      --discord-token=*)   dc_token="${1#--discord-token=}" ;;
      --auth-profile=*)    profile="${1#--auth-profile=}" ;;
      --workdir=*)         workdir="${1#--workdir=}" ;;
      --from-persona=*)    from_persona="${1#--from-persona=}" ;;
      --type=*)            p_type="${1#--type=}" ;;
      --isolation=*)       p_iso="${1#--isolation=}" ;;
      --model=*)           p_model="${1#--model=}" ;;
      --effort=*)          p_effort="${1#--effort=}" ;;
      # DIVE-644: opt-in, default-OFF import telemetry. Only meaningful for a
      # registry-slug import (a local .tar.gz has no public slug to report).
      --report-import)     report_import=1 ;;
      -*)                  fail "$E_USAGE" "unknown flag: $1" ;;
      *)                   [[ -z "$pack" ]] && pack="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$as" ]]   || fail "$E_USAGE" "--as=<name> is required (the new agent's name)"

  # Persona mode: synthesize a v1 pack from the OpenAgent persona, then fall into
  # the normal pack-import flow below (the synth tarball IS the pack).
  local persona_tmp=""
  if [[ -n "$from_persona" ]]; then
    [[ -z "$pack" ]] || fail "$E_USAGE" "give a pack OR --from-persona, not both"
    [[ -f "$from_persona" ]] || fail "$E_NOT_FOUND" "persona file not found: $from_persona"
    step "Synthesizing pack from OpenAgent persona '$from_persona' (type=$p_type)"
    persona_tmp=$(_persona_to_pack "$from_persona" "$p_type" "$p_iso" "$p_model" "$p_effort") \
      || fail "$E_VALIDATION" "could not build a pack from persona '$from_persona' (is it a valid OpenAgent persona?)"
    pack="$persona_tmp"
  fi
  [[ -n "$pack" ]] || fail "$E_USAGE" "usage: 5dive agent import <pack>|--from-persona=<file.persona.yaml> --as=<name> [--type=claude] [--channels=...] [--telegram-token=...] [--discord-token=...] [--auth-profile=...] [--workdir=...]"

  # A bare slug (not a local file) → resolve from the character-pack git registry.
  local resolved_tmp=""
  if [[ ! -f "$pack" ]]; then
    if [[ "$pack" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
      step "Resolving '$pack' from the character-pack registry"
      import_slug="$pack"   # remember the registry slug for opt-in --report-import
      resolved_tmp=$(_marketplace_fetch_pack "$pack") \
        || fail "$E_NOT_FOUND" "no pack '$pack' in the registry (browse: 5dive agent marketplace ls)"
      pack="$resolved_tmp"
    else
      fail "$E_NOT_FOUND" "pack not found: $pack"
    fi
  fi

  # Reject an existing target up front — import recreates, it never overlays.
  local reg; reg=$(registry_read)
  jq -e --arg n "$as" '.agents[$n]' <<<"$reg" >/dev/null 2>&1 \
    && fail "$E_VALIDATION" "agent '$as' already exists — pick a fresh --as=<name> (import never overlays an existing agent)"

  # Unpack into an isolated stage and validate the manifest before touching anything.
  local stage; stage=$(mktemp -d)
  tar -xzf "$pack" -C "$stage" 2>/dev/null \
    || { rm -rf "$stage" "$resolved_tmp" "$persona_tmp"; fail "$E_GENERIC" "could not read pack (expected a .tar.gz from 'agent export')"; }
  [[ -n "$resolved_tmp" ]] && rm -f "$resolved_tmp"
  [[ -n "$persona_tmp" ]] && rm -f "$persona_tmp"
  [[ -f "$stage/manifest.json" ]] \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "pack has no manifest.json — not a 5dive agent pack"; }

  local pf; pf=$(jq -r '.packFormat // empty' "$stage/manifest.json" 2>/dev/null)
  [[ "$pf" =~ ^[0-9]+$ ]] \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "pack manifest missing packFormat"; }
  (( pf <= PACK_FORMAT_VERSION )) \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "pack format v$pf is newer than this CLI supports (v$PACK_FORMAT_VERSION) — upgrade 5dive"; }

  # Memory mode: false (config pack) or "distilled" (DIVE-472 — human-approved
  # knowledge facts under memory/, seeded after create). Reject anything else.
  local mem_inc; mem_inc=$(jq -r '.includes.memory // false' "$stage/manifest.json")
  if [[ "$mem_inc" != "false" && "$mem_inc" != "distilled" ]]; then
    rm -rf "$stage"; fail "$E_VALIDATION" "pack declares unsupported memory mode '$mem_inc'"
  fi

  # DIVE-840: a deploy-time persona may bundle its private ed25519 signing key
  # under the sanctioned ext namespace so an imported agent can OWN its identity
  # (sign) instead of just carrying a public-key rarity. Extract it into a
  # transient, agent-invisible file inside the 0700 stage dir and STRIP it from
  # persona.yaml NOW — before the CLAUDE.md render, the persona.yaml install, and
  # any card re-render below ever read the file, so the secret never persists in
  # the pack. The keystore install happens after the agent user exists (below);
  # every failure path already `rm -rf "$stage"`, which scrubs the transient key.
  local signing_keyfile="" has_signing_key=0
  if [[ -f "$stage/persona.yaml" ]]; then
    signing_keyfile="$stage/.signing_key"; : >"$signing_keyfile"; chmod 600 "$signing_keyfile"
    _persona_strip_signing_key "$stage/persona.yaml" "$signing_keyfile"; local _srk=$?
    if (( _srk == 0 )); then
      has_signing_key=1                                    # key extracted + stripped
    elif (( _srk == 9 )); then
      rm -f "$signing_keyfile"; signing_keyfile=""         # clean, no key — proceed sign-less
    else
      # FAIL CLOSED: the strip ERRORED (e.g. pyyaml missing, unreadable YAML), so
      # persona.yaml may STILL contain the private key. Never fall through to the
      # install below — abort the whole import rather than risk leaking the key.
      rm -f "$signing_keyfile"; rm -rf "$stage"
      fail "$E_GENERIC" "could not process the persona's signing key (rc=$_srk) — aborting import to avoid leaking a private key"
    fi
  fi

  # DIVE-656: if the pack carries an OpenAgent persona.yaml it is the CANONICAL
  # identity source — (re)render CLAUDE.md from it so the imported agent's identity
  # is spec-driven, not a stale hand-edited doc. Falls back to the packed CLAUDE.md
  # if the persona is unreadable. Runs before the rename below so the name swap
  # still applies to the rendered doc.
  if [[ -f "$stage/persona.yaml" ]]; then
    if _persona_render_claudemd "$stage/persona.yaml" "$stage/CLAUDE.md.oa.$$" 2>/dev/null; then
      mv "$stage/CLAUDE.md.oa.$$" "$stage/CLAUDE.md"
      step "Identity sourced from the pack's OpenAgent persona.yaml"
    else
      rm -f "$stage/CLAUDE.md.oa.$$"
      warn "pack's persona.yaml is not a valid OpenAgent persona — using the packed CLAUDE.md"
    fi
  fi

  # Rename the persona to the chosen --as name (CLAUDE.md + card + seed memory) so
  # an imported agent doesn't keep introducing itself by the pack's original name.
  local orig_name; orig_name=$(jq -r '.agentName // empty' "$stage/manifest.json")
  [[ -n "$orig_name" ]] && _pack_rename_persona "$stage" "$orig_name" "$as"

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
  # DIVE-620: a dashboard marketplace import passes no --auth-profile and packs
  # carry no profile, so $profile is empty here. Without a profile the agent is
  # created with no authProfile binding AND no agents.d/<name>-auth.env symlink,
  # so it boots with no creds AND a later dashboard re-auth (which selects agents
  # by authProfile == <name>) matches nothing and never heals it. Default the
  # profile to the new agent's name and still defer auth (below) — create
  # pre-makes the empty profile dir + symlink, a harmless no-op until first
  # sign-in, and re-auth then targets authProfile=<name> correctly.
  [[ -n "$profile" ]] || profile="$as"

  # Build the create argv. Skills are re-added afterwards (best-effort) so one
  # unresolvable ref can't abort the import. Channels default to none unless the
  # importer supplies a token (a pack never carries secrets).
  local -a cargs=("$as" "--type=$type" "--no-skills")
  [[ -n "$isolation" ]] && cargs+=("--isolation=$isolation")
  [[ -n "$workdir" ]]   && cargs+=("--workdir=$workdir")
  # DIVE-620: bind the profile AND defer auth. These are NOT mutually exclusive —
  # cmd_create pre-creates the empty profile dir + symlink under --defer-auth
  # (cmd_agent.sh ensure_profile_dir + link_agent_profile), so the imported agent
  # gets authProfile=<profile> in the registry and the agents.d/<name>-auth.env
  # symlink from creation, while first-run UI still does the actual sign-in. With
  # FIX A above $profile is always set (defaults to $as), so the prior bare
  # --defer-auth (no profile, no symlink) branch is gone.
  cargs+=("--auth-profile=$profile" "--defer-auth")
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

  # Preserve the OpenAgent persona.yaml (DIVE-656) so the imported agent owns its
  # canonical identity file — it can re-export, re-sign, or feed the gallery. The
  # rename above already swapped the pack's name/id to the --as name. (The signing
  # key, if any, was already stripped from this file above — it never persists here.)
  if [[ -f "$stage/persona.yaml" ]]; then
    # DIVE-840 fail-closed guard: no matter how the strip above went, a persona.yaml
    # that still mentions a signing_key must NEVER be installed. Abort if it does.
    if grep -qF "signing_key" "$stage/persona.yaml"; then
      rm -rf "$stage"; fail "$E_GENERIC" "refusing to install a persona.yaml that still contains a signing_key (fail-closed)"
    fi
    install -o "agent-${as}" -g "agent-${as}" -m 644 "$stage/persona.yaml" "$cdir/persona.yaml" 2>/dev/null || true
  fi

  # DIVE-840: install the adopted signing key into the imported agent's keystore so
  # it OWNS its identity and signs as itself (no re-mint — rarity already rides in
  # provenance). Perms match the openagent lib/keystore contract: dir 0700, key
  # 0600, both owned by the agent user. Then securely scrub the transient key file.
  # If there was no bundled key the agent simply runs sign-less, rarity preserved.
  if (( has_signing_key )) && [[ -s "$signing_keyfile" ]]; then
    local kdir="/home/agent-${as}/.openagent"
    install -d -o "agent-${as}" -g "agent-${as}" -m 700 "$kdir" 2>/dev/null || true
    if install -o "agent-${as}" -g "agent-${as}" -m 600 "$signing_keyfile" "$kdir/agent.key" 2>/dev/null; then
      step "Adopted the persona's signing key into the keystore (~/.openagent/agent.key) — agent owns its identity"
    else
      warn "could not install the adopted signing key; agent runs sign-less (rarity still preserved)"
    fi
  fi
  if [[ -n "$signing_keyfile" && -e "$signing_keyfile" ]]; then
    shred -u "$signing_keyfile" 2>/dev/null || rm -f "$signing_keyfile"
  fi

  # Stash the character avatar so the onboarding/Telegram flow (DIVE-494) can set
  # it as the agent's profile photo. We only preserve it here; we never set it.
  local avatar_note="none"
  if [[ -f "$stage/avatar.png" ]]; then
    install -o "agent-${as}" -g "agent-${as}" -m 644 "$stage/avatar.png" "$cdir/avatar.png" 2>/dev/null \
      && avatar_note="$cdir/avatar.png"
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

  # Seed distilled persona memory into the new agent's project memory dir. Memory
  # is keyed by project slug (the encoded workdir), so we can only place it when a
  # workdir is known; otherwise report it skipped rather than drop it somewhere
  # the agent won't read.
  local mem_seeded="none"
  if [[ "$mem_inc" == "distilled" && -d "$stage/memory" ]]; then
    if [[ -n "$workdir" ]]; then
      local slug mdir
      slug=$(printf '%s' "$workdir" | sed 's#/#-#g')
      mdir="$cdir/projects/${slug}/memory"
      install -d -o "agent-${as}" -g "agent-${as}" "$mdir" 2>/dev/null || true
      cp "$stage"/memory/*.md "$mdir/" 2>/dev/null || true
      chown -R "agent-${as}:agent-${as}" "$cdir/projects" 2>/dev/null || true
      mem_seeded="$mdir"
    else
      mem_seeded="skipped (no workdir to resolve the memory slug)"
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
    # Prefer a skill body bundled in the pack (self-contained); fall back to the
    # recorded source ref (resolved from a published repo).
    if [[ -f "$stage/skills/$id/SKILL.md" ]] && _install_bundled_skill "$as" "$id" "$stage/skills/$id"; then
      added+=("$id")
    elif ( cmd_skill_add "$as" --source="$src" --skill="$id" ) >/dev/null 2>&1; then
      added+=("$id")
    else
      skipped+=("$sk")
    fi
  done < <(jq -r '.skills[]? // empty' "$stage/manifest.json")

  rm -rf "$stage"

  # DIVE-644: fire opt-in import telemetry AFTER a fully successful import. Only
  # when --report-import was passed AND we know the registry slug (file imports
  # carry none). Best-effort and non-fatal — never let a counter hiccup taint a
  # green import.
  local reported="off"
  if (( report_import )); then
    if [[ -n "$import_slug" ]]; then
      _report_import "$import_slug" && reported="$import_slug" || reported="failed"
    else
      reported="skipped (no registry slug — local pack)"
    fi
  fi

  local added_j skipped_j
  added_j=$(printf '%s\n'   "${added[@]+"${added[@]}"}"   | jq -R . | jq -cs 'map(select(. != ""))')
  skipped_j=$(printf '%s\n' "${skipped[@]+"${skipped[@]}"}" | jq -R . | jq -cs 'map(select(. != ""))')
  local mem_note="no memory"
  [[ "$mem_inc" == "distilled" ]] && mem_note="distilled memory -> $mem_seeded"
  ok "imported '$as' from pack ($mem_note). Skills added: ${#added[@]}, skipped: ${#skipped[@]}; template: $templated; avatar: $avatar_note." \
     '{name:$n, type:$t, memory:$mem, memorySeeded:$ms, skillsAdded:$a, skillsSkipped:$s, template:$tpl, avatar:$av, reported:$ri}' \
     --arg n "$as" --arg t "$type" --arg mem "$mem_inc" --arg ms "$mem_seeded" --argjson a "$added_j" --argjson s "$skipped_j" --arg tpl "$templated" --arg av "$avatar_note" --arg ri "$reported"
}
