
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
    # DIVE-2370: this WAS a bare `[[ "$id" =~ ^[A-Za-z0-9._-]+$ ]]` — the same character
    # class DIVE-2338 proved insufficient, because it accepts "." and ".." and the caller
    # supplies the separator. It matters here and not only cosmetically: `mkdir -p
    # "$dl/skills/.."` resolves to $dl itself and the mv then plants $dl/SKILL.md, which is
    # exactly the file the import step at _install_bundled_skill probes for. Refusing the id
    # here breaks the chain at its first link.
    valid_skill_id "$id" || continue
    skill_target_within "$dl/skills" "$id" || continue
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

# _pack_skill_refs <skills-dir> -> JSON array of skill specs for the manifest.
#
# DIVE-2678. Export used to emit the bare directory names here. That is lossy in the
# one way that matters: import re-resolves a bare name through parse_skill_spec, which
# defaults to `<org>/skills` and tries NOTHING else, so a skill from any other repo
# came out of an export unresolvable and the importer could only skip it. Measured on
# two fresh seats from one exported AGENTS.md: 4 of 22 installed, and all 18 skipped
# were third-party (none published in 5dive-ai/skills — verified by fetching each).
# The provenance was never missing, only unread: `.skills-manifest.json`, written by
# cmd_skill_add next to the skills themselves, records the source each was installed
# from. Emit the qualified `<owner/repo>:<id>` form when the source is known and is not
# the default repo; keep the bare form otherwise, so the common case and the
# human-readable AGENTS.md rendering are unchanged.
#
# A skill with no manifest entry (hand-seeded, or bundled by an earlier import) still
# comes out bare — there is no fact to carry. That is the case the import-side warning
# now names out loud instead of folding into a count.
_pack_skill_refs() {
  local sdir="$1"
  [[ -d "$sdir" ]] || { echo '[]'; return 0; }
  local mf='{}'
  if [[ -f "$sdir/.skills-manifest.json" ]]; then
    mf=$(jq -c 'if type == "object" then . else {} end' "$sdir/.skills-manifest.json" 2>/dev/null) || mf='{}'
    [[ -n "$mf" ]] || mf='{}'
  fi
  # Skills install as real dirs OR symlinks (per-agent skill layout), so match
  # both — -type d alone misses the symlinked majority.
  find "$sdir" -maxdepth 1 -mindepth 1 \( -type d -o -type l \) -printf '%f\n' 2>/dev/null \
    | sort | jq -R . \
    | jq -cs --argjson m "$mf" --arg def "$(gh_org)/skills" '
        map(. as $id
            | (($m[$id].source // "") | tostring) as $s
            | if ($s == "" or $s == $def) then $id else ($s + ":" + $id) end)' 2>/dev/null \
    || echo '[]'
}

# Install a bundled skill (a local <dir>/SKILL.md) directly into the agent's
# skills dir — used on import when the pack carries the skill body.
_install_bundled_skill() {
  local name="$1" id="$2" srcdir="$3"
  [[ -f "$srcdir/SKILL.md" ]] || return 1
  local user="agent-${name}" home="/home/agent-${name}" type install_dir
  type=$(agent_type "$name"); [[ -n "$type" ]] || return 1
  # DIVE-2583: through the shared resolver, so the destination this function
  # actually writes to is the same value the export text quotes. Note what this
  # function does NOT do — it is not type-gated. It runs for EVERY type, which is
  # why "codex/opencode install none" was wrong in the import direction.
  install_dir=$(skills_install_dir "$type")
  # DIVE-2370 — THE DESTRUCTIVE SITE. $id reaches here from the pack manifest's skills[]
  # (jq over $stage/manifest.json, i.e. third-party content) via parse_skill_spec, which
  # splits on ":" and validates NOTHING. With id="..", dest resolves to $home/.claude and
  # the next line is `rm -rf` — settings, credentials, projects and memory, followed by a
  # cp -r + chown -R that leaves a plausible-looking directory behind. Same predicate as
  # cmd_skill_rm, one definition, in validation.sh.
  valid_skill_id "$id" || { warn "refusing bundled skill id '$id' (invalid)"; return 1; }
  skill_target_within "$home/$install_dir" "$id" \
    || { warn "refusing bundled skill id '$id' — escapes $install_dir (DIVE-2370)"; return 1; }
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

# `5dive market` (DIVE-1020) — the front door to the agent market: browse/search
# the character-pack registry (rarity-first) and preview a persona before hiring.
# Read-only (curls the public index; no root/lock/audit — same posture as
# `agent marketplace`). Pairs with `hire <role> --from-market` (which provisions)
# and the OpenAgent registry (each pack carries a did:key identity).
#
#   5dive market [<keyword>] [--role=<r>] [--rarity=<t>] [--seasoned] [--json]
#   5dive market search <keyword>          # alias for the above
#   5dive market show <slug>               # preview one persona (tier, skills, card, DID)
_market_usage() {
  cat <<'USAGE'
5dive market — browse & search the agent market before you hire (DIVE-1020)

  5dive market                          # browse every pack, rarity-first
  5dive market <keyword>                # search slug/name/tagline/role/tags/skills
  5dive market search <keyword>         #   (explicit alias)
  5dive market --role=<r>               # filter by role/character (e.g. engineer, ceo)
  5dive market --rarity=<tier>          # filter by tier (mythical|legendary|epic|rare)
  5dive market --seasoned               # only packs that ship pre-trained memory
  5dive market show <slug>              # preview a persona: tier, model, skills, card, DID
  --json                                # machine-readable (dashboard/agent feed)

  Then: 5dive hire <role> --from-market --dry-run   (preview a real hire, provisions nothing)
        5dive agent inspect <slug>                  (full install-time disclosure, incl. which harnesses it lands on)
        5dive agent import <slug> --as=<name>       (clone this exact persona)
        5dive agent import <slug> --as=<name> --type=codex     (DIVE-2568: onto a non-Claude harness)

  A pack is HARNESS-AGNOSTIC. `type` in the catalog is what it was packed as and
  is only the import default — the persona, memory, avatar and skills are plain
  markdown and data, and import renders the identity doc into whichever
  instruction file the target harness actually reads.
USAGE
}

# jq helper text shared by the market renderers: rarity ranking, base-skill set
# (baseline skills every agent gets — filtered from the "distinctive" count so a
# pack isn't credited for them), and a 0-100 completeness score.
_MARKET_JQ='
  def rank: {"mythical":0,"legendary":1,"epic":2,"rare":3}[(.//"")] // 4;
  def base: ["notify-user","find-skills","compile-knowledge","5dive-cli"];
  def distinct: ((.skills // []) - base);
  def complete:
    ( (if ((.tagline // "")|length) > 0 then 1 else 0 end)
    + (if (distinct|length) > 0        then 1 else 0 end)
    + (if .includesMemory              then 1 else 0 end)
    + (if ((.avatar  // "")|length) > 0 then 1 else 0 end)
    + (if ((.did     // "")|length) > 0 then 1 else 0 end) ) * 20;
  def shortmodel: (. // "-" | sub("^claude-";"") | sub("-20[0-9]+$";""));
'

cmd_market() {
  local sub="${1:-ls}"
  case "$sub" in
    -h|--help)          _market_usage; return 0 ;;
    show|info|preview)  shift || true; cmd_market_show "$@"; return ;;
    ls|list|browse)     [[ $# -gt 0 ]] && shift || true ;;
    search|find)        shift || true ;;   # explicit search alias; keyword(s) follow
  esac

  local kw="" role="" rarity="" seasoned=0 a
  for a in "$@"; do
    case "$a" in
      --role=*)             role="${a#--role=}" ;;
      --rarity=*)           rarity="${a#--rarity=}" ;;
      --tier=*)             rarity="${a#--tier=}" ;;
      --seasoned|--memory)  seasoned=1 ;;
      --*)                  fail "$E_USAGE" "unknown flag: $a (see: 5dive market --help)" ;;
      *)                    [[ -z "$kw" ]] && kw="$a" || kw="$kw $a" ;;
    esac
  done

  local idx; idx=$(_marketplace_index) \
    || fail "$E_GENERIC" "could not reach the agent market ($(_marketplace_base))"
  jq -e '.packs' >/dev/null 2>&1 <<<"$idx" || fail "$E_GENERIC" "market index is malformed"

  local filtered
  filtered=$(jq -c \
    --arg kw   "$(printf '%s' "$kw"     | tr '[:upper:]' '[:lower:]')" \
    --arg role "$(printf '%s' "$role"   | tr '[:upper:]' '[:lower:]')" \
    --arg rar  "$(printf '%s' "$rarity" | tr '[:upper:]' '[:lower:]')" \
    --argjson seasoned "$seasoned" '
    def L(x): (x // "" | ascii_downcase);
    .packs | map(select(
        ($kw=="" or (
           (L(.slug)|contains($kw)) or (L(.name)|contains($kw)) or (L(.tagline)|contains($kw))
           or (L(.character)|contains($kw))
           or (((.tags//[])   + (.skills//[])) | any(ascii_downcase|contains($kw)))
        ))
        and ($role=="" or (L(.character)|contains($role)) or ((.tags//[])|any(ascii_downcase|contains($role))))
        and ($rar=="" or (L(.rarity)==$rar))
        and ($seasoned==0 or (.includesMemory==true))
    ))' <<<"$idx")

  local n total; n=$(jq 'length' <<<"$filtered"); total=$(jq '.packs|length' <<<"$idx")

  if (( JSON_MODE )); then
    ok "" '{registry:($org+"/character-packs"), query:{keyword:$kw,role:$role,rarity:$rar,seasoned:($s==1)}, total:$t, count:$n, packs:$p}' \
       --arg org "$(gh_org)" --arg kw "$kw" --arg role "$role" --arg rar "$rarity" \
       --argjson s "$seasoned" --argjson t "$total" --argjson n "$n" --argjson p "$filtered"
    return
  fi

  if (( n == 0 )); then
    local q=""; [[ -n "$kw" ]] && q+=" '$kw'"; [[ -n "$role" ]] && q+=" role=$role"; [[ -n "$rarity" ]] && q+=" rarity=$rarity"
    echo "No agents match${q} in the market ($(gh_org)/character-packs)."
    echo "Browse all: 5dive market"
    return
  fi
  local hdr="AGENT MARKET — $(gh_org)/character-packs  ($n"
  [[ "$n" != "$total" ]] && hdr+=" of $total, filtered"
  echo "${hdr} packs)"
  echo
  jq -r "$_MARKET_JQ"'
    sort_by([(.rarity|rank), -(distinct|length), (if .includesMemory then 0 else 1 end)])
    | (["SLUG","NAME","TIER","ROLE","MODEL","SKILLS","MEMORY","COMPLETE"]|@tsv),
      (.[] |
        [ .slug, .name, (.rarity // "-"), (.character // "-"),
          (.model|shortmodel), (distinct|length|tostring),
          (if .includesMemory then "seasoned" else "persona" end),
          ((complete|tostring) + "%") ]|@tsv)' <<<"$filtered" \
    | column -t -s $'\t' | sed 's/^/  /'
  echo
  # DIVE-2568: nobody should hire something that will not run. The harness set is
  # derived per pack, but it is IDENTICAL for every pack that does not narrow
  # itself — so a per-row column would be the same string repeated N times, which
  # reads as noise and gets skipped. State it once as a property of the catalog,
  # and let `market show` carry the per-pack answer for the narrowed case.
  local _agnostic; _agnostic=$(_pack_targets_from "" | paste -sd, - | sed 's/,/, /g')
  local _narrowed; _narrowed=$(jq -r '[.[] | select(((.targets // []) | length) > 0) | .slug] | length' <<<"$filtered")
  echo "  lands on: ${_agnostic:-(no hostable harness on this box)}  — every pack imports onto any of these (5dive agent import <slug> --as=<n> --type=<harness>)"
  (( _narrowed > 0 )) && echo "  ${_narrowed} pack(s) here narrow that set — see 5dive market show <slug>"
  echo
  echo "  preview: 5dive market show <slug>    ·    hire: 5dive hire <role> --from-market --dry-run"
}

# `5dive market show <slug>` — preview a single persona without downloading the
# pack tarball: metadata from the index + the human `card.md` blurb + its
# OpenAgent DID. For the full executable disclosure, `agent inspect <slug>`.
cmd_market_show() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || fail "$E_USAGE" "usage: 5dive market show <slug>"
  local idx; idx=$(_marketplace_index) \
    || fail "$E_GENERIC" "could not reach the agent market ($(_marketplace_base))"
  local pack; pack=$(jq -c --arg s "$slug" '.packs[] | select(.slug==$s)' <<<"$idx")
  [[ -n "$pack" && "$pack" != "null" ]] \
    || fail "$E_NOT_FOUND" "no agent '$slug' in the market (browse: 5dive market)"

  local base card path
  base=$(_marketplace_base); path=$(jq -r '.path' <<<"$pack")
  card=$(curl -fsSL --max-time 15 "${base}/${path}/card.md" 2>/dev/null || true)

  # DIVE-2568: the per-pack harness answer, derived from THIS CLI and narrowed
  # only if the catalog entry says so. A pack's `type` in the index is what it was
  # packed as — the import DEFAULT — never a ceiling, so it is rendered as such.
  local lands_j; lands_j=$(_pack_targets_from "$(jq -r '(.targets // [])[]? | select(type=="string")' <<<"$pack")" | jq -R . | jq -cs 'map(select(. != ""))')

  if (( JSON_MODE )); then
    ok "" '{pack:$p, card:$c, landsOn:$lands}' --argjson p "$pack" --arg c "$card" --argjson lands "$lands_j"
    return
  fi
  # DIVE-2303: a pack stores the family ALIAS ("opus"), never a concrete id, so the
  # catalog entry is still true after the alias moves. Resolve at RENDER instead —
  # "opus (currently claude-opus-5)" is honest today and honest after opus 6, where
  # a resolved id baked into index.json would just recreate the drift one layer up.
  # A pack that deliberately pins shows its id alone (resolve returns it unchanged).
  local _m _mres _mdisp
  _m=$(jq -r '.model // ""' <<<"$pack")
  _mres=$(resolve_model_alias "$_m")
  if [[ -z "$_m" ]]; then _mdisp="-"
  elif [[ "$_mres" != "$_m" ]]; then _mdisp="$_m (currently $_mres)"
  else _mdisp="$_m"; fi
  jq -r --arg mdisp "$_mdisp" --argjson lands "$lands_j" "$_MARKET_JQ"'
    "\(.name)  —  \(.rarity // "unranked") · \(.character // "agent")   ·   completeness \(complete)%",
    "  \(.tagline // "")",
    "",
    "  lands on: " + (if ($lands|length)>0 then ($lands|join(", ")) else "(no hostable harness on this box)" end)
                  + (if ((.targets // [])|length) > 0 then "   [narrowed by the pack]" else "" end)
                  + (if (.type // "") != "" then "   (packed as \(.type))" else "" end),
    "  model:   \($mdisp)    effort: \(.effort // "-")",
    "  memory:  " + (if .includesMemory then "seasoned — ships pre-trained (distilled lessons)" else "persona-only (no seeded memory)" end),
    "  skills:  " + (distinct | if length==0 then "(baseline only)" else join(", ") end),
    "  identity: \(.did // "-")"' <<<"$pack"
  if [[ -n "$card" ]]; then
    echo
    echo "  ── persona preview (card.md) ──"
    printf '%s\n' "$card" | head -40 | sed 's/^/  /'
  fi
  echo
  echo "  full disclosure:  5dive agent inspect ${slug}"
  echo "  clone this one:   5dive agent import ${slug} --as=<name>            (defaults to the harness it was packed as)"
  echo "  onto a codex/opencode seat:  5dive agent import ${slug} --as=<name> --type=codex"
  echo "  hire by role:     5dive hire <role> --from-market --dry-run"
}

# DIVE-995 pack trust layer. Enumerate the EXECUTABLE surface a pack would grant
# the imported agent — the "this pack runs X" install-time disclosure and the
# safety precondition before running ANY third-party pack. Pure + read-only:
# takes an already-unpacked stage dir, emits a JSON object; callers render or
# gate on it. Highest-risk item is `hooks` (arbitrary shell that auto-runs on the
# new agent's tool events — the agentjacking/prompt-injection surface); the rest
# (skills/plugins added, system-prompt render, seeded recall, adopted signing
# key) are lower-risk but still material to an informed install decision.
# DIVE-2568 — WHICH HARNESSES A PACK CAN LAND ON.
#
# Target-agnostic, and DERIVED rather than declared. Nothing in packFormat 1 is
# Claude-specific: persona.yaml, card.md, the manifest, the avatar and memory/
# are harness-neutral markdown and data. Exactly two questions are harness-bound
# — WHERE the identity doc goes and WHERE skills go — and both are already
# answered per type by TYPE_PERSONA_FILE and SKILLS_INSTALL_DIR. So the target
# set is "every known type whose persona doc has a probe-verified home", which
# is the DIVE-2223 invariant, nothing new.
#
# The consequence is the point of this row: all 19 shipped packs declare
# config.type "claude" and not one of them has to be republished to become
# importable onto codex or opencode. A publisher cannot get compatibility wrong
# because a publisher does not state it.
#
# The optional manifest key config.targets NARROWS the set and can never widen
# it — a pack that genuinely needs one harness may say so, but no pack may claim
# a harness this CLI cannot render its persona into.
#
# DELIBERATELY NOT WRITTEN BY cmd_export. The set is a property of the CLI, not
# of the pack; baking it in at pack time freezes it on the day it was packed and
# recreates precisely the drift DIVE-2303 moved back out of index.json. A pack
# packed today gets a harness added tomorrow for free.
_pack_targets_from() {   # _pack_targets_from [<newline-separated declared narrowing>]
  local declared="${1:-}" t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    # An entry with no persona path (hermes, openclaw) is not a target: the
    # create would succeed and the persona — the pack's whole payload — would
    # never reach the model. That is a half-import, not an import.
    [[ -n "${TYPE_PERSONA_FILE[$t]:-}" ]] || continue
    is_known_type "$t" || continue
    if [[ -n "$declared" ]] && ! grep -qxF -- "$t" <<<"$declared"; then continue; fi
    printf '%s\n' "$t"
  done < <(printf '%s\n' "${!TYPE_PERSONA_FILE[@]}" | sort -u)
}

# Same set, read through a pack manifest's optional config.targets narrowing.
_pack_harness_targets() {   # _pack_harness_targets [<manifest.json>]
  local mf="${1:-}" declared=""
  if [[ -n "$mf" && -f "$mf" ]]; then
    declared=$(jq -r '(.config.targets // [])[]? | select(type=="string")' "$mf" 2>/dev/null || true)
  fi
  _pack_targets_from "$declared"
}

# True when the manifest narrows its own target set (vs. the agnostic default).
_pack_targets_declared() {   # _pack_targets_declared <manifest.json>
  [[ -f "${1:-}" ]] || return 1
  jq -e '((.config.targets // []) | length) > 0' "$1" >/dev/null 2>&1
}

# DIVE-2568 — WHAT A NON-CLAUDE SEAT CANNOT CARRY, named by value.
#
# settings.json is Claude Code's file and it is the ONLY sink 5dive has for a
# pack's model, effort, hooks and plugins. On a codex or opencode seat those four
# keys have nowhere to go. That is correct and it is not a reason to refuse the
# import — the persona, memory, avatar and skills are the payload and they all
# land. What was wrong is that the drop was SILENT: a pack whose manifest reads
# model "opus" imported onto codex produced an agent running the harness default
# while the manifest still read "opus", with nothing on screen either way. Same
# rule DIVE-2565 set for the three things a text file cannot carry — the drop is
# fine, the silence is not, and the report must name the VALUE (not just the key)
# so the operator can set it in the harness's own config.
#
# Extracted from cmd_import so it is gradeable without root, a network or an
# agent user: an assertion on the warn STRING grades the rendering, not the
# condition, and would pass on a branch that never runs. Emits one item per line;
# empty output means nothing was dropped. Never fails — a report, not a gate.
# model/effort are the RESOLVED values the import would have written (manifest,
# then any explicit --model/--effort override, then resolve_model_alias) — NOT
# re-read from the manifest here. Reporting the manifest's value would name a
# model the operator never asked for whenever they passed an override, which is
# the same class of wrong-but-plausible the report exists to prevent.
_pack_unapplied_on() {   # _pack_unapplied_on <type> <model> <effort> <hooks-present:0|1> <manifest.json>
  local type="${1:-}" model="${2:-}" effort="${3:-}" hooks_present="${4:-0}" mf="${5:-}"
  [[ "$type" == "claude" ]] && return 0
  [[ -n "$model"  ]] && printf 'model=%s\n'  "$model"
  [[ -n "$effort" ]] && printf 'effort=%s\n' "$effort"
  (( hooks_present )) && printf 'hooks\n'
  if [[ -f "$mf" ]] && jq -e '((.plugins // []) | length) > 0' "$mf" >/dev/null 2>&1; then
    printf 'plugins\n'
  fi
  return 0
}

# _pack_seat_needs_key <type> — 0 when an API key is this seat's ONLY route to a
# model, 1 otherwise. DIVE-2676.
#
# The distinction that matters at import time is not "claude vs not". It is
# whether deferring auth leaves a route open at all:
#   * TYPE_AUTH holds the file a harness writes after an INTERACTIVE sign-in, so
#     a type listed there (claude, codex, pi, grok, ...) boots credential-less on
#     purpose — first-run UI finishes the job, and --defer-auth is honest.
#   * A type in TYPE_API_FILE but NOT in TYPE_AUTH has no such flow. opencode is
#     the one on this box: its key is injected from the connector file and there
#     is nothing a human can click later. Deferring auth there does not postpone
#     the credential, it omits it — and the seat additionally never gets the
#     opencode.json model pin that only the create path's --provider branch
#     writes. Measured 2026-08-04: 'agent info' shows model: — and every ask
#     times out at 120s, after an import that reported OK.
#
# Derived from the maps rather than a hardcoded list so a new API-key-only type
# is covered the day it is added, and a type that gains a sign-in flow drops out.
_pack_seat_needs_key() {
  local t="${1:-}"
  [[ -n "${TYPE_API_FILE[$t]:-}" && -z "${TYPE_AUTH[$t]:-}" ]]
}

_pack_disclosure_json() {
  local stage="$1" mf="$1/manifest.json"
  [[ -f "$mf" ]] || { echo '{}'; return 1; }
  # DIVE-2568: the harness set is part of the install-time disclosure, not a
  # separate report — `agent inspect`, the import-time print and the market
  # preview all read it from here, so there is one answer and three renders.
  local lands_on; lands_on=$(_pack_harness_targets "$mf" | jq -R . | jq -cs .)
  # A persona.yaml is the canonical identity source, so its presence means the
  # pack (re)renders the agent's system prompt (CLAUDE.md). Pre-strip it may also
  # bundle a private signing key the imported agent would adopt (own its identity).
  local renders=false adopts=false
  if [[ -f "$stage/persona.yaml" ]]; then
    renders=true
    grep -qF "signing_key" "$stage/persona.yaml" && adopts=true
  fi
  jq -n --argjson m "$(cat "$mf")" --argjson r "$renders" --argjson a "$adopts" \
        --argjson lands "$lands_on" '
    ($m.hooks // {}) as $h
    | ($m.plugins // []) as $p
    | [$h | .. | objects | .command? // empty] as $cmds
    # DIVE-1009 (1): recurse plugin-carried hooks. A bundled plugin can register
    # its OWN shell-on-tool-event; the top-level $m.hooks scan never sees it. Walk
    # the plugins structure for any nested hook command AND any non-empty .hooks
    # block a plugin ships, so a plugin hook is disclosed as an executable surface.
    | [$p | .. | objects | .command? // empty] as $pcmds
    | [$p | .. | objects | select(has("hooks")) | .hooks
           | select(. != null and (. | length) > 0)] as $pHookBlocks
    # DIVE-1009 (2): defense in depth — flag hooks as present when .hooks is
    # NON-EMPTY, not merely when it carries a .command. A future CC hook type that
    # executes without a .command field would otherwise slip both disclosure and
    # the strip gate. Callers strip on nonEmpty, not just count>0.
    | {
        hooks:   { count: ($cmds | length), events: ($h | keys),
                   commands: $cmds, nonEmpty: (($h | length) > 0) },
        pluginHooks: { count: ($pcmds | length), commands: $pcmds,
                       present: (($pcmds | length) > 0 or ($pHookBlocks | length) > 0) },
        skills:  ($m.skills  // []),
        plugins: ($m.plugins // []),
        # DIVE-2568. `landsOn` is DERIVED from this CLI; `declaredType` is what
        # the pack itself was packed as and is only the import DEFAULT, never a
        # ceiling. `narrowed` says the publisher restricted the set by hand.
        landsOn:      $lands,
        declaredType: ($m.config.type // null),
        narrowed:     ((($m.config.targets // []) | length) > 0),
        rendersSystemPrompt: $r,
        seedsMemory: (($m.includes.memory // false) != false),
        adoptsSigningKey: $a
      }'
}

# Human-readable render of a disclosure JSON blob (from _pack_disclosure_json).
_pack_disclosure_print() {
  local d="$1" hc
  hc=$(jq -r '.hooks.count' <<<"$d")
  echo "  ── pack will let the new agent run ──────────────────────────"
  if (( hc > 0 )); then
    warn "HOOKS: $hc shell command(s) auto-run on this agent's tool events —"
    jq -r '.hooks.commands[] | "        $ " + .' <<<"$d"
    echo "        (arbitrary shell; NOT installed unless you pass --allow-hooks)"
  else
    echo "     hooks:   none"
  fi
  # DIVE-1009: plugin-carried hooks are their own executable surface — a bundled
  # plugin can auto-run shell on tool events even when top-level hooks is empty.
  if [[ "$(jq -r '.pluginHooks.present // false' <<<"$d")" == "true" ]]; then
    warn "PLUGIN HOOKS: bundled plugin(s) ship shell that auto-runs on tool events —"
    jq -r '.pluginHooks.commands[]? | "        $ " + .' <<<"$d"
    echo "        (plugin-carried shell; NOT installed unless you pass --allow-hooks)"
  fi
  echo "     skills:  $(jq -r 'if (.skills|length)>0 then "\(.skills|length) (\(.skills|join(", ")))" else "none" end' <<<"$d")"
  # Plugins may be a name-array, an object of enabled plugins ({"p@mkt":true}), or
  # (hostile) an array of objects carrying hooks — normalize all three to names so
  # the render never crashes on the exact shape DIVE-1009 hardens against.
  echo "     plugins: $(jq -r '
      (.plugins // []) as $p
      | (if   ($p|type)=="object" then ($p|keys)
         elif ($p|type)=="array"  then [$p[] | if type=="object" then (.name // "plugin") else tostring end]
         else [] end) as $names
      | if ($names|length)>0 then ($names|join(", ")) else "none" end' <<<"$d")"
  # DIVE-2568: state the harness set BEFORE the reader decides to install. "Which
  # seats does this run on" is an install decision, so it belongs in the same
  # disclosure as "what does it run", not in a separate command.
  echo "     lands on: $(jq -r '
      (.landsOn // []) as $l
      | (if ($l|length)>0 then ($l|join(", ")) else "(no harness on this box can host it)" end)
      + (if .narrowed then "   [narrowed by the pack]" else "" end)
      + (if (.declaredType // "") != "" then "   (packed as \(.declaredType))" else "" end)' <<<"$d")"
  echo "     system prompt re-rendered from persona: $(jq -r '.rendersSystemPrompt' <<<"$d")"
  echo "     seeds recall memory: $(jq -r '.seedsMemory' <<<"$d")"
  echo "     adopts a bundled signing key (owns identity): $(jq -r '.adoptsSigningKey' <<<"$d")"
  echo "  ─────────────────────────────────────────────────────────────"
}

# DIVE-1010: guard tar extraction against path-traversal (zip-slip). A local
# `.tar.gz` import (import <file>) bypasses registry signing entirely, so an
# untrusted pack could carry members like `../../etc/...` or `/abs/path` that
# tar would write OUTSIDE the mktemp stage. Validate every member up front and
# refuse the pack before extracting anything. Shared by cmd_inspect + cmd_import.
#
# DIVE-1011: the name-check above cannot cover a SYMLINK escape — a distinct
# class. A pack ships member 1 = a symlink `link -> /etc` (name 'link' passes),
# then member 2 = `link/file` (name also passes); on extraction tar follows the
# on-disk symlink and writes OUTSIDE the stage (e.g. /etc/file). Same for
# hardlinks. Modern GNU tar has its own symlink-replacement guard, so this is
# defense-in-depth, but a name-check alone genuinely can't see it. Refuse any
# pack that ships a link member outright — 5dive packs never contain links.
# Returns: 0 ok, 1 unreadable/not-a-gzip, 2 unsafe member (traversal or link).
_pack_safe_extract() {
  local pack="$1" stage="$2" member listing type_listing
  listing=$(tar -tzf "$pack" 2>/dev/null) || return 1
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    case "$member" in
      /*|..|../*|*/../*|*/..) return 2 ;;
    esac
  done <<<"$listing"
  # Verbose listing: the leading char of each entry is the type flag —
  # 'l' = symlink, 'h' = hardlink. Refuse the pack if any member is a link.
  type_listing=$(tar -tvzf "$pack" 2>/dev/null) || return 1
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    case "$member" in
      [lh]*) return 2 ;;
    esac
  done <<<"$type_listing"
  tar -xzf "$pack" -C "$stage" 2>/dev/null || return 1
}

# DIVE-995: `5dive agent inspect <pack|slug>` — read-only "look before you
# install". Resolves a local pack OR a bare registry slug, unpacks into an
# isolated stage, and reports its executable surface (see _pack_disclosure_json)
# WITHOUT creating anything. No root needed. The safety precondition a person (or
# an agent) runs before importing a third-party pack.
cmd_inspect() {
  local pack="${1:-}"
  [[ -n "$pack" ]] || fail "$E_USAGE" "usage: 5dive agent inspect <pack.tar.gz|slug>"
  local resolved_tmp=""
  if [[ ! -f "$pack" ]]; then
    if [[ "$pack" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
      resolved_tmp=$(_marketplace_fetch_pack "$pack") \
        || fail "$E_NOT_FOUND" "no pack '$pack' in the registry (browse: 5dive agent marketplace ls)"
      pack="$resolved_tmp"
    else
      fail "$E_NOT_FOUND" "pack not found: $pack"
    fi
  fi
  local stage; stage=$(mktemp -d)
  _pack_safe_extract "$pack" "$stage" || { local rc=$?; rm -rf "$stage" "$resolved_tmp"
    (( rc == 2 )) && fail "$E_VALIDATION" "pack rejected: contains unsafe members (path traversal, absolute paths, or sym/hardlinks), refusing to extract"
    fail "$E_GENERIC" "could not read pack (expected a .tar.gz from 'agent export')"; }
  [[ -n "$resolved_tmp" ]] && rm -f "$resolved_tmp"
  [[ -f "$stage/manifest.json" ]] \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "pack has no manifest.json — not a 5dive agent pack"; }
  local disc; disc=$(_pack_disclosure_json "$stage") \
    || { rm -rf "$stage"; fail "$E_VALIDATION" "could not read pack manifest"; }
  local aname; aname=$(jq -r '.agentName // "?"' "$stage/manifest.json")
  if (( JSON_MODE )); then
    ok "" '{pack:$p, disclosure:$d}' --arg p "$aname" --argjson d "$disc"
  else
    echo "Pack '$aname' — install-time disclosure (DIVE-995)"
    _pack_disclosure_print "$disc"
    echo "  import with: 5dive agent import <pack> --as=<name>   (add --allow-hooks to keep hooks)"
  fi
  rm -rf "$stage"
}

_pack_usage() {
  cat <<USAGE
5dive agent export / import — portable agent packs (DIVE-39)

  5dive agent export <name> [--format=pack|agents-md] [--with-memory]
                            [--approve-memory=<dir>] [--audience=publish|self] [-o <path>|--out=<path>]
                                  # write a shareable pack. Default = config only.
                                  # --format=agents-md (DIVE-2565) writes ONE markdown
                                  # file that IS an AGENTS.md: YAML frontmatter = the
                                  # agent spec, body = the persona doc, memory as fenced
                                  # '## memory/<file>' sections. Readable, diffable,
                                  # pasteable — and codex/opencode read it as-is with no
                                  # 5dive installed. Skills travel as NAMES not bodies and
                                  # hooks are never carried; the file says both out loud.
                                  # 'agent import <file.md>' splits it back.
                                  # --audience (DIVE-2567) picks who the pack is FOR, and
                                  # DEFAULTS TO publish: staged memory is scanned for
                                  # operational detail (host paths, agent/human names,
                                  # hostnames, task ids, repo names, chat ids, sudo posture,
                                  # credential locations) and the export is REFUSED naming
                                  # file, line and category. Nothing is ever silently
                                  # redacted. --audience=self (own backup / clone on your own
                                  # box) skips THAT scan and ONLY that scan — never publish a
                                  # self pack. DIVE-2679: the secret tripwire (real tokens/keys)
                                  # is a separate control and runs on BOTH audiences, always.
                                  # 'self' is not a force flag; there is deliberately no way to
                                  # export a staged credential.
                                  # It gates BOTH containers: the scan runs before the
                                  # format branch, so the tarball and the single-file
                                  # AGENTS.md are covered by construction, not by two rules.
                                  # --with-memory is a TWO-PHASE deny-by-default flow:
                                  #   1) export <name> --with-memory  -> writes a scoped persona
                                  #      DRAFT (only reference/project knowledge facts; private
                                  #      user/feedback facts excluded) for you to review + edit.
                                  #   2) export <name> --approve-memory=<draft dir>  -> seals the
                                  #      reviewed memory into the pack. Nothing is packed unreviewed.
  5dive agent marketplace [ls]    # browse the character-pack registry (<org>/character-packs)
  5dive agent inspect <pack|slug> # DIVE-995: read-only "this pack runs X" disclosure —
                                  # hooks (arbitrary shell), skills, plugins, whether it
                                  # re-renders the system prompt, seeds memory, or adopts a
                                  # signing key. Run this BEFORE importing a third-party pack.
  5dive agent import <pack|slug> --as=<name> [--channels=none|telegram|discord|dashboard[,ch...]]
                            [--telegram-token=<tok>] [--discord-token=<tok>]
                            [--auth-profile=<name>] [--workdir=<path>] [--report-import] [--allow-hooks]
                            [--type=<type>] [--provider=<id> --api-key=<key|->] [--model=<slug>]
                                  # --provider/--api-key (DIVE-2676): provision the seat's
                                  # credentials AND model in the same command. An API-key-only
                                  # harness (opencode) has no interactive sign-in, so without
                                  # these the import lands the persona onto an agent that has
                                  # no model and CANNOT ANSWER. "-" reads the key from stdin.
                                  # --allow-hooks (default OFF): keep the pack's hooks. Without
                                  # it, a pack's arbitrary-shell hooks are STRIPPED on import.
                                  # recreate an agent from a pack into a FRESH name.
                                  # <pack> = a .tar.gz file OR a bare registry slug
                                  # (e.g. 'import lilbro --as=...') pulled from the git registry.
                                  # --report-import (opt-in, default OFF): ping a public
                                  # increment-only, zero-PII counter with just the pack slug
                                  # so the gallery can rank Most-imported. Registry slugs only.
                                  # Packs carry no secrets: supply the new agent's own
                                  # token/auth-profile here. Skills are re-added from their
                                  # recorded refs (skills not in a published repo are skipped
                                  # + reported). Memory is never in a config pack.

  A pack carries an agent's portable identity (instructions, skills, settings subset),
  NEVER secrets (tokens/keys/sessions/transcripts are hard-excluded). --with-memory adds
  redacted persona memory through a mandatory review gate. 'agent clone' (same-host
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
# Returns 0 (clean) or 1 (hit); on hit, prints file:line: <class> to stderr.
# Belt + braces: the real safety is the allowlist + type-scoping, this catches
# a regression that widens either.
#
# DIVE-2679 — WHY THIS IS THREE RULE KINDS AND NOT ONE ALTERNATION. The original
# was a single case-insensitive alternation over the staged dir, and two of its
# branches matched ENGLISH rather than secrets. `sk-[A-Za-z0-9]` is unanchored, so
# it fires on ta"sk-"need, a"sk-"rail, ri"sk-"tier, ma"sk-"wt — measured against a
# real 411-fact memory store it hit 41 files and NOT ONE held a key; with a word
# boundary and a realistic length it hits zero. On a board whose vocabulary is
# literally task/ask/risk that single rule refuses every export the feature has.
# `credentials` and a bare `API_KEY` are the same mistake in slower motion: agent
# memory is ABOUT operations, so it discusses credentials by name constantly, and
# the matched lines were things like "a workflow-file push is NOT blocked by
# credentials" and `OPENROUTER_API_KEY=…` with the value already elided.
#
# So the fix is not a looser tripwire, it is a tripwire that distinguishes a
# secret's VALUE from a secret's NAME:
#   value rules  — shapes only a real credential has; match anywhere.
#   assign rules — a key NAME is a secret only when something is assigned to it.
#   file rules   — a staged file that IS a credential store. This is the actual
#                  "allowlist regression" case the tripwire was written for, and
#                  it was never checked: only content was.
# Net effect on detection is POSITIVE — gh_/AWS tokens and PEM blocks were not
# covered before and are now, while prose about credentials no longer refuses.
_PACK_SECRET_VALUE_RULES=(
  # The trailing [A-Z ]* is load-bearing and was missing: an armoured PGP secret key
  # is `-----BEGIN PGP PRIVATE KEY BLOCK-----`, so the word after "PRIVATE KEY" put it
  # out of reach of a trailing literal and it exported CLEAN (caught in review). A
  # suffix class rather than `( BLOCK)?` so any future armour label is covered too.
  # `-----BEGIN CERTIFICATE-----` deliberately does NOT match: a certificate is public,
  # and the old bare `-----BEGIN` refused on one. That is a narrowing, on purpose.
  'private-key-block:-----BEGIN[A-Z ]*PRIVATE KEY[A-Z ]*-----'
  'openai-style-key:(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'
  'github-token:(^|[^A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,}'
  'slack-token:(^|[^A-Za-z0-9])xox[abposr]-[A-Za-z0-9-]{10,}'
  'aws-access-key-id:(^|[^A-Za-z0-9])AKIA[0-9A-Z]{16}([^0-9A-Z]|$)'
  'telegram-bot-token:(^|[^A-Za-z0-9])[0-9]{8,}:[A-Za-z0-9_-]{30,}'
)
_PACK_SECRET_ASSIGN_RULES=(
  "assigned-credential:(BOT_TOKEN|API_?KEY|ACCESS_TOKEN|AUTH_TOKEN|SECRET_KEY|CLIENT_SECRET|PASSWORD|CREDENTIALS?)[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z0-9_./+-]{16,}"
)
# Anchored at a path segment so a FACT named e.g. 'dive931-secret-drop.md' is not a
# credential store, but a staged '.env' or 'id_ed25519' is.
_PACK_SECRET_FILE_RE='(^|/)(\.env(\.[A-Za-z0-9_-]+)?|credentials(\.(json|ya?ml))?|id_(rsa|ed25519|ecdsa)|.*\.(pem|p12|pfx|keystore))$'

_pack_secret_tripwire() {
  local dir="$1" hit=0 rule class re f line rel

  # 1. A staged file that IS a credential store, by name.
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    printf '%s: credential-file\n' "${f#"$dir"/}" >&2
    hit=1
  done < <(find "$dir" -type f 2>/dev/null | grep -E "$_PACK_SECRET_FILE_RE" || true)

  # 2. Content. -I skips binaries (avatar.png is staged alongside memory and its
  # bytes will eventually match any long-enough character class by chance).
  # NEVER echo the match itself — the report is file:line and the rule that fired,
  # so a refusal is actionable without the refusal becoming its own leak.
  for rule in "${_PACK_SECRET_VALUE_RULES[@]}" "${_PACK_SECRET_ASSIGN_RULES[@]}"; do
    class="${rule%%:*}"; re="${rule#*:}"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      rel="${line#"$dir"/}"
      printf '%s: %s\n' "$(cut -d: -f1,2 <<<"$rel")" "$class" >&2
      hit=1
    # -e is NOT optional: the private-key rule begins with '-' and grep reads a bare
    # leading-dash pattern as flags. It silently matched nothing, and the miss was
    # invisible because a fixture holding a PEM block usually trips some other rule too.
    done < <(grep -rnIE -e "$re" "$dir" 2>/dev/null || true)
  done
  return "$hit"
}

# --- DIVE-2567: the memory leak-check, ENFORCED on the export path -----------
#
# character-packs/README.md has always REQUIRED that a published pack carry
# "distilled seed memory ... never raw private memory or secrets". That rule was
# DOCUMENTED AND NOT ENFORCED: nothing in the CLI or CI had ever looked at memory
# CONTENT on the way out. It survived only because five packs ship memory and a
# human wrote each one. A one-command memory export (DIVE-2565) makes raw memory
# an artifact users hand to strangers, at a volume where hand-review is fiction.
#
# IT DETECTS CATEGORIES, NOT KNOWN VALUES. The repo-scoped pre-push guard
# (DIVE-1774) hashes a curated denylist — correct for its job and zero false
# positives — but it only ever sees the value it was told about. Agent memory is
# written at RUNTIME by an agent recording the operational specifics of a real
# deployment, so the leaky value is by definition the one nobody enrolled. Each
# rule below therefore describes a SHAPE of operational fact, and the identity
# roster is derived from the box at scan time rather than maintained by hand.
#
# IT NEVER REDACTS. A silent scrub teaches the operator their memory exported
# clean when it did not; every hit is refused with file, line and category so the
# human distills that fact — states the LESSON without the host/name/id.

# Names this deployment knows: agent accounts on the box + the registry. DERIVED,
# so it covers whoever exists HERE rather than a list someone must remember to
# update. Empty is a legitimate answer (no agents) — the pattern rules still run.
# Roster entries that are ORDINARY ENGLISH or a generic role noun are dropped.
# Measured, not guessed: with them in, all five published character-packs failed
# this gate, on lines like "commit to main" and "Creative lessons distilled" —
# a gate that red-flags every honest pack is a gate somebody turns off.
# The cost is a real blind spot (an agent literally named 'main' goes unnamed),
# and it is the SAFE direction to be wrong in: this list can only make the scan
# quieter about generic words, never about a specific one, and such a fact almost
# always carries a path, host or task id on the same line anyway.
_PACK_LEAK_GENERIC='main|dev|ops|admin|root|test|demo|prod|staging|sandbox|agent|user|team|lead|bot|api|app|web|data|core|base|node|host|code|claude|marketing|creative|design|sales|support|product|research|engineering|finance|legal|security|growth|docs|infra|platform|mobile|council|blog|api'

_pack_leak_roster_raw() {
  { ls -1 /home 2>/dev/null | sed -n 's/^agent-//p'
    registry_read 2>/dev/null | jq -r '.agents | keys[]' 2>/dev/null
  } | tr 'A-Z' 'a-z' | grep -xE '[a-z][a-z0-9_-]{2,}' 2>/dev/null | sort -u || true
}

# Names that are unambiguous: a hit anywhere in the text is a hit.
_pack_leak_roster() { _pack_leak_roster_raw | grep -xvE "$_PACK_LEAK_GENERIC" || true; }

# Names that collide with ordinary English. Dropping them outright left a hole
# olivia named at review: an agent literally called 'main' would never be caught.
# They are not dropped — they are held to a NARROWER rule, and fire only where the
# word is used as an ACTOR ("hand it back to main"), never as a noun ("commit to
# main"). The discriminator is the verb in front, which is what distinguishes a
# person from a branch; a stop-list alone cannot see that difference.
_pack_leak_roster_generic() { _pack_leak_roster_raw | grep -xE "$_PACK_LEAK_GENERIC" || true; }

# Verbs and role labels that take a PERSON as their object. Deliberately excludes
# bare prepositions ("to", "from"): "commit to main" and "rebased from main" are
# the exact false positives that made the first cut unusable.
_PACK_LEAK_ACTOR_CUE='(ask|asked|ping|pinged|tell|told|dm|dmed|notify|notified|escalate|escalated|delegate|delegated|route|routed|reassign|assign|assigned|hand|handed|handoff|reviewer|verifier|maker|assignee|owner|owned|cc)'

# Values that are reserved-fake BY CONVENTION (CLAUDE.md) or unroutable by RFC,
# plus public standards ids. Anchored to the match, which is what `grep -o` emits.
# The optional `(.* )?` prefix matters: a keyword-anchored rule captures its
# keyword too ("chat_id 1234567890"), so anchoring the exemption to the START of
# the match would let a reserved placeholder trip the gate wherever a rule
# happened to swallow the words in front of it.
_PACK_LEAK_EXEMPT_RE=': (.* )?((1234567890)'
_PACK_LEAK_EXEMPT_RE+='|([A-Za-z0-9._%+-]+@example\.(com|org|net))'
_PACK_LEAK_EXEMPT_RE+='|(([A-Za-z0-9-]+\.)*example\.(com|org|net))|(localhost)'
_PACK_LEAK_EXEMPT_RE+='|(192\.0\.2\.[0-9]{1,3})|(198\.51\.100\.[0-9]{1,3})|(203\.0\.113\.[0-9]{1,3})'
_PACK_LEAK_EXEMPT_RE+='|(127\.[0-9.]+)|(10\.[0-9.]+)|(192\.168\.[0-9.]+)|(172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+)'
_PACK_LEAK_EXEMPT_RE+='|(0\.0\.0\.0)|(20[0-9]{6})'
_PACK_LEAK_EXEMPT_RE+='|((RFC|SHA|SHA256|ISO|UTF|AES|RSA|SSH|TLS|HTTP|HTTPS|IPV|UTC|CVE|MD|UUID|OAUTH|ASCII|PBKDF2|BASE)-[0-9]+))$'

# Two name-shaped false positives, both measured against the published packs:
#   - a roster name inside a contraction. "don" is an agent here AND the stem of
#     "don't", so the roster fired on ordinary prose. The rule captures the
#     apostrophe tail so the whole contraction is the match and is dropped here —
#     which keeps "ask don to review" a hit, where stop-listing the name would not.
#   - agent-<participle>. "an agent-relayed approval" is a compound adjective, not
#     an account; the suffix, not a word list, is what tells them apart.
_PACK_LEAK_NAME_EXEMPT_RE=": identity-name: ([^ ]*'[a-z]{1,3}|agent-[a-z]+(ed|ing|ly|able|ible|less|wide|based|driven|facing))$"

# Scan a memory dir for the categories a published pack must not carry.
# Prints "<file>:<line>: <category>: <match>" per hit to stderr; 0 clean, 1 hits.
# <dir> [self-name]. The EXPORTING agent's own name is not a leak in its own pack
# — the pack is published under it — so it is dropped from the roster. Measured:
# the shipped 'don' pack opens "# Don — seed memory", and a gate that refuses a
# persona for being itself is one nobody can satisfy.
_pack_memory_leakscan() {
  local dir="$1" self="${2:-}"
  [[ -d "$dir" ]] || return 0
  local roster roster_alt="" gen gen_alt="" found
  roster=$(_pack_leak_roster | grep -xv "${self:-__no_self__}" | paste -sd'|' - 2>/dev/null || true)
  [[ -n "$roster" ]] && roster_alt="|\\b(${roster})\\b"
  gen=$(_pack_leak_roster_generic | grep -xv "${self:-__no_self__}" | paste -sd'|' - 2>/dev/null || true)
  # {0,24}: an actor cue and its object sit in the same clause. Wider, and "ask
  # olivia whether the deploy to main is safe" reads 'main' as the person asked.
  [[ -n "$gen" ]] && gen_alt="|\\b${_PACK_LEAK_ACTOR_CUE}\\b[^.!?]{0,24}\\b(${gen})\\b"

  # <category> <case-insensitive:0|1> <ERE>. Categories are exactly the ones the
  # row enumerates, so a reviewer can map a hit back to the reason it is a leak.
  local rules=(
    "host-path|0|(/home/[A-Za-z0-9._-]+|/root\\b|/Users/[A-Za-z0-9._-]+|/srv/[A-Za-z0-9._-]+)"
    "identity-name|1|(\\bagent-[a-z][a-z0-9_-]*\\b|@[A-Za-z0-9_]{2,}bot\\b|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}${roster_alt})('[a-z]{1,3})?${gen_alt}"
    "hostname|1|(\\b[a-z0-9][a-z0-9-]*(\\.[a-z0-9-]+)*\\.(com|ai|io|net|org|dev|sh|app|cloud|xyz|de|co)\\b|\\b([0-9]{1,3}\\.){3}[0-9]{1,3}\\b)"
    "task-id|0|\\b[A-Z][A-Z0-9]{1,9}-[0-9]{2,6}\\b"
    "repo-name|1|((git@|https?://)?(github|gitlab|bitbucket)\\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|\\brepos?(itory)?[: ]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"
    "chat-id|1|((chat|message|msg|user|thread|group|telegram|discord)[ _-]?id[ =:#]+[0-9]+|\\b[0-9]{7,19}\\b)"
    "sudo-posture|1|(\\b(sudo|nopasswd|sudoers|visudo|setuid|euid|uid=0|passwordless root)\\b|root@)"
    "credential-location|1|(\\b(id_ed25519|id_rsa|\\.netrc|credentials\\.json|secrets?\\.(json|ya?ml|env|txt)|bot_token|api_key|keychain)\\b|\\.ssh/|\\.env\\b|auth[ _-]?profile|token (lives|is stored|sits))"
  )

  found=$(
    local rule ctg ci re raw
    for rule in "${rules[@]}"; do
      ctg="${rule%%|*}"; rule="${rule#*|}"
      ci="${rule%%|*}";  re="${rule#*|}"
      if [[ "$ci" == "1" ]]; then raw=$(grep -rInioE "$re" "$dir" 2>/dev/null || true)
      else                        raw=$(grep -rInoE  "$re" "$dir" 2>/dev/null || true); fi
      [[ -n "$raw" ]] || continue
      # grep -o emits "<path>:<line>:<match>"; a match may itself contain colons,
      # so take the first two fields and treat the whole remainder as the match.
      printf '%s\n' "$raw" | awk -F: -v c="$ctg" -v d="$dir/" '
        { f=$1; l=$2; sub(/^[^:]*:[^:]*:/, "");
          sub("^" d, "", f); printf "%s:%s: %s: %s\n", f, l, c, $0 }'
    # Dedupe on the WHOLE finding, then sort STABLY by file+line. `sort -u` with a
    # field key would have deduped on <file>:<line> alone and silently dropped the
    # second category on a line that leaks two things — which is the common case
    # (a repo URL is also a hostname), so the report would under-name the work.
    done | grep -vE "$_PACK_LEAK_EXEMPT_RE" | grep -vE "$_PACK_LEAK_NAME_EXEMPT_RE" \
         | awk '!seen[$0]++' | sort -t: -k1,1 -k2,2n -s
  ) || found=""

  [[ -n "$found" ]] || return 0
  printf '%s\n' "$found" >&2
  return 1
}

# Two audiences (DIVE-2565). A self-backup or clone-on-my-own-box never crosses
# the operator's trust boundary, so no scan is required; anything that may be
# PUBLISHED is scanned and fails closed. The CLI cannot know where a tarball
# ends up, so PUBLISH is the default and --audience=self is the explicit opt-out.
_pack_memory_publish_gate() {
  local audience="$1" dir="$2" self="${3:-}"
  if [[ "$audience" == "self" ]]; then
    warn "audience=self — memory leak-check SKIPPED. This pack is for YOUR OWN backup/clone; do not publish it or hand it to anyone else."
    return 0
  fi
  _pack_memory_leakscan "$dir" "$self"
}

# Locate an agent's persona-memory dir. Memory is keyed by project slug
# (~/.claude/projects/<slug>/memory/); a customer agent normally has one. If
# several exist we take the largest (the agent's primary working project).
_pack_memory_dir() {
  local name="$1"
  local base="/home/agent-${name}/.claude/projects"   # separate stmt: ${name} aborts under set -u if same line
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

# -------- DIVE-2565: single-file agent export/import (AGENTS.md) -----------
#
# A tarball pack is a fine ARCHIVE and a poor ARTEFACT: you cannot read it, diff
# it, paste it into a chat, or hand it to a harness that has never heard of
# 5dive. This renders the very same staged pack as ONE markdown file that IS an
# AGENTS.md — YAML frontmatter carrying the agent spec, the persona doc as the
# body, and (opt-in) memory as fenced `## memory/<file>` sections.
#
# ONE RENDERER, NOT ONE ADAPTER PER HARNESS. Nothing in the format is
# Claude-specific: `type` is a field, and memory is plain markdown that needs no
# porting at all. `AGENTS.md -> CLAUDE.md` is already the convention, so codex or
# opencode reads the export as-is with no 5dive installed — the file degrades
# into something useful instead of a dead archive.
#
# SECURITY — this path invents NO new policy. It renders the stage cmd_export
# already built, so it inherits, unchanged: the deny-by-default {reference,
# project}-only memory scoping, the mandatory two-phase approve gate, and the
# secret tripwire (which runs over the whole stage BEFORE we render). Two things
# are deliberately NOT carried, and the file SAYS SO rather than dropping them
# silently:
#   - hooks: arbitrary shell auto-run on tool events. A pasteable single file is
#     the worst possible carrier for it, and import already strips hooks by
#     default anyway (DIVE-995), so carrying them would only ever be a trap.
#   - skill BODIES: names travel as refs (exactly as the tarball manifest does).
#     Inlining bodies would balloon a file whose whole value is being
#     human-sized, and every harness still gets the NAMES — visible in the
#     frontmatter, restated in a `## Skills` section, and warned about by name on
#     import. DIVE-2583: that is a claim about THIS CONTAINER only. It says
#     nothing about where import puts a body it CAN resolve — that answer is
#     skills_install_dir(<type>) and it is non-empty for every type.
AGENTS_MD_FORMAT_VERSION=1

# Sentinels are HTML comments: invisible in every markdown renderer, ignored by
# any harness reading the file as instructions, and exact for the parser — which
# is what lets the persona body stay UNFENCED (codex must read it verbatim)
# without its own `##` headings colliding with our section headings.
AGENTS_MD_S_SKILLS='<!-- 5dive:skills -->'
AGENTS_MD_S_MEMORY='<!-- 5dive:memory -->'

# Longest tilde-fence in <file>, so we can open a longer one and contain content
# that itself contains fences (memory facts routinely hold ``` code blocks).
_agents_md_fence() {
  local f="$1" n
  n=$(grep -oE '^~{3,}' "$f" 2>/dev/null | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }') || n=0
  (( n < 5 )) && n=5
  printf '%*s\n' "$((n + 1))" '' | tr ' ' '~'
}

# Render a staged pack (the dir cmd_export builds) as one AGENTS.md on stdout.
_agents_md_render() {
  local stage="$1"
  local mf="$stage/manifest.json"   # separate stmt: ${stage} aborts under set -u if same line
  [[ -f "$mf" ]] || return 1

  # Frontmatter. Every scalar goes through jq's @json: a JSON string is a valid
  # YAML 1.2 double-quoted scalar, so this is exact quoting with no YAML emitter
  # dependency — and it round-trips through `fromjson` on the parse side.
  local hasav=false
  [[ -f "$stage/avatar.png" ]] && hasav=true
  jq -r --argjson amf "$AGENTS_MD_FORMAT_VERSION" --argjson hasav "$hasav" '
    def s: if . == null or . == "" then "null" else (. | tostring | @json) end;
    [ "---",
      "agentsMdFormat: \($amf)",
      "packFormat: \(.packFormat)",
      "name: \(.agentName | s)",
      "type: \(.config.type | s)",
      "model: \(.config.model | s)",
      "effort: \(.config.effort | s)",
      "isolation: \(.config.isolation | s)",
      "channels: \(.config.channels | s)",
      "workdir: \(.config.workdir | s)",
      "createdWith: \(.createdWith | s)",
      "includesMemory: \(.includes.memory | if . == false then "false" else (. | @json) end)",
      "hooks: dropped   # never carried by a single-file export (see Skills note)",
      # The avatar is a PNG. A file whose whole value is being human-sized and
      # pasteable cannot carry it, and base64 would defeat the point — but a
      # QUIET drop is precisely the failure mode this format exists to avoid, so
      # the absence is declared. Export --format=pack keeps the real avatar.png.
      "avatar: \(if $hasav then "dropped   # binary; use --format=pack to carry avatar.png" else "none" end)"
    ]
    + (if ((.skills // []) | length) == 0 then ["skills: []"]
       else ["skills:"] + ((.skills // []) | map("  - " + @json)) end)
    + ["plugins: " + ((.plugins // []) | tojson), "---", ""]
    | .[]' "$mf" || return 1

  # Persona doc — verbatim and unfenced: this IS the AGENTS.md body a foreign
  # harness reads as its instructions.
  if [[ -f "$stage/CLAUDE.md" ]]; then
    cat "$stage/CLAUDE.md"
  else
    printf '# %s\n\n(no persona document in this export)\n' "$(jq -r '.agentName // "agent"' "$mf")"
  fi
  printf '\n'

  # Skills: names, never bodies — and say so, PER DIRECTION (DIVE-2583). One
  # sentence used to fuse two different mechanisms and got the joint wrong:
  #   - EXPORT (this file): carries refs, not bodies. True for EVERY harness.
  #   - the parenthetical "(codex, opencode)" have no skills directory: false
  #     about all of them. SKILLS_INSTALL_DIR maps every known type and unmapped
  #     types fall back, so the category the sentence named is empty.
  #   - IMPORT: _install_bundled_skill is NOT type-gated and cmd_skill_add resolves
  #     the same map, so a codex seat that imports DOES get bodies under $HOME.
  #     Telling that reader "NONE are installed" is the permissive, dangerous half.
  # So: name the direction, and take the destination from skills_install_dir —
  # the resolver the installer itself calls — instead of restating a type list.
  local nskills; nskills=$(jq -r '(.skills // []) | length' "$mf")
  if (( nskills > 0 )); then
    local sk_type sk_dir
    sk_type=$(jq -r '.config.type // "claude"' "$mf")
    sk_dir=$(skills_install_dir "$sk_type")
    printf '%s\n' "$AGENTS_MD_S_SKILLS"
    printf '## Skills\n\n'
    printf 'This agent expects the skills below. THIS FILE carries their NAMES, not\n'
    printf 'their bodies — the same refs the tarball pack records — so the file on its\n'
    printf 'own installs nothing, on any harness.\n\n'
    printf 'Importing it is the other direction. `5dive agent import` re-resolves each\n'
    printf 'name from its source repo, installs the ones it can and reports by name the\n'
    printf 'ones it could not; on a `%s` seat an installed body lands in\n' "$sk_type"
    printf '`~/%s/<skill>/`. Whether %s then LOADS that directory is the\n' "$sk_dir" "$sk_type"
    printf "harness's own behaviour and 5dive does not verify it — so treat this list as\n"
    printf 'the capabilities the agent was written to assume, not as proof it has them.\n\n'
    jq -r '(.skills // [])[] | "- `" + . + "`"' "$mf"
    printf '\n'
  fi

  # Memory: fenced, one section per fact, opt-in and already scoped upstream.
  _agents_md_render_memory "$stage"
}

# The memory half of the render, extracted VERBATIM so cmd_import can reuse it
# (DIVE-2568). Emits nothing when the stage carries no facts, so callers can call
# it unconditionally. tests/pack_agents_md_unit.sh grades the export format and is
# the check that this extraction changed no output — mutation-confirmed: breaking
# the delegation below reds 3 of its arms.
_agents_md_render_memory() {
  local stage="$1"
  [[ -d "$stage/memory" ]] || return 0
  find "$stage/memory" -maxdepth 1 -name '*.md' 2>/dev/null | grep -q . || return 0
  printf '%s\n' "$AGENTS_MD_S_MEMORY"
  printf '# Memory\n\n'
  printf 'Distilled persona memory, one fact per section. `5dive agent import`\n'
  printf 'writes each back to `memory/<file>`; any other harness just reads them.\n\n'
  local f base fence
  while IFS= read -r f; do
    base=$(basename "$f")
    fence=$(_agents_md_fence "$f")
    printf '<!-- 5dive:memory-file: %s -->\n' "$base"
    printf '## memory/%s\n\n' "$base"
    printf '%s\n' "$fence"
    cat "$f"
    # A fact not ending in a newline would swallow the closing fence.
    [[ -n "$(tail -c1 "$f")" ]] && printf '\n'
    printf '%s\n\n' "$fence"
  done < <(find "$stage/memory" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
  return 0
}

# DIVE-2568 — MEMORY HAS TO BE IN EFFECT, NOT MERELY PRESENT.
#
# The row's acceptance criterion is that a pack hired onto a codex or opencode
# seat comes up with the persona AND any distilled memory in effect. cmd_import
# seeds facts to ~/.claude/projects/<slug>/memory — 5dive's own store, which
# `5dive memory search` reads for ANY agent, so the facts are reachable. They are
# not LOADED, though: it is the Claude Code harness that auto-injects that store's
# index each session. A codex seat reads .codex/AGENTS.md and nothing else, so on
# a foreign harness the memory would sit one command away from an agent with no
# reason to run it — present, and not in effect. Same shape as the settings.json
# drop, one layer up.
#
# This is what the DIVE-2565 renderer is FOR, applied to the import direction
# rather than the export one: inline the facts into the instruction file the
# target harness actually reads, using the same fenced sections and sentinels the
# single-file export emits. Claude is deliberately excluded — there the store IS
# auto-loaded, and duplicating every fact into CLAUDE.md would double the system
# prompt to fix a problem that harness does not have.
#
# Rewrites $stage/CLAUDE.md IN PLACE, before persona_install_doc routes it to the
# harness's own path. Returns 0 when it inlined, 1 when it did not (either not
# wanted, or it failed and said so) — so the caller reports the mechanism rather
# than inferring it. A separate function because the alternative is a branch
# inside cmd_import that only a live root import can reach: an assertion on its
# warn STRING grades the rendering, not the condition, and stays green on a
# branch that never runs.
_pack_inline_memory_into_doc() {   # _pack_inline_memory_into_doc <stage> <type> <mem_inc>
  local stage="${1:-}" type="${2:-}" mem_inc="${3:-}"
  local doc="$stage/CLAUDE.md"
  [[ -f "$doc" ]] || return 1
  [[ "$type" != "claude" && "$mem_inc" == "distilled" ]] || return 1
  [[ -d "$stage/memory" ]] || return 1
  find "$stage/memory" -maxdepth 1 -name '*.md' 2>/dev/null | grep -q . || return 1
  local inl="$doc.inline.$$" n
  n=$(find "$stage/memory" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
  if { cat "$doc"; printf '\n'; _agents_md_render_memory "$stage"; } > "$inl" 2>/dev/null \
     && [[ -s "$inl" ]]; then
    mv "$inl" "$doc"
    step "Inlined $n distilled memory fact(s) into the persona doc — a '$type' seat does not auto-load 5dive's memory store"
    return 0
  fi
  rm -f "$inl"
  # NEVER a silent failure: the facts are still seeded and searchable, but this
  # harness will not load them, and that difference is the whole point of the row.
  warn "could not inline distilled memory into the persona doc for this '$type' seat — the facts are still seeded and reachable via '5dive memory search', but this harness will not load them automatically"
  return 1
}

# Is <file> a 5dive single-file agent export? Anchored on the frontmatter key we
# emit, so a persona.yaml or a plain hand-written AGENTS.md never misfires.
_agents_md_is() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  [[ "$(head -c3 "$f" 2>/dev/null)" == "---" ]] || return 1
  awk 'NR==1 && $0 != "---" { exit 1 }
       NR>1 && /^---[[:space:]]*$/ { exit 1 }
       NR>1 && /^agentsMdFormat:[[:space:]]*[0-9]+[[:space:]]*$/ { exit 0 }
       NR>200 { exit 1 }' "$f"
}

# Explode a single-file export back into a pack STAGE at <outdir>: manifest.json,
# CLAUDE.md, memory/*.md. Deliberately reconstructs a v1 pack rather than a
# second import path, so everything downstream in cmd_import is untouched.
_agents_md_explode() {
  local file="$1" outdir="$2"
  _agents_md_is "$file" || return 1
  mkdir -p "$outdir" || return 1

  # --- frontmatter -> manifest.json
  local fm; fm=$(mktemp)
  awk 'NR==1 { next } /^---[[:space:]]*$/ { exit } { print }' "$file" > "$fm"

  local amf; amf=$(awk -F': *' '/^agentsMdFormat:/ { print $2; exit }' "$fm" | tr -d '[:space:]')
  [[ "$amf" =~ ^[0-9]+$ ]] || { rm -f "$fm"; return 1; }
  (( amf <= AGENTS_MD_FORMAT_VERSION )) || { rm -f "$fm"; return 1; }

  # Scalars were emitted as JSON, so `fromjson` unquotes exactly; a human who
  # hand-edited the file into a bare word still parses via the `// .` fallback.
  _amd_get() {
    awk -v k="$1" 'index($0, k ": ") == 1 { sub("^" k ": ", ""); sub(/[[:space:]]+#.*$/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$fm" \
      | jq -r 'fromjson? // .' 2>/dev/null
  }
  local pf name type model effort iso channels workdir cwith meminc
  pf=$(_amd_get packFormat);   [[ "$pf" =~ ^[0-9]+$ ]] || pf=1
  name=$(_amd_get name); type=$(_amd_get type); model=$(_amd_get model)
  effort=$(_amd_get effort); iso=$(_amd_get isolation); channels=$(_amd_get channels)
  workdir=$(_amd_get workdir); cwith=$(_amd_get createdWith); meminc=$(_amd_get includesMemory)
  local v; for v in name type model effort iso channels workdir cwith meminc; do
    [[ "${!v}" == "null" ]] && printf -v "$v" '%s' ''
  done
  [[ -n "$name" && -n "$type" ]] || { rm -f "$fm"; unset -f _amd_get; return 1; }

  # skills: block list OR inline `[]`.
  local skills
  skills=$(awk '/^skills:[[:space:]]*\[\][[:space:]]*$/ { exit }
                /^skills:[[:space:]]*$/ { inl = 1; next }
                inl && /^  - / { sub(/^  - /, ""); print; next }
                inl { exit }' "$fm" | jq -Rc 'fromjson? // .' 2>/dev/null | jq -cs '.' 2>/dev/null)
  [[ -n "$skills" ]] || skills='[]'
  local plugins
  plugins=$(awk 'index($0, "plugins: ") == 1 { sub(/^plugins: /, ""); print; exit }' "$fm")
  # settings.json's enabledPlugins is an OBJECT map in the field
  # ({"telegram@5dive-plugins":true}), not an array — an array-only check here
  # silently DROPPED every real agent's plugins on round-trip. Accept either;
  # cmd_import's `($plugins|length) > 0` works for both.
  jq -e 'type == "array" or type == "object"' <<<"$plugins" >/dev/null 2>&1 || plugins='[]'
  rm -f "$fm"; unset -f _amd_get

  # A single-file export never carries hooks (see the header) — reconstruct an
  # EMPTY hooks block rather than omitting the key, so the manifest stays v1-shaped.
  jq -n --argjson fmt "$pf" --arg name "$name" --arg ver "$cwith" \
        --arg type "$type" --arg iso "$iso" --arg ch "$channels" --arg wd "$workdir" \
        --arg model "$model" --arg effort "$effort" --arg mem "$meminc" \
        --argjson skills "$skills" --argjson plugins "$plugins" '
    def n: if . == "" then null else . end;
    { packFormat: $fmt, agentName: $name, createdWith: $ver,
      includes: { memory: (if $mem == "" or $mem == "false" then false else $mem end), persona: false },
      config: { type: $type, isolation: ($iso | n), channels: (if $ch == "" then "none" else $ch end),
                workdir: ($wd | n), authProfile: null, model: ($model | n), effort: ($effort | n) },
      plugins: $plugins, skills: $skills, hooks: {} }' > "$outdir/manifest.json" || return 1

  # --- persona body: everything between the frontmatter and the first sentinel.
  awk -v sk="$AGENTS_MD_S_SKILLS" -v me="$AGENTS_MD_S_MEMORY" '
    NR == 1 { next }
    !seen && /^---[[:space:]]*$/ { seen = 1; next }
    !seen { next }
    $0 == sk || $0 == me { exit }
    # Drop the blank line the renderer puts after the closing "---" (and any
    # others), so render->explode->render is byte-stable on the persona doc.
    !started && /^[[:space:]]*$/ { next }
    { started = 1; print }' "$file" > "$outdir/CLAUDE.md"
  # Trim the blank lines the renderer padded with, so a render->parse->render
  # round-trip is byte-stable.
  awk 'BEGIN { RS = "\0" } { sub(/\n+$/, "\n"); printf "%s", $0 }' "$outdir/CLAUDE.md" > "$outdir/.cm" \
    && mv "$outdir/.cm" "$outdir/CLAUDE.md"
  [[ -s "$outdir/CLAUDE.md" ]] || rm -f "$outdir/CLAUDE.md"

  # --- memory sections. The filename comes off the sentinel and is validated
  # here: it becomes a path, and this file may have crossed a trust boundary.
  if grep -qxF "$AGENTS_MD_S_MEMORY" "$file"; then
    mkdir -p "$outdir/memory"
    awk -v me="$AGENTS_MD_S_MEMORY" -v dir="$outdir/memory" '
      $0 == me { inmem = 1; next }
      !inmem { next }
      /^<!-- 5dive:memory-file: .* -->$/ {
        f = $0; sub(/^<!-- 5dive:memory-file: /, "", f); sub(/ -->$/, "", f)
        # Reject anything that is not a plain <name>.md — no traversal, no path.
        if (f !~ /^[A-Za-z0-9._-]+\.md$/ || f ~ /^\.\.?$/ || index(f, "..") > 0) { cur = ""; next }
        cur = dir "/" f; printf "" > cur; body = 0; fence = ""; next
      }
      cur == "" { next }
      fence == "" && /^~{3,}[[:space:]]*$/ { fence = $0; sub(/[[:space:]]+$/, "", fence); body = 1; next }
      body && $0 == fence { cur = ""; fence = ""; body = 0; next }
      body { print >> cur }' "$file"
    find "$outdir/memory" -maxdepth 1 -name '*.md' 2>/dev/null | grep -q . || rm -rf "$outdir/memory"
  fi
  return 0
}

# Explode + re-tar into a v1 pack tarball; echoes the path. cmd_import then runs
# its existing safe-extract / manifest-validation / disclosure path over it, so a
# single-file import is graded by exactly the same gates as a tarball import.
_agents_md_to_pack() {
  local file="$1" stage tgz
  stage=$(mktemp -d) || return 1
  if ! _agents_md_explode "$file" "$stage"; then rm -rf "$stage"; return 1; fi
  tgz=$(mktemp -u /tmp/5dive-agentsmd-XXXXXX.tar.gz)
  if ! tar -czf "$tgz" -C "$stage" . 2>/dev/null; then rm -rf "$stage" "$tgz"; return 1; fi
  rm -rf "$stage"
  printf '%s\n' "$tgz"
}

cmd_export() {
  require_root
  local name="" with_memory=0 out="" approve_memory="" format="pack" audience="publish"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-memory)      with_memory=1 ;;
      --approve-memory=*) approve_memory="${1#--approve-memory=}"; with_memory=1 ;;
      --audience=*)       audience="${1#--audience=}" ;;
      --out=*)            out="${1#--out=}" ;;
      # DIVE-2565: -o is the spelling the single-file flow is documented with.
      -o)                 shift; [[ $# -gt 0 ]] || fail "$E_USAGE" "-o needs a path"; out="$1" ;;
      --format=*)         format="${1#--format=}" ;;
      -*)                 fail "$E_USAGE" "unknown flag: $1" ;;
      *)                  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent export <name> [--format=pack|agents-md] [--with-memory] [--approve-memory=<dir>] [--audience=publish|self] [-o <path>]"
  case "$format" in
    pack|agents-md) ;;
    *) fail "$E_USAGE" "unknown --format '$format' (known: pack, agents-md)" ;;
  esac
  # DIVE-2567: default is the STRICT audience. An operator who wants the scan off
  # has to say which audience they are exporting for; a typo is not a bypass.
  [[ "$audience" == "publish" || "$audience" == "self" ]] \
    || fail "$E_USAGE" "--audience must be 'publish' (default, memory leak-check enforced) or 'self' (own backup/clone, leak-check skipped; the secret tripwire still runs)"
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
        fail "$E_GENERIC" "nothing shareable: 0 reference/project knowledge facts ($excluded private user/feedback or opted-out facts excluded). Only metadata.type 'reference' or 'project' facts are eligible — 'user' and 'feedback' are private by definition and never exported. This agent has none of the former, so there is nothing to distil; write the shareable knowledge as reference/project facts first. Nothing written."
      fi
      if ! _pack_secret_tripwire "$draft"; then
        rm -rf "$draft"
        # DIVE-2679: name the ONE wrong turn this refusal invites. The reporter's next
        # move was --audience=self, because the usage text presents it as the escape
        # hatch; it is not one, and finding that out by re-running is a wasted cycle.
        fail "$E_GENERIC" "a scoped fact tripped the secret tripwire (file:line: rule above) — refusing. Remove the credential from that fact, or tag the fact 'private: true' to exclude it, then retry. NOTE: --audience=self does NOT bypass this — it only skips the operational-detail leak-check; a real token never leaves in either audience."
      fi
      # DIVE-2567: the draft exists to be REVIEWED, so here the leak-check REPORTS
      # rather than refuses — refusing to write the draft would leave the human
      # nothing to edit. The refusal is at seal time, over the same scan.
      local leaky=0
      if [[ "$audience" != "self" ]] && ! _pack_memory_leakscan "$draft" "$name"; then
        leaky=1
        warn "the lines above (file:line:category) carry operational detail a PUBLISHED pack must not: distill each one — state the LESSON without the host, name, id or path — or delete it. Sealing REFUSES while any remain (--audience=self exports it unscanned for your own backup)."
      fi
      chown -R "agent-${name}:agent-${name}" "/home/agent-${name}/.claude/pack-staging" 2>/dev/null || true
      ok "memory DRAFT ready for review — kept $kept knowledge fact(s), excluded $excluded private/opted-out (deny-by-default). REVIEW + EDIT: $draft — then SEAL: 5dive agent export $name --approve-memory=$draft. Nothing is packed until you approve." \
         '{name:$n, phase:"draft", draft:$d, kept:$k, excluded:$e, leakCheck:(if $lk==1 then "hits" elif $a=="self" then "skipped" else "clean" end)}' \
         --arg n "$name" --arg d "$draft" --argjson k "$kept" --argjson e "$excluded" \
         --argjson lk "$leaky" --arg a "$audience"
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
        fail "$E_GENERIC" "approved memory tripped the secret tripwire (file:line: rule above) — refusing to seal. Remove the credential from that fact, or tag it 'private: true', then retry. --audience=self does NOT bypass this (it only skips the operational-detail leak-check)."
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
  # Skills as source refs (reuse the skills spec; import re-adds them).
  #
  # DIVE-2678: this used to emit the skills DIRECTORY NAMES and nothing else, which
  # throws away the one fact import needs. A bare name is re-resolved by
  # parse_skill_spec against `<org>/skills` and NOWHERE else, so every skill that came
  # from any other repo became unresolvable the moment it was exported — the importer
  # then correctly, and silently-by-design, skipped it. Measured on two fresh seats:
  # 4 of 22 installed, the other 18 all third-party (none of them exist in
  # 5dive-ai/skills, verified by fetch). The skill's origin is not lost data: the
  # per-agent `.skills-manifest.json` already records the source cmd_skill_add
  # resolved it from. Carry it as the qualified `<owner/repo>:<id>` form whenever it
  # is NOT the default repo, and keep the short bare form when it is — so an
  # AGENTS.md stays readable and the common case is unchanged.
  local skills; skills=$(_pack_skill_refs "$cdir/skills")
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

  # DIVE-2567: memory CONTENT gate — ONE enforcement point, over the same staged
  # bytes both containers are built from, placed BEFORE the format branch below.
  # After DIVE-2565 memory can leave the box by two routes (the .tar.gz and the
  # single-file AGENTS.md); gating the stage rather than either writer is what
  # makes that two-and-only-two count irrelevant, and covers the third route the
  # next format adds. Fails closed for the publish audience.
  if [[ -d "$stage/memory" ]] && ! _pack_memory_publish_gate "$audience" "$stage/memory" "$name"; then
    rm -rf "$stage" "$mem_tmp"
    fail "$E_GENERIC" "refusing to export: staged memory carries operational detail a published pack must not (file:line:category above — host paths, agent/human names, hostnames, task ids, repo names, chat ids, sudo posture, credential locations). Distill those facts — the LESSON without the specifics — and retry; or, for YOUR OWN backup/clone only, re-run with --audience=self. Nothing was written and nothing was silently redacted."
  fi

  # DIVE-2565: same stage, different container. Renders AFTER the tripwire above,
  # so the single-file export can never carry something the tarball would refuse.
  if [[ "$format" == "agents-md" ]]; then
    [[ -n "$out" ]] || out="/tmp/${name}-AGENTS.md"
    if ! _agents_md_render "$stage" > "$out"; then
      rm -f "$out"; rm -rf "$stage" "$mem_tmp"
      fail "$E_GENERIC" "failed to render the single-file export"
    fi
    chmod 644 "$out"
    local n_hooks; n_hooks=$(jq -r '(.hooks // {}) | length' "$stage/manifest.json" 2>/dev/null || echo 0)
    rm -rf "$stage"; [[ -n "$mem_tmp" ]] && rm -rf "$mem_tmp"
    (( has_avatar )) && warn "dropped the avatar (binary): a single-file export carries no image — use --format=pack to keep avatar.png"
    (( n_hooks > 0 )) && warn "dropped $n_hooks hook block(s): a single-file export never carries arbitrary shell (export --format=pack if you need them)"
    local skill_n; skill_n=$(jq -r 'length' <<<"$skills" 2>/dev/null || echo 0)
    # DIVE-2583: same correction as the rendered section — the FILE carries no
    # bodies (true everywhere); importing it still installs into the importing
    # seat's mapped skills dir, so do not tell the exporter that nothing lands
    # anywhere. No dir is named here on purpose: at export time we do not know
    # which type the file will be imported onto, and the old text's mistake was
    # exactly this kind of unearned specificity.
    (( skill_n > 0 )) && warn "skills travel as NAMES, not bodies ($skill_n listed in the file); the file says so. Importing it re-resolves each name from its source repo and installs what it can into the importing seat's skills dir — every harness has one"
    ok "exported '$name' as a single-file AGENTS.md (memory: $mem_inc) -> $out" \
       '{name:$n, file:$o, format:"agents-md", agentsMdFormat:$f, withMemory:($m != "false"), memory:$m, skills:$s, hooks:"dropped"}' \
       --arg n "$name" --arg o "$out" --argjson f "$AGENTS_MD_FORMAT_VERSION" --arg m "$mem_inc" --argjson s "$skills"
    return 0
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
  local report_import=0 import_slug="" allow_hooks=0
  # DIVE-658 #2: provision straight from an OpenAgent persona file. The persona
  # carries identity only; these flags supply the 5dive runtime config the pack
  # would otherwise hold (sane defaults; only consumed in --from-persona mode).
  # DIVE-1317: --type/--model/--effort must be honored for a PACK/marketplace
  # import too, not only --from-persona. Default p_type EMPTY so we can tell
  # "explicitly asked for <type>" apart from "took the pack's baked-in type";
  # the from-persona synth defaults it to claude locally below.
  local from_persona="" p_type="" p_iso="standard" p_model="" p_effort=""
  # DIVE-2676: BYO credentials on the import path. Without these an import onto
  # an API-key-only seat provisions an agent that cannot reach a model at all.
  local p_provider="" p_api_key=""
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
      --provider=*)        p_provider="${1#--provider=}" ;;
      --api-key=*)         p_api_key="${1#--api-key=}" ;;
      # DIVE-644: opt-in, default-OFF import telemetry. Only meaningful for a
      # registry-slug import (a local .tar.gz has no public slug to report).
      --report-import)     report_import=1 ;;
      # DIVE-995: hooks are arbitrary shell that auto-run on the new agent's tool
      # events (the agentjacking surface of third-party packs). Deny-by-default:
      # a pack's hooks are STRIPPED on import unless the importer opts in here.
      --allow-hooks)       allow_hooks=1 ;;
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
    local synth_type="${p_type:-claude}"
    step "Synthesizing pack from OpenAgent persona '$from_persona' (type=$synth_type)"
    persona_tmp=$(_persona_to_pack "$from_persona" "$synth_type" "$p_iso" "$p_model" "$p_effort") \
      || fail "$E_VALIDATION" "could not build a pack from persona '$from_persona' (is it a valid OpenAgent persona?)"
    pack="$persona_tmp"
  fi
  [[ -n "$pack" ]] || fail "$E_USAGE" "usage: 5dive agent import <pack>|--from-persona=<file.persona.yaml> --as=<name> [--type=claude] [--channels=...] [--telegram-token=...] [--discord-token=...] [--auth-profile=...] [--workdir=...]"

  # DIVE-2565: a single-file AGENTS.md export is a pack too. Explode it back into
  # a v1 stage and re-tar, so EVERYTHING below — safe-extract, manifest
  # validation, the DIVE-995 disclosure, hook stripping, memory seeding, skill
  # re-add — runs on the identical path. One import flow, not two.
  local md_tmp=""
  if [[ -f "$pack" ]] && _agents_md_is "$pack"; then
    step "Reading single-file agent export '$pack' (AGENTS.md)"
    md_tmp=$(_agents_md_to_pack "$pack") \
      || fail "$E_VALIDATION" "could not parse '$pack' as a 5dive single-file agent export"
    pack="$md_tmp"
  fi

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
  _pack_safe_extract "$pack" "$stage" || { local rc=$?; rm -rf "$stage" "$resolved_tmp" "$persona_tmp" "$md_tmp"
    (( rc == 2 )) && fail "$E_VALIDATION" "pack rejected: contains unsafe members (path traversal, absolute paths, or sym/hardlinks), refusing to extract"
    fail "$E_GENERIC" "could not read pack (expected a .tar.gz from 'agent export')"; }
  [[ -n "$resolved_tmp" ]] && rm -f "$resolved_tmp"
  [[ -n "$persona_tmp" ]] && rm -f "$persona_tmp"
  [[ -n "$md_tmp" ]] && rm -f "$md_tmp"
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
    local _srk=0; _persona_strip_signing_key "$stage/persona.yaml" "$signing_keyfile" || _srk=$?
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
  # DIVE-1317: explicit runtime flags override the pack's baked-in config so a
  # marketplace hire is harness-agnostic — `agent import <slug> --type=codex`
  # provisions a codex agent instead of silently taking the pack's claude type.
  # (from-persona already baked p_type into the manifest above, so p_type is
  # empty there and the manifest value stands.)
  [[ -n "$p_type" ]]   && type="$p_type"
  [[ -n "$p_model" ]]  && model="$p_model"
  [[ -n "$p_effort" ]] && effort="$p_effort"
  # DIVE-2303: resolve a family ALIAS to the full current id before it reaches
  # settings.json. A pack may legitimately carry model:"opus" — that is the whole
  # point, so a published character does not freeze on the id that was current the
  # day it was packed — but the value below is written RAW into a brand-new agent's
  # settings.json, and per src/lib/models.sh (DIVE-506/536) Claude Code >= 2.1.181
  # runs a startup migration that STRIPS a bare alias from a FRESH config dir. An
  # imported agent's config dir is always fresh, so without this the agent would
  # silently lose its pin on first boot and fall back to the runtime default —
  # while the manifest still read correctly, which is what makes it hard to see.
  # A full id passes through resolve_model_alias untouched, so this is a no-op for
  # packs that deliberately pin.
  [[ -n "$model" ]] && model=$(resolve_model_alias "$model")
  [[ -n "$type" ]] || { rm -rf "$stage"; fail "$E_VALIDATION" "manifest has no agent type"; }
  is_known_type "$type" || { rm -rf "$stage"; fail "$E_NOT_FOUND" "unknown --type '$type' (known: ${!TYPE_BIN[*]})"; }
  # DIVE-2568: a pack is target-agnostic, but "agnostic" is not "unbounded" — the
  # persona has to have somewhere to land. Refuse an unhostable target HERE,
  # before cmd_create makes a unix account, a home and a systemd unit for an
  # agent that would come up with none of the character it was hired for.
  # is_known_type is not enough on its own: hermes and openclaw pass it and have
  # no TYPE_PERSONA_FILE entry, so today they provision and then silently drop
  # the entire payload (persona_install_doc warns and returns 1, import carries
  # on and reports success).
  local -a _lands=(); mapfile -t _lands < <(_pack_harness_targets "$stage/manifest.json")
  if ! printf '%s\n' "${_lands[@]+"${_lands[@]}"}" | grep -qxF -- "$type"; then
    local _why="this CLI has no probe-verified persona path for a '$type' seat, so the pack's identity doc would never reach the model (DIVE-2223)"
    if _pack_targets_declared "$stage/manifest.json"; then
      _why="the pack narrows itself to: $(jq -r '(.config.targets // []) | join(", ")' "$stage/manifest.json")"
    fi
    rm -rf "$stage"
    fail "$E_VALIDATION" "this pack cannot be imported onto a '$type' agent — ${_why}. It lands on: ${_lands[*]:-(nothing on this box)}"
  fi
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
  #
  # DIVE-2676: ...unless the importer brought credentials. --defer-auth and
  # --provider/--api-key are mutually exclusive in cmd_create (BYO is the
  # ALTERNATIVE to signing in later), so the BYO branch must not add it. Going
  # through cmd_create rather than re-implementing here is the whole point: that
  # path already writes the connector key AND calls {pi,opencode}_apply_model_default,
  # which is the opencode.json model pin an import has never written.
  local byo=0
  if [[ -n "$p_provider" || -n "$p_api_key" ]]; then
    [[ -n "$p_provider" && -n "$p_api_key" ]] \
      || { rm -rf "$stage"; fail "$E_USAGE" "--provider and --api-key must be passed together"; }
    byo=1
  fi
  cargs+=("--auth-profile=$profile")
  if (( byo )); then
    cargs+=("--provider=$p_provider" "--api-key=$p_api_key")
    # Forward the model only when it can be MEANT for this seat: an explicit
    # --model=, or a claude seat where the pack's baked id is already native.
    # A pack's "claude-opus-5" is not a slug an openrouter-backed opencode seat
    # can resolve, and DIVE-1395 catalog validation hard-fails an unresolvable
    # one at create — so forwarding it blindly would turn a working import into
    # a failed one.
    if [[ -n "$model" ]] && { [[ -n "$p_model" ]] || [[ "$type" == "claude" ]]; }; then
      cargs+=("--model=$model")
    fi
  else
    cargs+=("--defer-auth")
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

  # DIVE-995: MANDATORY install-time disclosure — surface the pack's executable
  # surface (hooks/skills/plugins/prompt/signing-key) BEFORE we recreate anything,
  # so an import is never a silent grant of arbitrary capability.
  local disclosure; disclosure=$(_pack_disclosure_json "$stage" 2>/dev/null || echo '{}')
  local disc_hooks; disc_hooks=$(jq -r '.hooks.count // 0' <<<"$disclosure" 2>/dev/null || echo 0)
  # DIVE-1009: strip on a NON-EMPTY .hooks (not just command count) and cover
  # plugin-carried hooks — the top-level count alone under-reports the surface.
  local disc_hooks_nonempty; disc_hooks_nonempty=$(jq -r '.hooks.nonEmpty // false' <<<"$disclosure" 2>/dev/null || echo false)
  local disc_plugin_hooks;   disc_plugin_hooks=$(jq -r '.pluginHooks.present // false' <<<"$disclosure" 2>/dev/null || echo false)
  if ! (( JSON_MODE )); then
    _pack_disclosure_print "$disclosure"
  fi

  # Recreate via the canonical create path (its ok-envelope suppressed so import
  # emits a single envelope). The registry lock is reentrant, so this is safe.
  step "Recreating agent '$as' from pack (type=$type)"
  ( cmd_create "${cargs[@]}" ) >/dev/null \
    || { rm -rf "$stage"; fail "$E_GENERIC" "create step failed while importing '$as'"; }

  local cdir="/home/agent-${as}/.claude"

  # DIVE-2568: put distilled memory IN EFFECT for a harness that does not
  # auto-load 5dive's store. Must run BEFORE the install below, which routes this
  # same doc to the harness's own instruction path. See _pack_inline_memory_into_doc.
  local mem_effect="none"
  if _pack_inline_memory_into_doc "$stage" "$type" "$mem_inc"; then
    mem_effect="inlined into the persona doc"
  fi

  # Layer the identity doc into the file THIS harness actually reads (DIVE-2223).
  # persona.yaml / avatar.png / settings.json below stay under ~/.claude because
  # 5dive itself reads those; the persona DOC is the one that has to follow the
  # type, and on a codex seat it prepends above the DIVE-1410 return-channel doc.
  if [[ -f "$stage/CLAUDE.md" ]]; then
    persona_install_doc "$as" "$type" "$stage/CLAUDE.md" || true
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
  # DIVE-2568 — THE SILENT DROP THIS ROW EXISTS TO REMOVE. See _pack_unapplied_on
  # for the reasoning; the predicate lives there so it can be graded offline.
  local cross_dropped='[]'
  local _hp=0
  if (( disc_hooks > 0 )) || [[ "$disc_hooks_nonempty" == "true" || "$disc_plugin_hooks" == "true" ]]; then _hp=1; fi
  local -a _nc=()
  mapfile -t _nc < <(_pack_unapplied_on "$type" "$model" "$effort" "$_hp" "$stage/manifest.json")
  if (( ${#_nc[@]} > 0 )); then
    warn "NOT applied on this '$type' seat (settings.json is Claude Code's file): ${_nc[*]} — set these in the harness's own config; the persona, memory and skills DID land"
    cross_dropped=$(printf '%s\n' "${_nc[@]}" | jq -R . | jq -cs .)
  fi

  # DIVE-2676: the warn above is about KEYS. This one is about whether the agent
  # we just built can think at all, which is a different — and strictly worse —
  # outcome, and the one an import has been reporting as success. Measured
  # 2026-08-04: import OK, persona byte-identical at the seat's own AGENTS.md,
  # 'agent info' model: — (empty), every ask "no idle reply within 120s". Every
  # step passed and the end-to-end result still failed, so the summary has to
  # carry the end-to-end verdict, not the per-step one. --provider/--api-key
  # above is the fix; this is what the operator sees when they skipped it.
  #
  # The fix names a RE-IMPORT rather than a repair, because there is no repair.
  # `agent auth set $type --api-key=` can still deliver the credential, but the
  # model pin has no post-hoc verb at all: `agent config <name> set model=`
  # accepts claude/codex/grok/antigravity ONLY and hard-fails "type '$type' does
  # not support 'model' config" for exactly the seats this branch fires on
  # (write_runtime_model has no opencode row). So the one command that produces a
  # thinking agent is the create path — which is why the flags were added above,
  # and why pointing at a nonexistent repair verb would just move the dead end.
  local can_think="yes" think_fix=""
  if (( ! byo )) && _pack_seat_needs_key "$type"; then
    can_think="no"
    think_fix="sudo 5dive agent rm $as && sudo 5dive agent import <pack> --as=$as --type=$type --provider=<id> --api-key=<key|-> --model=<slug>"
    warn "agent '$as' CANNOT ANSWER YET: a '$type' seat authenticates by API key only (no interactive sign-in), and this import deferred auth — so it has no credential AND no model pin, and this CLI has no verb that adds a model to a live '$type' seat. The persona landed; the agent behind it is inert. Re-run the import with credentials: $think_fix"
  fi
  if [[ "$type" == "claude" ]]; then
    local sfile="$cdir/settings.json" hooks plugins cur
    hooks=$(jq -c '.hooks // {}'     "$stage/manifest.json")
    plugins=$(jq -c '.plugins // []' "$stage/manifest.json")
    # DIVE-995: deny-by-default on the arbitrary-shell hooks surface. Unless the
    # importer explicitly passed --allow-hooks, drop the pack's hooks so a
    # third-party pack can't silently auto-run shell on the new agent's tool
    # events. Disclosed above; stripping is the enforced safety default.
    if (( ! allow_hooks )) && { (( disc_hooks > 0 )) || [[ "$disc_hooks_nonempty" == "true" ]]; }; then
      warn "stripped the pack's hooks (arbitrary shell auto-run on tool events) — re-import with --allow-hooks to keep them"
      hooks='{}'
    fi
    # DIVE-1009: deny-by-default also covers plugin-carried hooks. A bundled plugin
    # that ships its own shell-on-tool-event never reaches the $hooks strip above,
    # so scrub any .hooks block nested in the plugins structure too (no-op for the
    # common name-ref case; drops the surface for a hostile, hook-bearing plugin).
    if (( ! allow_hooks )) && [[ "$disc_plugin_hooks" == "true" ]]; then
      warn "stripped plugin-carried hook(s) from the pack — re-import with --allow-hooks to keep them"
      plugins=$(jq -c 'walk(if type == "object" then del(.hooks) else . end)' <<<"$plugins" 2>/dev/null || echo "$plugins")
    fi
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
      # DIVE-2568: on a claude seat the store IS the loading mechanism; elsewhere
      # it is only the searchable one, and the inline above is what puts the facts
      # in front of the model. Say which happened rather than leaving the reader
      # to infer it from the type.
      [[ "$mem_effect" == "none" && "$type" == "claude" ]] && mem_effect="auto-loaded from $mdir"
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
    # DIVE-2370: parse_skill_spec is a splitter, not a validator. Guard before the -f probe
    # so a traversal id is skipped-and-reported rather than reaching either install path.
    if ! valid_skill_id "$id"; then skipped+=("$sk"); continue; fi
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

  # DIVE-2565: a silent skill drop is the bad outcome the single-file format was
  # explicitly not allowed to have. Name them, on every harness.
  #
  # DIVE-2678: naming them was not enough. "Skills added: 4, skipped: 18" reads as a
  # broken importer, and the reader's next move (re-run it, file a bug) is the wrong
  # one in both cases — the skip is CORRECT, the skill genuinely is not fetchable from
  # the repo that was tried. So say which repo was tried, why that one, and the exact
  # command that fixes it. A bare ref and a qualified ref fail for different reasons
  # and get different sentences.
  if (( ${#skipped[@]} > 0 )); then
    warn "skills NOT installed on this '$type' agent: ${skipped[*]} — the agent's instructions still assume them"
    local sk_
    for sk_ in "${skipped[@]}"; do
      if [[ "$sk_" == *:* ]]; then
        warn "  '${sk_#*:}' — '${sk_%%:*}' did not serve it (missing, private, or unreachable from this host)"
      else
        warn "  '$sk_' — no source recorded in the pack, so only '$(gh_org)/skills' was tried and it is not published there; re-add it by hand: 5dive agent skill $as add --source=<owner/repo> --skill=$sk_"
      fi
    done
  fi

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
  [[ "$mem_inc" == "distilled" ]] && mem_note="distilled memory -> $mem_seeded ($mem_effect)"
  local hooks_note="none"
  if (( disc_hooks > 0 )) || [[ "$disc_hooks_nonempty" == "true" || "$disc_plugin_hooks" == "true" ]]; then
    local _pn=""; [[ "$disc_plugin_hooks" == "true" ]] && _pn="+plugin"
    hooks_note="stripped($disc_hooks$_pn)"; (( allow_hooks )) && hooks_note="allowed($disc_hooks$_pn)"
  fi
  # DIVE-2568: `persona` is where the identity doc actually landed for THIS
  # harness, and `notApplied` is the machine-readable half of the warn above —
  # the dashboard renders a cross-harness hire from these two, so neither the
  # human nor the UI has to infer "did the persona reach a codex seat" from the
  # absence of an error.
  local persona_at; persona_at=$(persona_target "$as" "$type" 2>/dev/null || echo "")
  local lands_j; lands_j=$(printf '%s\n' "${_lands[@]+"${_lands[@]}"}" | jq -R . | jq -cs 'map(select(. != ""))')
  # DIVE-2676: canThink/thinkFix ride in the SAME envelope as the success text so
  # neither a human skimming the last line nor the dashboard rendering the JSON
  # can read an inert seat as a healthy hire. An import that cannot produce an
  # agent that answers is not a green import, and the summary line says so.
  local think_note=""
  [[ "$can_think" == "no" ]] && think_note=" INERT: no credential and no model on this '$type' seat — see the warning above."
  ok "imported '$as' from pack onto a '$type' seat ($mem_note). Skills added: ${#added[@]}, skipped: ${#skipped[@]}; template: $templated; avatar: $avatar_note; hooks: $hooks_note.${think_note}" \
     '{name:$n, type:$t, persona:$pa, landsOn:$lands, notApplied:$nap, canThink:$ct, thinkFix:$tf, memory:$mem, memorySeeded:$ms, memoryInEffect:$me, skillsAdded:$a, skillsSkipped:$s, template:$tpl, avatar:$av, reported:$ri, hooks:$hk, disclosure:$disc}' \
     --arg ct "$can_think" --arg tf "$think_fix" \
     --arg n "$as" --arg t "$type" --arg pa "$persona_at" --argjson lands "$lands_j" --argjson nap "$cross_dropped" \
     --arg mem "$mem_inc" --arg ms "$mem_seeded" --arg me "$mem_effect" --argjson a "$added_j" --argjson s "$skipped_j" --arg tpl "$templated" --arg av "$avatar_note" --arg ri "$reported" --arg hk "$hooks_note" --argjson disc "$disclosure"
}
