# cmd_memory — queryable team memory, read-path (DIVE-726 Phase 1a).
#
# `5dive memory search "<query>"` ranks and returns the most relevant snippets
# from the agent's markdown memory stores, capped at a token ceiling, with source
# provenance. BM25-first (lexical) per the Phase 1a decision (lodar 2026-07-02):
# no embedding model, no new dependency, nothing leaves the box — the moat is the
# accumulated fleet history, retrieved not injected (flat, bounded context cost).
#
# Read-only (same posture as `usage` / `digest`): scans markdown files only, no
# registry mutation, no lock, no audit.
#
# Stores (default): the calling user's own memory dirs — every
#   ~/.claude/projects/*/memory/**.md
# plus the shared wiki (community/wiki) when present on this box (internal fleet).
# Cross-agent recall (reading another agent's store) is Phase 1b — gated on the
# group-readable-store decision — so Phase 1a stays single-agent + shared wiki.
#
# Usage:
#   5dive memory search "<query>" [--limit=N] [--max-tokens=T] [--roots=a,b,...]
#     --limit       max snippets to return (default 8)
#     --max-tokens  ceiling on total snippet tokens returned (default 1500)
#     --roots       comma-separated dirs to search (overrides the defaults)

_memory_usage() {
  cat >&2 <<'EOF'
5dive memory — queryable team memory

  5dive memory search "<query>" [--limit=N] [--max-tokens=T] [--roots=a,b]
                                [--store=all|mine|wiki] [--agent=<name>]
      Rank markdown memory snippets by relevance (BM25), newest-fleet-history
      first, capped at a token ceiling, with file+heading provenance.
      --store  all (default): own stores + shared wiki · mine: own stores only
               · wiki: shared wiki only
      --agent  search ANOTHER agent's store (per-user 0600 — root only; the
               shared path for cross-agent knowledge is the wiki)
      --index  TWO-STAGE RECALL (DIVE-3821). Print one INDEX ROW per file —
               slug + the one-line description + score, no bodies — then fetch
               only what you chose with `memory get`. Measured on a real
               633-atom store, same query: 8 rows = 459 tok against 8 snippets
               = 1008 tok. --limit defaults to 25 here — the point of stage 1
               is to see enough candidates to choose between, and 25 rows
               (1401 tok) still beat 8 snippets on candidates per token.

  5dive memory get <slug> [<slug>...] [--max-tokens=T] [--roots=a,b]
                          [--store=all|mine|wiki] [--agent=<name>]
      Stage 2: print the FULL bodies of the named atoms, over the same roots
      `search` ranks. Slugs are the ones `search --index` printed (- and _ are
      interchangeable); an unknown slug names its near neighbours instead of
      just refusing. Exits 4 only when NOTHING resolved — a partial fetch is a
      fetch. Idea credit: claude-mem (Apache-2.0) search → get_observations.

  5dive memory router [--root=<dir>] [--agent=<name>] [--budget=BYTES]
                      [--recent=N] [--write]
      Rebuild MEMORY.md as a small ROUTER instead of a flat enumeration of
      every atom. A flat index grows with the store and, past the ~24 KB load
      limit, the loader drops its TAIL with no error — the oldest facts stop
      existing silently. The router carries the recall protocol, a typed topic
      map with counts, and the newest N atoms by slug; everything else stays on
      disk and is reached through `search --index` + `get`. NOTHING is deleted.
      Dry-run by default. --write backs the old index up to
      MEMORY.md.pre-router-<stamp> first. A block between
      `<!-- router:keep-start -->` / `<!-- router:keep-end -->` is carried over
      verbatim — the generator never owns your hand-written standing lines.

  5dive memory add --name=<kebab-slug> --description="<one-liner>"
                   [--type=user|feedback|project|reference] [--store=mine|wiki]
                   [--tags=a,b] [--valid-to=YYYY-MM-DD] [--supersedes=<slug>]
                   [--confidence=high|medium|low] [--provenance="<source>"]
                   [--evidence=<kind>:<ref>]... [--check='<cmd>' | --no-check="<why>"]
                   [--no-dedup] [--force]  (body on stdin)
      Compile a durable memory: writes a frontmatter markdown file into your
      own store (default) or the shared team wiki (--store=wiki, the publish
      path other agents can search), stamps provenance (who/when), appends the
      store's index line, and refuses token/key-shaped content (tripwire;
      --force does NOT bypass it). Existing file needs --force to overwrite.
      Lifecycle envelope (, all optional): --valid-to = date the fact
      expires / needs recheck; --supersedes = slug of the memory this replaces
      (that one is then demoted in recall instead of silently lingering);
      --confidence = how sure; --provenance = where the fact came from. Recall
      demotes + flags expired / superseded / low-confidence facts (never hides).
      Evidence back-refs (DIVE-3106, idea-derived from TencentDB-Agent-Memory,
      MIT): --evidence is repeatable and STRUCTURAL, so "re-verify this claim"
      is a mechanical walk instead of re-reading prose. Kinds:
        file:<path>[:line]  task:DIVE-1234  cmd:<command that proves it>
        sha:<gitsha>  url:<https://...>  run:<id>
      It sits BESIDE --provenance (free text), which is unchanged. A memory
      with no evidence is not flagged, demoted, or degraded.
      CHECKABILITY (DIVE-3885) is a SEPARATE, AUTHORED field — deliberately not
      built on --evidence. Measured 2026-09-01 over 2,651 fleet atoms: 596 carry
      evidence, but 595 of those are `run:<session id>`, stamped by the
      consolidate pipeline. TWELVE hand-authored refs exist fleet-wide. A field
      the pipeline can fill converges to whatever the pipeline fills in, so
      `check:` is one the pipeline CANNOT fill and `add` will not let it skip
      silently:
        --check='<cmd>'   a read-only shell command whose EXIT CODE re-derives
                          this fact. 0 = still true. It is run unattended by
                          `memory check`, so it is refused if it writes, escapes
                          (sudo/rm/curl|sh), or is trivially green (`true`, `:`,
                          a bare echo) — a check that cannot go red is not one.
                          It is also refused if THE SHELL CANNOT PARSE IT:
                          `--check=` reads like a description field, and a
                          sentence in it made the pass accuse a true fact
                          (DIVE-3909). A check that parses but names a command
                          absent from this box is still accepted — that is the
                          `unknown` the pass exists to report.
        --no-check="<why>" the recorded opt-out. Not free: the reason is written
                          to frontmatter as `no_check:`, so an unchecked fact is
                          COUNTABLE rather than merely absent.
      WRITE-TIME ENFORCEMENT: --type=reference (a fact about the world, the
      class that rots) requires one of the two. Every other type is unchanged.
      Write-time dedup: `add` WARNS (never refuses) when the body overlaps an
      existing memory in the same store — silence it with --no-dedup.

  5dive memory consolidate [--max-sessions=N] [--idle-min=M] [--max-chars=C]
                           [--distiller=<cmd>] [--dry-run] [--force]
      ASYNC transcript -> memory atoms (DIVE-726 phase 1). Distils your own
      FINISHED session transcripts into durable atoms (facts, preferences,
      constraints, events) written into your own store through the same
      `memory add` path — so knowledge outlives a window nobody remembered to
      compile. Built for cron, not for a live session:
        --max-sessions  transcripts per pass (default 3) — bounds the cost
        --idle-min      never touch a transcript written inside N minutes
                        (default 30). This is what keeps it off the LIVE session.
        --max-chars     excerpt cap per transcript (default 20000)
        --distiller     command reading the excerpt on stdin, returning
                        {"atoms":[...]} (default: headless `claude --print`;
                        env FIVEDIVE_MEMORY_DISTILLER also sets it)
        --dry-run       print the atoms, write nothing, leave the ledger alone
        --force         re-distil a transcript the ledger already records
      EXIT CODE IS THE ARTIFACT, NOT THE ATTEMPT (DIVE-3711): a pass whose every
      attempted distillation FAILED wrote nothing and exits 6 (auth required —
      the usual cause is a CLI that is not logged in for this user). A partial
      failure, or a pass that legitimately found nothing durable, still exits 0.
      In --json, `ok` mirrors that. Read the atom count, never the exit code, if
      what you want to know is whether anything was produced.
      Idempotent: a ledger (.consolidated.tsv beside the store) records each
      (session, byte count), and `add` refuses a slug that already exists — so a
      re-run is a no-op even if the ledger is lost.
      Writes to YOUR OWN store only. There is deliberately no --store: an
      auto-extractor must not be able to publish to the shared wiki (DIVE-481
      deny-default). Publishing stays a curated act.
      SCHEDULED FOR YOU — you do not have to wire this up. The heartbeat tick
      (the one root cron every box already has) runs ONE bounded pass per seat
      every 6h, as that seat's own user. Off: MEMORY_CONSOLIDATE=off. Retune:
      MEMORY_CONSOLIDATE_EVERY_MIN. Run it by hand any time; it is idempotent.
      COST — it spends YOUR model quota, so the number is stated, not implied.
      Measured 2026-08-20, default `claude --print` distiller, one ~300KB
      transcript at --max-chars=20000: $0.244 cold-cache, $0.081 warm, ~35s,
      ~2.5k output tokens. The scheduled cadence bounds that to <=4 calls per
      seat per day, and a seat with no NEW finished transcript costs $0 (the
      ledger short-circuits before the distiller is ever invoked). Lower it
      further with --max-chars, or point --distiller at a cheaper model.

  5dive memory check [--roots=a,b] [--store=all|mine|wiki] [--agent=<name>]
                     [--slug=<slug>]... [--timeout=SEC] [--dry-run] [--json]
      Run every atom's authored `check:` command and report which facts no
      longer re-derive. It STAMPS `check_status`, `checked_at` and `check_rc`
      into the frontmatter — that is the point of the pass, and it is what makes
      the flag two-way: a fact whose check goes green again is stamped `fresh`
      and stops being demoted. `--dry-run` looks without touching anything.
        exit 0  every check that RAN came back green
        exit 1  at least one fact went `stale` (its check ran and went red)
      A red check means THE FACT IS WRONG **OR THE CHECKER IS** — so `stale` is
      a flag for a human/agent to adjudicate, never a verdict. Recall demotes a
      stale fact and says so; it is never hidden, and NOTHING here deletes a
      memory. A checker that could not RUN (timeout, command not found, not
      executable, or shell text the parser rejects) is `unknown`, NOT stale — an instrument failure and a false fact are the same
      shape from the outside, and folding them together is how a janitor starts
      deleting true facts. Checks run read-only, with a timeout (default 20s),
      one at a time, under your own uid.

  5dive memory doctor [--roots=a,b] [--agent=<name>] [--code-root=<dir>] [--json]
      Hygiene pass over the memory store(s): index drift (MEMORY.md vs files on
      disk), dangling [[wiki-links]], stale source refs (file:line no longer in
      the codebase), near-duplicate memories, and dangling structural
      evidence back-refs (--evidence file: targets). Also runs inside the
      `memory` category of `5dive doctor` for the whole box.

Searches the agent's own ~/.claude/projects/*/memory stores (+ the shared wiki
when present) unless --roots/--store/--agent narrow it.
EOF
}

# Root helpers (DIVE-897): own stores, another agent's stores, the shared wiki.
# Each emits a comma-separated list (may be empty).
_memory_own_roots() {
  # $1 (optional) = an agent short name — that agent's home instead of ours.
  # Per-user memory dirs are 0600, so another agent's store only resolves for
  # root; a non-root caller gets an empty list (the caller errors clearly).
  local base="$HOME" roots=() d
  if [ -n "${1:-}" ]; then
    base="/home/agent-$1"
    [ -d "$base" ] || base="/home/$1"   # the main `claude` user has no agent- prefix
  fi
  for d in "$base"/.claude/projects/*/memory; do
    [ -d "$d" ] && [ -r "$d" ] && roots+=("$d")
  done
  local IFS=,; echo "${roots[*]}"
}

_memory_wiki_root() {
  # Shared wiki (internal fleet only; absent on customer boxes — harmless).
  local d
  for d in "$HOME"/projects/5dive/community/wiki /home/claude/projects/5dive/community/wiki; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  echo ""
}

# Default search roots: own stores + wiki (the pre-scoping behavior).
_memory_default_roots() {
  local own wiki
  own=$(_memory_own_roots)
  wiki=$(_memory_wiki_root)
  if [ -n "$own" ] && [ -n "$wiki" ]; then echo "$own,$wiki"
  else echo "${own}${wiki}"
  fi
}

# Scoping (DIVE-897): resolve roots from --store/--agent unless --roots wins.
# --agent reads another agent's per-user store — 0600, so root only; the
# sanctioned cross-agent path is the shared wiki (agents PUBLISH there via
# `memory add --store=wiki`; private stores stay private, deny-by-default per
# the DIVE-481 distillation-gate posture).
# DIVE-3821: lifted out of `search` verbatim so `get` and `router` resolve the
# SAME roots — a fetch that could not see what the index row came from is not a
# second stage, it is a second store.
# $1=store  $2=agent  $3=explicit --roots (wins when non-empty)
_memory_resolve_roots() {
  local store="$1" agent="$2" roots="$3"
  if [ -z "$roots" ]; then
    local own="" wiki=""
    if [ -n "$agent" ]; then
      [ "$store" = "wiki" ] && fail "$E_USAGE" "--agent scopes a private store; it can't combine with --store=wiki"
      own=$(_memory_own_roots "$agent")
      [ -n "$own" ] || fail "$E_PERMISSION" "can't read agent '$agent''s memory store (per-user 0600 — run as root, or search the shared wiki instead)"
      [ "$store" = "all" ] && wiki=$(_memory_wiki_root)
    else
      [ "$store" != "wiki" ] && own=$(_memory_own_roots)
      [ "$store" != "mine" ] && wiki=$(_memory_wiki_root)
      [ "$store" = "wiki" ] && [ -z "$wiki" ] && fail "$E_NOT_FOUND" "no shared wiki on this box (community/wiki)"
    fi
    if [ -n "$own" ] && [ -n "$wiki" ]; then roots="$own,$wiki"; else roots="${own}${wiki}"; fi
  fi
  [ -n "$roots" ] || fail "$E_NOT_FOUND" "no memory stores found (looked in ~/.claude/projects/*/memory); pass --roots="
  echo "$roots"
}

_memory_search() {
  # DIVE-3821: two-stage recall. --index returns INDEX ROWS (slug + the
  # one-line description + score), one per FILE, with no bodies — the cheap
  # first stage. `memory get <slug>...` is the second stage and fetches the
  # full bodies for the handful of slugs that were actually chosen.
  local query="" limit=8 limit_set=0 maxtok=1500 roots="" store="all" agent="" index=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit=*)      limit="${1#*=}"; limit_set=1 ;;
      --index)        index=1 ;;
      --index=*)      case "${1#*=}" in 1|true|yes) index=1 ;; 0|false|no) index=0 ;; *) fail "$E_VALIDATION" "--index takes no value (or 1|0)" ;; esac ;;
      --max-tokens=*) maxtok="${1#*=}" ;;
      --roots=*)      roots="${1#*=}" ;;
      --store=*)      store="${1#*=}" ;;
      --agent=*)      agent="${1#*=}" ;;
      -h|--help)      _memory_usage; return 0 ;;
      --*)            fail "$E_USAGE" "memory search: unknown flag: $1" ;;
      *)              [ -z "$query" ] && query="$1" || query="$query $1" ;;
    esac
    shift
  done
  [ -n "$query" ] || { _memory_usage; fail "$E_USAGE" "memory search: a query is required"; }
  # An index row costs ~30 tokens against ~130 for a snippet, so the first
  # stage can afford to be WIDER: the whole point is to see enough candidates
  # to choose between them. Only the defaults move; an explicit --limit wins.
  if [ "$index" -eq 1 ] && [ "$limit_set" -eq 0 ]; then limit=25; fi
  require_node "memory search"
  case "$store" in all|mine|wiki) : ;; *) fail "$E_VALIDATION" "bad --store '$store' (all | mine | wiki)" ;; esac
  if [ -n "$roots" ] && { [ "$store" != "all" ] || [ -n "$agent" ]; }; then
    fail "$E_USAGE" "--roots overrides scoping — don't combine it with --store/--agent"
  fi
  roots="$(_memory_resolve_roots "$store" "$agent" "$roots")"

  local js; js="$(mktemp -t 5dive-memsearch.XXXXXX.mjs)" || fail "$E_GENERIC" "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -f '$js'" RETURN
  cat > "$js" <<'MEMJS'
// DIVE-726 Phase 1a — BM25 lexical read-path over the markdown memory stores.
// Section-chunked (by md heading) for provenance; YAML frontmatter stripped with
// the description kept as each chunk's lead; token-ceilinged output. Zero deps.
import fs from "node:fs";
import path from "node:path";
const argv = process.argv.slice(2);
const query = argv.find((a) => !a.startsWith("--")) ?? "";
const opt = (k, d) => { const h = argv.find((a) => a.startsWith(`--${k}=`)); return h ? h.slice(k.length + 3) : d; };
const LIMIT = Number(opt("limit", 8));
const MAX_TOKENS = Number(opt("max-tokens", 1500));
const ROOTS = String(opt("roots", "")).split(",").filter(Boolean);
const INDEX = String(opt("index", "0")) === "1";   // DIVE-3821 stage 1: rows, not bodies
const TODAY = new Date().toISOString().slice(0, 10);   // DIVE-1024: expiry compare
const estTokens = (s) => Math.ceil(s.length / 4);
const STOP = new Set("a an and are as at be but by for from has have if in into is it its of on or that the their then there these this to was were will with you your our we".split(" "));
const tokenize = (s) => s.toLowerCase().replace(/`[^`]*`/g, " ").replace(/[^a-z0-9]+/g, " ").split(" ").filter((t) => t.length > 1 && !STOP.has(t));
function mdFiles(root) {
  const out = [];
  const walk = (d) => {
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) { const full = path.join(d, e.name); if (e.isDirectory()) walk(full); else if (e.isFile() && e.name.endsWith(".md")) out.push(full); }
  };
  walk(root); return out;
}
// DIVE-1024: pull a single scalar field out of a YAML frontmatter block.
function fmField(fm, k) { const m = new RegExp(`^\\s*${k}:\\s*["']?(.+?)["']?\\s*$`, "m").exec(fm); return m ? m[1].trim() : ""; }
function chunk(file) {
  let text; try { text = fs.readFileSync(file, "utf-8"); } catch { return []; }
  const fm = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  let front = "";
  // DIVE-1024 lifecycle envelope, parsed once per file and carried on each chunk.
  let meta = { name: path.basename(file).replace(/\.md$/, ""), validTo: "", confidence: "", supersedes: "", checkStatus: "", checkedAt: "" };
  if (fm) {
    const desc = /^description:\s*["']?(.+?)["']?\s*$/m.exec(fm[1]); if (desc) front = desc[1].replace(/^>\s*/, "").trim();
    meta = {
      name: fmField(fm[1], "name") || fmField(fm[1], "title") || meta.name,
      validTo: fmField(fm[1], "valid_to"),
      confidence: fmField(fm[1], "confidence").toLowerCase(),
      supersedes: fmField(fm[1], "supersedes"),
      checkStatus: fmField(fm[1], "check_status").toLowerCase(),
      checkedAt: fmField(fm[1], "checked_at"),
    };
    text = text.slice(fm[0].length);
  }
  const lines = text.split("\n");
  const chunks = [];
  let cur = { heading: path.basename(file), body: [] };
  for (const line of lines) {
    const m = /^(#{1,6})\s+(.*)$/.exec(line);
    if (m) { if (cur.body.join("").trim()) chunks.push(cur); cur = { heading: m[2].trim(), body: [] }; }
    else cur.body.push(line);
  }
  if (cur.body.join("").trim()) chunks.push(cur);
  return chunks.map((c, i) => { let t = c.body.join("\n").trim(); if (i === 0 && front) t = `${front}\n\n${t}`; return { file, heading: c.heading, text: t, m: meta }; }).filter((c) => c.text.length > 0);
}
const docs = [];
for (const root of ROOTS) for (const f of mdFiles(root)) docs.push(...chunk(f));
// DIVE-1024: any slug named in some fact's `supersedes` is stale → demote it.
const superseded = new Set(docs.map((d) => d.m && d.m.supersedes).filter(Boolean));
const CONF_MULT = { low: 0.5, medium: 0.85, high: 1, "": 1 };
// Multiplicative demotion (never removal): expired/superseded/low-confidence
// facts still surface, ranked lower, with a visible flag. Absent fields = 1x.
function lifecycle(m) {
  let mult = 1; const flags = [];
  if (!m) return { mult, flags };
  if (m.validTo && m.validTo < TODAY) { mult *= 0.3; flags.push(`⚠ expired ${m.validTo}`); }
  if (superseded.has(m.name)) { mult *= 0.2; flags.push("⤴ superseded"); }
  const cm = CONF_MULT[m.confidence] ?? 1; if (cm < 1) { mult *= cm; flags.push(`confidence:${m.confidence}`); }
  // DIVE-3885: a fact whose authored check went RED. Demoted and flagged, never
  // hidden and never deleted — the check may be the thing that broke, not the
  // fact. `unknown` (the checker could not run) is flagged at full rank: an
  // instrument failure is not evidence about the claim.
  if (m.checkStatus === "stale") { mult *= 0.4; flags.push(`⚠ check red${m.checkedAt ? ` ${m.checkedAt}` : ""}`); }
  else if (m.checkStatus === "unknown") { flags.push("? check did not run"); }
  return { mult, flags };
}
if (!query) { console.error('usage: memory search "<query>"'); process.exit(2); }
if (docs.length === 0) { console.log("(no markdown found in the given roots)"); process.exit(0); }
const k1 = 1.5, b = 0.75;
const docTokens = docs.map((d) => tokenize(`${d.heading} ${d.text}`));
const avgdl = docTokens.reduce((s, t) => s + t.length, 0) / docTokens.length;
const df = new Map();
for (const toks of docTokens) for (const t of new Set(toks)) df.set(t, (df.get(t) ?? 0) + 1);
const N = docs.length;
const idf = (t) => Math.log(1 + (N - (df.get(t) ?? 0) + 0.5) / ((df.get(t) ?? 0) + 0.5));
const qToks = [...new Set(tokenize(query))];
const scored = docs.map((d, i) => {
  const toks = docTokens[i]; const tf = new Map();
  for (const t of toks) tf.set(t, (tf.get(t) ?? 0) + 1);
  let score = 0;
  for (const qt of qToks) { const f = tf.get(qt) ?? 0; if (!f) continue; score += idf(qt) * (f * (k1 + 1)) / (f + k1 * (1 - b + b * (toks.length / avgdl))); }
  const lc = lifecycle(d.m);
  return { ...d, score: score * lc.mult, flags: lc.flags };
}).filter((d) => d.score > 0).sort((a, b) => b.score - a.score);
const home = process.env.HOME || "";
// DIVE-3821: the description is what stage 1 shows, so carry it per-file. The
// chunker folds it into chunk 0's text; re-read it here rather than parse the
// snippet back out.
function describe(file) {
  let text; try { text = fs.readFileSync(file, "utf-8"); } catch { return ""; }
  const fm = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  if (fm) {
    const d = /^description:\s*["']?(.+?)["']?\s*$/m.exec(fm[1]);
    if (d) return d[1].replace(/^>\s*/, "").trim();
  }
  // No frontmatter (the wiki has such pages): first non-heading prose line.
  for (const l of text.split("\n")) {
    const t = l.trim();
    if (!t || t.startsWith("#") || t.startsWith("---") || t.startsWith("|")) continue;
    return t;
  }
  return "";
}
function slugOf(d) { return (d.m && d.m.name) || path.basename(d.file).replace(/\.md$/, ""); }
const rel = (f) => f.replace(`${home}/.claude/projects/`, "").replace(/^-home[^/]*\/memory\//, "memory/").replace(`${home}/projects/5dive/`, "").replace("/home/claude/projects/5dive/", "");
let used = 0, shown = 0;
if (INDEX) {
  // Stage 1: one row per FILE (best-scoring chunk wins), no bodies. Ranking is
  // the same BM25 + lifecycle demotion — only the RENDERING changes, so a row
  // and its body can never disagree about which fact ranked where.
  const best = new Map();
  for (const d of scored) {
    const k = d.file;
    const prev = best.get(k);
    if (!prev || d.score > prev.score) best.set(k, d);
  }
  const rows = [...best.values()].sort((a, b) => b.score - a.score);
  console.log(`\n🔎 "${query}"  —  ${rows.length} file(s) across ${N} chunks (BM25 index rows, ≤${MAX_TOKENS} tok)\n`);
  for (const d of rows) {
    if (shown >= LIMIT) break;
    const slug = slugOf(d);
    let desc = describe(d.file);
    if (desc.length > 160) desc = desc.slice(0, 160) + " …";
    const flags = d.flags && d.flags.length ? "  [" + d.flags.join(" · ") + "]" : "";
    // The full path is NOT printed: it is ~20 tokens of the ~40 a row costs and
    // it is recoverable from the slug through `memory get`. What a chooser
    // actually needs from it is which STORE the fact came from — a wiki page is
    // shared, an own atom is private — so the row keeps that and drops the rest.
    const src = /community\/wiki\//.test(d.file) ? "wiki" : "mine";
    const line = `[${d.score.toFixed(2)}] ${slug}  ·${src}${flags}\n      ${desc || "(no description)"}`;
    const cost = estTokens(line);
    if (used + cost > MAX_TOKENS && shown > 0) break;
    used += cost; shown++;
    console.log(line);
  }
  console.log(`\n— ${shown}/${rows.length} rows, ~${used} tokens. Fetch the ones you want:\n    5dive memory get <slug> [<slug>...]\n`);
  process.exit(0);
}
console.log(`\n🔎 "${query}"  —  ${scored.length} hits across ${N} chunks / ${new Set(docs.map((d) => d.file)).size} files (BM25, ≤${MAX_TOKENS} tok)\n`);
for (const d of scored) {
  if (shown >= LIMIT) break;
  const snippet = d.text.length > 500 ? d.text.slice(0, 500) + " …" : d.text;
  const cost = estTokens(snippet);
  if (used + cost > MAX_TOKENS && shown > 0) break;
  used += cost; shown++;
  console.log(`[${d.score.toFixed(2)}] ${rel(d.file)}  ›  ${d.heading}${d.flags && d.flags.length ? "  [" + d.flags.join(" · ") + "]" : ""}`);
  console.log(snippet.split("\n").map((l) => "    " + l).join("\n"));
  console.log("");
}
console.log(`— shown ${shown}/${scored.length} hits, ~${used} tokens —`);
MEMJS
  node "$js" "$query" --limit="$limit" --max-tokens="$maxtok" --roots="$roots" --index="$index"
}

# memory add — the write/compile path (DIVE-897, DIVE-726 Phase 1b).
# Deterministic half of "compile before you close": the AGENT authors the body
# (that's LLM work, guided by the compile-knowledge skill); this command gives
# it one mechanical, provenance-stamped, tripwired way to persist it. Writing
# to --store=wiki is the PUBLISH path that makes a fact fleet-searchable —
# cross-agent recall happens by publishing here, never by opening the 0600
# per-agent stores (deny-by-default, same posture as the DIVE-481 gate).
# _memory_emit_evidence <indent> [ref...] — emit the structural evidence list as
# YAML. Values are double-quoted (a cmd: ref carries arbitrary shell text).
_memory_emit_evidence() {
  local indent="$1"; shift
  [ $# -gt 0 ] || return 0
  printf '%sevidence:\n' "$indent"
  local r
  for r in "$@"; do
    printf '%s  - "%s"\n' "$indent" "$(printf '%s' "$r" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  done
}

# _memory_dedup_warn <target-file> <store-dir> — DIVE-3106 write-time dedup.
# ADVISORY ONLY, by lodar's constraint (2026-08-09): `memory add` already carries
# one load-bearing refusal (the secret tripwire) and a second refusal on the same
# verb would make compiling feel adversarial — a duplicate memory is cheaper than
# a false refusal on a write path. So: warn on stderr, exit 0, always.
# Same Jaccard-over-body-words shape as the doctor's near-dup check, so the two
# agree. Body arrives on stdin. python3 absent (customer boxes) = silently skip.
# NOTE the body arrives as a FILE, not on stdin. The heredoc that carries this
# program IS python3's stdin, so a piped body would be swallowed by `python3 -`
# and sys.stdin.read() would return the tail of the program. (Caught by the
# harness, not by review: the dedup silently never fired.)
_memory_dedup_warn() {
  local target="$1" dir="$2" bodyfile="$3"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$target" "$dir" "$bodyfile" <<'DEDUPPY' >&2 || true
import os, re, sys
target, store, bodyfile = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    body = open(bodyfile, encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)
WORD = re.compile(r"[a-z0-9_./-]{3,}")
def words(t):
    t = re.sub(r"\A---\n.*?\n---\n", "", t, flags=re.S)   # drop frontmatter
    return set(WORD.findall(t.lower()))
mine = words(body)
if len(mine) < 12:
    sys.exit(0)
hits = []
try:
    entries = sorted(os.listdir(store))
except OSError:
    sys.exit(0)
for f in entries:
    if not f.endswith(".md") or f in ("MEMORY.md", "index.md"):
        continue
    path = os.path.join(store, f)
    if os.path.abspath(path) == os.path.abspath(target):
        continue                                  # --force update-in-place
    try:
        w = words(open(path, encoding="utf-8", errors="replace").read())
    except OSError:
        continue
    if len(w) < 12:
        continue
    inter = len(mine & w)
    if not inter:
        continue
    jac = inter / len(mine | w)
    if jac >= 0.6:
        hits.append((jac, f))
for jac, f in sorted(hits, reverse=True)[:3]:
    sys.stderr.write(
        "\u26a0 near-duplicate: %d%% token overlap with %s \u2014 consider updating "
        "it in place (--force) or --supersedes; writing anyway "
        "(--no-dedup silences this)\n" % (int(jac * 100), f))
DEDUPPY
  return 0
}

# _memory_check_validate <cmd> — DIVE-3885. A `check:` is executed UNATTENDED by
# `memory check`, and its whole value is that it can go RED. Two refusals:
#
#  1. NOT READ-ONLY. The nightly pass runs these with the store owner's uid. A
#     check that writes, deletes, escalates or pipes the network into a shell is
#     a scheduled command with a memory file for a trigger.
#  2. TRIVIALLY GREEN. `--check=true` satisfies the enforcement and re-derives
#     nothing — the exact degeneracy that made `evidence:` 99% autostamp. An
#     enforcement with a free-and-silent way to satisfy it enforces nothing.
_memory_check_validate() {
  local c="$1"
  [ -n "$(printf '%s' "$c" | tr -d '[:space:]')" ] \
    || fail "$E_VALIDATION" "--check is empty — it must be a command whose exit code re-derives the fact"
  # 0. IS IT A COMMAND AT ALL — DIVE-3909. `--check=` reads like a description
  # field and an author will write one; the atom that forced this row carried
  # English prose and every refusal below let it through. `bash -c` then died on
  # the syntax error with rc 2, and 2 is neither 127 nor a timeout, so the pass
  # called a TRUE fact stale for a defect in the SENTENCE. DIVE-3885's own rule
  # is that enforcement belongs where the fact is WRITTEN, so it belongs here.
  if ! bash -n -c "$c" 2>/dev/null; then
    fail "$E_VALIDATION" "--check is not a runnable command — the shell cannot parse it. A check is shell text whose EXIT CODE re-derives the fact, not a description of how to re-derive it (use --no-check=\"<why>\" to record the gap)"
  fi
  # A check that PARSES but names a command absent from this box is NOT refused
  # here: DIVE-3885 deliberately treats "the checker could not run" as a real,
  # expected state (`unknown` at full rank), and a wiki atom travels to seats
  # that do not hold the tool. So prose that happens to parse — `the file still
  # exists` — is caught at run time as `unknown`, never as `stale`. That is the
  # honest outcome; the damage this row is about is a TRUE fact demoted 0.4x,
  # and the parse refusal plus the unknown net close that completely.
  # 1. read-only
  if printf '%s' "$c" | grep -qE '(^|[;&|[:space:]])(sudo|rm|rmdir|mv|dd|mkfs|shutdown|reboot|kill|pkill|truncate|chmod|chown|tee)([[:space:]]|$)'; then
    fail "$E_VALIDATION" "--check must be READ-ONLY — it is run unattended by \`memory check\` (refused: writes/escalates)"
  fi
  # Redirection: silencing is fine, writing a file is not. Strip the shapes that
  # produce no file (>/dev/null, >/dev/stderr, 2>&1) and refuse whatever `>` is
  # left — that one has a path on the end of it.
  local _redir; _redir="$(printf '%s' "$c" | sed -E 's/[0-9]?>>?[[:space:]]*\/dev\/(null|stdout|stderr)//g; s/[0-9]?>>?&[0-9-]//g')"
  if printf '%s' "$_redir" | grep -q '>'; then
    fail "$E_VALIDATION" "--check must be READ-ONLY — redirecting to a file is a write (>/dev/null 2>&1 is allowed if you only meant to silence it)"
  fi
  if printf '%s' "$c" | grep -qE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh'; then
    fail "$E_VALIDATION" "--check must be READ-ONLY — piping a download into a shell is not a check"
  fi
  if printf '%s' "$c" | grep -qE '5dive[[:space:]]+(task|agent|memory)[[:space:]]+(done|add|cancel|start|send|kill|rm|reject|deliver)'; then
    fail "$E_VALIDATION" "--check must be READ-ONLY — it must not drive the board or the fleet"
  fi
  # 2. cannot go red
  local t; t="$(printf '%s' "$c" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$t" in
    true|:|"exit 0"|true*\;*|echo*|printf*|cat*|"pwd"|"date"|"whoami"|"hostname")
      fail "$E_VALIDATION" "--check '$t' can never go red — a check that cannot fail is not a check (it is the degeneracy that made \`evidence:\` 99% autostamp)" ;;
  esac
  return 0
}

_memory_add() {
  local name="" type="" desc="" store="mine" tags="" force=0 no_dedup=0
  local valid_to="" supersedes="" confidence="" provenance=""
  local check="" no_check="" check_set=0 no_check_set=0
  local evidence=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name=*)        name="${1#*=}" ;;
      --type=*)        type="${1#*=}" ;;
      --description=*) desc="${1#*=}" ;;
      --store=*)       store="${1#*=}" ;;
      --tags=*)        tags="${1#*=}" ;;
      --valid-to=*)    valid_to="${1#*=}" ;;
      --supersedes=*)  supersedes="${1#*=}" ;;
      --confidence=*)  confidence="${1#*=}" ;;
      --provenance=*)  provenance="${1#*=}" ;;
      --evidence=*)    evidence+=("${1#*=}") ;;
      --check=*)       check="${1#*=}"; check_set=1 ;;
      --no-check=*)    no_check="${1#*=}"; no_check_set=1 ;;
      --no-dedup)      no_dedup=1 ;;
      --force)         force=1 ;;
      -h|--help)       _memory_usage; return 0 ;;
      *)               fail "$E_USAGE" "memory add: unknown arg: $1" ;;
    esac
    shift
  done
  [ -n "$name" ] || fail "$E_USAGE" "memory add: --name=<kebab-slug> is required"
  printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9-]{0,63}$' \
    || fail "$E_VALIDATION" "--name must be kebab-case, ≤ 64 chars"
  [ -n "$desc" ] || fail "$E_USAGE" "memory add: --description is required (it's what recall ranks on)"
  case "$store" in mine|wiki) : ;; *) fail "$E_VALIDATION" "bad --store '$store' (mine | wiki)" ;; esac
  if [ "$store" = "mine" ]; then
    [ -n "$type" ] || fail "$E_USAGE" "--type=user|feedback|project|reference is required for your own store"
    case "$type" in user|feedback|project|reference) : ;; *) fail "$E_VALIDATION" "bad --type '$type' (user | feedback | project | reference)" ;; esac
  fi
  # DIVE-1024 lifecycle envelope (all optional; absent = pre-1024 behavior).
  if [ -n "$valid_to" ]; then printf '%s' "$valid_to" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      || fail "$E_VALIDATION" "--valid-to must be an ISO date (YYYY-MM-DD)"; fi
  if [ -n "$confidence" ]; then case "$confidence" in high|medium|low) : ;; *) fail "$E_VALIDATION" "--confidence must be high|medium|low" ;; esac; fi
  if [ -n "$supersedes" ]; then printf '%s' "$supersedes" | grep -qE '^[a-z0-9][a-z0-9_-]{0,63}$' \
      || fail "$E_VALIDATION" "--supersedes must be the slug of the memory it replaces"; fi
  # DIVE-3106 evidence back-refs: a STRUCTURAL path from the claim to the ground
  # truth, so re-verification is a mechanical walk. The kind prefix is what makes
  # it walkable — a free-text ref would just be a second --provenance.
  local _ev
  for _ev in ${evidence+"${evidence[@]}"}; do
    case "$_ev" in
      file:?*|task:?*|cmd:?*|sha:?*|url:?*|run:?*) : ;;
      *) fail "$E_VALIDATION" "--evidence must be <kind>:<ref> (file|task|cmd|sha|url|run), got: $_ev" ;;
    esac
    case "$_ev" in
      task:*) printf '%s' "${_ev#task:}" | grep -qE '^[A-Z]+-[0-9]+$' \
          || fail "$E_VALIDATION" "--evidence task: wants a board ident like DIVE-1234, got: ${_ev#task:}" ;;
      sha:*)  printf '%s' "${_ev#sha:}" | grep -qE '^[0-9a-f]{7,40}$' \
          || fail "$E_VALIDATION" "--evidence sha: wants a git sha, got: ${_ev#sha:}" ;;
      url:*)  printf '%s' "${_ev#url:}" | grep -qE '^https?://' \
          || fail "$E_VALIDATION" "--evidence url: wants an http(s) URL, got: ${_ev#url:}" ;;
    esac
  done
  # DIVE-3885 checkability. A NEW authored field, deliberately not layered on
  # --evidence: 595 of the 596 evidence blocks fleet-wide are the pipeline's
  # `run:` autostamp, so anything built on that substrate starts from 12 rows.
  # The lesson the census yields — a memory field with no WRITE-TIME
  # enforcement converges to whatever the autostamp fills in, however well it is
  # documented — is why this one refuses instead of merely offering.
  if [ "$check_set" -eq 1 ] && [ "$no_check_set" -eq 1 ]; then
    fail "$E_USAGE" "--check and --no-check are mutually exclusive — a fact either has a way to re-derive itself or a recorded reason it does not"
  fi
  [ "$check_set" -eq 1 ] && _memory_check_validate "$check"
  if [ "$no_check_set" -eq 1 ]; then
    # The opt-out is RECORDED, not free. A bare --no-check would be a second
    # budget nobody watches; a reason in frontmatter makes the unchecked fact
    # countable, which is the only reason the enforcement survives contact.
    [ "${#no_check}" -ge 8 ] \
      || fail "$E_VALIDATION" "--no-check needs a real reason (>= 8 chars) — it is written to frontmatter and counted"
  fi
  # ENFORCEMENT, scoped to the class of fact that rots: `reference` is a claim
  # about the world outside this store (a path, a flag, a service, a limit), and
  # it is the class a stale-check pass exists for. user/feedback/project facts
  # and wiki pages are unchanged — widening this would just farm --no-check.
  if [ "$store" = "mine" ] && [ "$type" = "reference" ] && [ "$check_set" -eq 0 ] && [ "$no_check_set" -eq 0 ]; then
    fail "$E_USAGE" "a --type=reference fact needs --check='<cmd whose exit code re-derives it>', or --no-check=\"<why it cannot have one>\" to record the gap (DIVE-3885)"
  fi

  [ -t 0 ] && fail "$E_USAGE" "memory add reads the body on stdin — pipe or heredoc it"
  local body; body=$(cat)
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || fail "$E_USAGE" "empty body on stdin — nothing to remember"

  # Secret tripwire (L3 posture, shared shape with cmd_pack's): refuse content
  # that looks like a live token/key. High-signal patterns only — memory notes
  # legitimately MENTION paths like .credentials.json, so the bare word is not
  # blocked (unlike the pack exporter, which stages whole files). --force does
  # not bypass this: a secret in a memory store outlives the session that knew
  # why it was there.
  if printf '%s\n%s' "$desc" "$body" | grep -qiE 'BOT_TOKEN=|API_KEY=|-----BEGIN|sk-[A-Za-z0-9]{8,}|[0-9]{8,}:[A-Za-z0-9_-]{30,}'; then
    fail "$E_VALIDATION" "the body looks like it contains a token/key (tripwire) — memories must reference where a secret LIVES, never its value"
  fi

  # Provenance: the pre-sudo invoker (agent short name or human login) + UTC date.
  local who="${SUDO_USER:-$(whoami)}"; who="${who#agent-}"
  local today; today=$(date -u +%F)

  local dir="" file="" index_file="" index_line=""
  if [ "$store" = "wiki" ]; then
    dir=$(_memory_wiki_root)
    [ -n "$dir" ] || fail "$E_NOT_FOUND" "no shared wiki on this box (community/wiki) — use --store=mine"
    [ -w "$dir" ] || fail "$E_PERMISSION" "wiki dir $dir is not writable by $(whoami)"
    file="$dir/$name.md"
    index_file="$dir/index.md"
    index_line="- [$name]($name.md) — $desc"
  else
    # Own store: prefer the dir that already has a MEMORY.md index, else the
    # first existing memory dir. No store yet = nothing bootstrapped this agent's
    # memory — that's the harness's job, don't invent a location.
    local d
    for d in "$HOME"/.claude/projects/*/memory; do
      [ -d "$d" ] || continue
      [ -z "$dir" ] && dir="$d"
      [ -f "$d/MEMORY.md" ] && { dir="$d"; break; }
    done
    [ -n "$dir" ] || fail "$E_NOT_FOUND" "no memory store found under ~/.claude/projects/*/memory"
    file="$dir/${type}_$(printf '%s' "$name" | tr '-' '_').md"
    index_file="$dir/MEMORY.md"
    index_line="- [$name]($(basename "$file")) — $desc"
  fi
  if [ -f "$file" ] && [ "$force" -ne 1 ]; then
    fail "$E_CONFLICT" "$(basename "$file") already exists — update it with --force, or pick a new --name"
  fi
  local existed=0; [ -f "$file" ] && existed=1
  # Advisory dedup (never refuses) — before the write, so the warning is useful.
  if [ "$no_dedup" -ne 1 ]; then
    local _bf; _bf=$(mktemp "${TMPDIR:-/tmp}/5dive-mem-dedup.XXXXXX") || _bf=""
    if [ -n "$_bf" ]; then
      printf '%s' "$body" > "$_bf"
      _memory_dedup_warn "$file" "$dir" "$_bf"
      rm -f "$_bf"
    fi
  fi

  if [ "$store" = "wiki" ]; then
    { printf -- '---\ntitle: %s\n' "$name"
      [ -n "$tags" ]       && printf 'tags: [%s]\n' "$tags"
      [ -n "$confidence" ] && printf 'confidence: %s\n' "$confidence"
      [ -n "$valid_to" ]   && printf 'valid_to: %s\n' "$valid_to"
      [ -n "$supersedes" ] && printf 'supersedes: %s\n' "$supersedes"
      [ -n "$check" ]      && printf 'check: "%s"\n' "$(printf '%s' "$check" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      [ -n "$no_check" ]   && printf 'no_check: "%s"\n' "$(printf '%s' "$no_check" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      [ -n "$provenance" ] && printf 'provenance: "%s"\n' "$(printf '%s' "$provenance" | sed 's/"/\\"/g')"
      _memory_emit_evidence "" ${evidence+"${evidence[@]}"}
      printf 'updated: %s\ncompiled_by: %s\n---\n\n%s\n' "$today" "$who" "$body"
    } > "$file"
  else
    { printf -- '---\nname: %s\ndescription: "%s"\nmetadata:\n  type: %s\n  compiled_by: %s\n  compiled_at: %s\n' \
        "$name" "$(printf '%s' "$desc" | sed 's/"/\\"/g')" "$type" "$who" "$today"
      [ -n "$tags" ]       && printf '  tags: [%s]\n' "$tags"
      [ -n "$confidence" ] && printf '  confidence: %s\n' "$confidence"
      [ -n "$valid_to" ]   && printf '  valid_to: %s\n' "$valid_to"
      [ -n "$supersedes" ] && printf '  supersedes: %s\n' "$supersedes"
      [ -n "$check" ]      && printf '  check: "%s"\n' "$(printf '%s' "$check" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      [ -n "$no_check" ]   && printf '  no_check: "%s"\n' "$(printf '%s' "$no_check" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      [ -n "$provenance" ] && printf '  provenance: "%s"\n' "$(printf '%s' "$provenance" | sed 's/"/\\"/g')"
      _memory_emit_evidence "  " ${evidence+"${evidence[@]}"}
      printf -- '---\n\n%s\n' "$body"
    } > "$file"
  fi
  # Index line (skip when updating in place, or when the index doesn't exist —
  # never invent a MEMORY.md/index.md the store's owner didn't set up).
  if [ "$existed" -eq 0 ] && [ -f "$index_file" ] && ! grep -qF "]($(basename "$file"))" "$index_file"; then
    printf '%s\n' "$index_line" >> "$index_file"
  fi

  if (( JSON_MODE )); then
    jq -nc --arg file "$file" --arg store "$store" --arg by "$who" --arg updated "$([ "$existed" -eq 1 ] && echo true || echo false)" \
      '{ok:true, data:{file:$file, store:$store, compiled_by:$by, updated:($updated=="true")}}'
  else
    echo "✓ compiled → $file${existed:+}"
    [ "$store" = "wiki" ] && echo "  published to the shared wiki — fleet-searchable via: 5dive memory search --store=wiki"
  fi
  return 0
}

# ---- memory check (DIVE-3885) ----------------------------------------------
#
# Item 3 of the DIVE-3882 janitor plan: a `check:` whose EXIT CODE re-derives
# the fact, plus a pass that flips `check_status: stale`.
#
# THE ROW'S GUARDRAIL, kept mechanical: a red check means the fact is wrong OR
# the checker is. So this pass flips a FLAG and prints a digest. It never edits
# a body, never deletes a file, and there is no --delete to add later. Recall
# demotes a stale fact and says why; it still surfaces.
#
# And the second half of that guardrail, which is easier to get wrong: a checker
# that could not RUN is `unknown`, not `stale`. A missing binary, a box without
# the tool, a 20s timeout — those are instrument failures, and folding an
# instrument failure into "the fact is false" is exactly how an automated
# janitor starts retiring true facts.
_memory_check() {
  # DIVE-3909: `write` DEFAULTS ON. Going stale was automatic and coming back
  # was manual, so a fact whose check went green again wore the stale flag — and
  # its 0.4x recall demotion — indefinitely, because nobody remembers `--write`.
  # Stamping is what this pass is FOR; `--dry-run` looks without touching.
  local roots="" store="all" agent="" timeout_s=20 write=1
  local slugs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --roots=*)   roots="${1#*=}" ;;
      --store=*)   store="${1#*=}" ;;
      --agent=*)   agent="${1#*=}" ;;
      --slug=*)    slugs+=("${1#*=}") ;;
      --timeout=*) timeout_s="${1#*=}" ;;
      --write)     write=1 ;;   # the default now; still accepted
      --dry-run)   write=0 ;;
      --json)      JSON_MODE=1 ;;
      -h|--help)   _memory_usage; return 0 ;;
      *)           fail "$E_USAGE" "memory check: unknown argument: $1" ;;
    esac
    shift
  done
  case "$store" in all|mine|wiki) : ;; *) fail "$E_VALIDATION" "bad --store '$store' (all | mine | wiki)" ;; esac
  printf '%s' "$timeout_s" | grep -qE '^[0-9]+$' || fail "$E_VALIDATION" "--timeout must be whole seconds"
  [ "$timeout_s" -gt 0 ] || fail "$E_VALIDATION" "--timeout must be > 0"
  command -v python3 >/dev/null 2>&1 || fail "$E_GENERIC" "memory check needs python3"
  local resolved; resolved=$(_memory_resolve_roots "$store" "$agent" "$roots")
  [ -n "$resolved" ] || fail "$E_NOT_FOUND" "no memory roots to check (--roots/--store/--agent narrowed everything away)"

  local out rc=0
  out=$(FIVEDIVE_MC_TIMEOUT="$timeout_s" FIVEDIVE_MC_WRITE="$write" \
        FIVEDIVE_MC_SLUGS="$(printf '%s\n' ${slugs+"${slugs[@]}"})" \
        python3 - "$resolved" <<'MCPY'
import json, os, re, subprocess, sys, datetime

roots = [r for r in sys.argv[1].split(",") if r]
timeout = int(os.environ.get("FIVEDIVE_MC_TIMEOUT", "20"))
write = os.environ.get("FIVEDIVE_MC_WRITE") == "1"
want = {s.strip().replace("_", "-") for s in os.environ.get("FIVEDIVE_MC_SLUGS", "").split("\n") if s.strip()}
today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")

FM = re.compile(r"\A---\n(.*?)\n---\n", re.S)

def fm_field(front, key):
    # Both layouts: top-level (wiki) and nested two-space under `metadata:` (own
    # store). A quoted value may carry escaped quotes — a check IS shell text.
    m = re.search(r'^[ \t]*%s:[ \t]*(.*?)[ \t]*$' % re.escape(key), front, re.M)
    if not m:
        return ""
    v = m.group(1)
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return v

def files():
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, names in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for n in sorted(names):
                if n.endswith(".md") and n not in ("MEMORY.md", "index.md"):
                    yield os.path.join(dirpath, n)

results = []
for path in files():
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    m = FM.match(text)
    if not m:
        continue
    front = m.group(1)
    cmd = fm_field(front, "check")
    if not cmd:
        continue
    slug = fm_field(front, "name") or fm_field(front, "title") or os.path.basename(path)[:-3]
    if want and slug.replace("_", "-") not in want:
        continue
    # Read-only by construction at write time; still run with no stdin, in the
    # store's dir, so a relative path in a check means something stable.
    status, rc, detail = "unknown", None, ""
    # DIVE-3909. A checker the shell cannot PARSE never ran, so it is `unknown` —
    # the same net DIVE-3885 built for 127 and the timeout. Keying on the exit
    # code cannot do this: a malformed check dies with rc 2, and so does
    # `grep -q pat missing-file`, a perfectly good check going honestly red
    # (both measured). PARSEABILITY is the discriminator; the exit code is not.
    parse = subprocess.run(["bash", "-n", "-c", cmd], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if parse.returncode != 0:
        perr = parse.stderr.decode("utf-8", "replace").strip().splitlines()
        detail = "not a runnable command: " + (perr[-1][:160] if perr else "shell parse error")
    else:
      try:
        proc = subprocess.run(["bash", "-c", cmd], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout, cwd=os.path.dirname(path) or ".")
        rc = proc.returncode
        tail = proc.stdout.decode("utf-8", "replace").strip().splitlines()
        detail = tail[-1][:200] if tail else ""
        if rc == 0:
            status = "fresh"
        elif rc in (126, 127):
            # The checker itself is missing, or is not executable. That is an
            # instrument failure and says nothing about the fact.
            status = "unknown"
            detail = detail or ("command not found" if rc == 127 else "not executable")
        else:
            status = "stale"
      except subprocess.TimeoutExpired:
        status, detail = "unknown", "timed out after %ds" % timeout
      except OSError as e:
        status, detail = "unknown", str(e)

    if write:
        nested = re.search(r'^\s+check:', front, re.M) is not None
        ind = "  " if nested else ""
        new_front = front
        for key, val in (("check_status", status), ("checked_at", today),
                         ("check_rc", "" if rc is None else str(rc))):
            line = "%s%s: %s" % (ind, key, val)
            pat = re.compile(r'^[ \t]*%s:.*$' % re.escape(key), re.M)
            if pat.search(new_front):
                new_front = pat.sub(lambda _m, l=line: l, new_front, count=1)
            else:
                # Immediately after the `check:` line it belongs to, so the
                # stamp travels with the field even in the nested layout.
                ck = re.search(r'^[ \t]*check:.*$', new_front, re.M)
                at = ck.end()
                new_front = new_front[:at] + "\n" + line + new_front[at:]
        try:
            open(path, "w", encoding="utf-8").write("---\n" + new_front + "\n---\n" + text[m.end():])
        except OSError as e:
            detail = (detail + " | ").strip() + "could not stamp: %s" % e
    results.append({"slug": slug, "file": path, "status": status,
                    "rc": rc, "cmd": cmd, "detail": detail})

print(json.dumps(results))
MCPY
) || fail "$E_GENERIC" "memory check: the pass failed to run"

  local n_total n_fresh n_stale n_unknown
  n_total=$(printf '%s' "$out" | jq 'length')
  n_fresh=$(printf '%s' "$out" | jq '[.[]|select(.status=="fresh")]|length')
  n_stale=$(printf '%s' "$out" | jq '[.[]|select(.status=="stale")]|length')
  n_unknown=$(printf '%s' "$out" | jq '[.[]|select(.status=="unknown")]|length')

  if (( JSON_MODE )); then
    printf '%s' "$out" | jq -c --argjson w "$write" \
      '{ok:true, data:{written:($w==1), total:length, fresh:[.[]|select(.status=="fresh")]|length,
        stale:[.[]|select(.status=="stale")]|length, unknown:[.[]|select(.status=="unknown")]|length,
        results:.}}'
  else
    if [ "$n_total" -eq 0 ]; then
      echo "memory check: no atom in these roots carries a check: — nothing to re-derive"
      echo "  authored checks are written at compile time: 5dive memory add --check='<cmd>'"
      return 0
    fi
    printf '%s' "$out" | jq -r '.[] | (if .status=="fresh" then "✓ fresh   " elif .status=="stale" then "✗ STALE   " else "? unknown " end) + .slug + (if .detail=="" then "" else "  — " + .detail end)'
    echo
    echo "memory check: $n_total checked · $n_fresh fresh · $n_stale stale · $n_unknown unknown$([ "$write" -eq 1 ] && echo " (stamped)" || echo " (dry-run — nothing stamped)")"
    [ "$n_stale" -gt 0 ] && echo "  a STALE fact may be wrong, or its CHECK may be. Adjudicate it — nothing here deletes a memory."
    [ "$n_unknown" -gt 0 ] && echo "  UNKNOWN = the checker could not run. That is an instrument failure, not evidence about the fact."
  fi
  # A stale fact is a RESULT, not a crash. Without mark_reported the EXIT
  # backstop in lib/output.sh prints "exited 1 without reporting a reason … this
  # is a bug in the CLI" over a digest that already said exactly what happened —
  # and a nightly cron would read that banner instead of the finding.
  if [ "$n_stale" -gt 0 ]; then rc=1; mark_reported; fi
  return "$rc"
}

# ---- memory hygiene (DIVE-991) ---------------------------------------------
#
# A runnable hygiene pass over one or more memory stores (per-agent stores +
# the shared wiki). Surfaces four classes of rot the karpathy-method stores
# accumulate as they grow:
#   - index-drift : MEMORY.md/index.md points at a file that no longer exists,
#                   OR a memory file on disk that the index never lists (a search
#                   miss — the index is what gets read into context each session).
#   - dangling-link : a [[wiki-link]] whose target slug matches no file in the
#                     store. Forward-references are legal (the memory rules bless
#                     them), so these are warnings, not errors — a nudge to write
#                     the stub or fix a typo'd slug.
#   - stale-ref : a memory citing a source path / file:line that no longer exists
#                 in the codebase (agent-main's bloated MEMORY.md is the live
#                 motivating case). Only checked when a --code-root to verify
#                 against is available, so we never cry wolf on customer boxes.
#   - near-dup : two memories in the same store with high token overlap — a
#                merge candidate (the rules say update-in-place, don't duplicate).
#
# The scan itself is a pure function of (code-root, store dirs) and lives in
# _memory_scan_json so both `5dive memory doctor` and `5dive doctor` (memory
# category) share one implementation. Python (a doctor-checked dep) does the
# parsing — bash regex over frontmatter + link graphs is a foot-gun.

# _memory_scan_json <code-root|""> <store-dir> [store-dir...]
# Emits a JSON array of {store,file,kind,severity,message} findings on stdout.
# code-root "" (or a missing dir) skips stale-ref verification.
_memory_scan_json() {
  local code_root="$1"; shift
  python3 - "$code_root" "$@" <<'PYEOF'
import os, re, sys, json

code_root = sys.argv[1]
stores = sys.argv[2:]

INDEX_NAMES = ("MEMORY.md", "index.md")
LINK_RE  = re.compile(r'\[\[([^\]|#]+)')                 # [[slug]] / [[slug|Label]] / [[slug#h]]
MDLINK_RE = re.compile(r'\]\(([^)\s]+\.md)\)')           # ](file.md)
# path-ish token: optional dirs + name + code extension, optional :line
# Extensions ordered longest-first and closed with a boundary so 'page.tsx'
# isn't truncated to 'page.ts' (nor 'plugin.json' to 'plugin.js') by the
# alternation matching a shorter prefix.
PATH_RE = re.compile(
    r'(?<![\w./@-])((?:[\w.-]+/)*[\w.-]+\.'
    r'(?:tsx|ts|jsx|mjs|cjs|json|js|yaml|yml|sh|py|go|rs|sql|toml|conf|env))'
    r'(?![A-Za-z0-9])(?::(\d+))?')
WORD_RE = re.compile(r'[a-z0-9]+')
PRUNE = {"node_modules", ".git", "dist", "build", ".next", "vendor",
         "coverage", ".venv", "__pycache__", ".turbo"}

# Prebuild a basename set from the code tree so a source ref counts as "exists"
# if the file lives anywhere in the repo (memories cite repo-relative paths from
# assorted cwds). Empty set => skip stale-ref checks entirely.
basenames = set()
if code_root and os.path.isdir(code_root):
    seen = 0
    for dp, dns, fns in os.walk(code_root):
        dns[:] = [d for d in dns if d not in PRUNE]
        for fn in fns:
            basenames.add(fn)
            seen += 1
        if seen > 400000:
            break

def split_front(text):
    """Return (name, mtype, body). name/mtype default to '' if absent."""
    name, mtype = "", ""
    body = text
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            fm = text[3:end]
            body = text[end + 4:]
            in_meta = False
            for ln in fm.splitlines():
                s = ln.strip()
                if s.startswith("name:"):
                    name = s[5:].strip().strip('"\'')
                elif s.startswith("metadata:"):
                    in_meta = True
                elif in_meta and s.startswith("type:"):
                    mtype = s[5:].strip().strip('"\'')
    return name, mtype, body

def slugs_of(fname, name):
    out = {os.path.splitext(fname)[0].lower()}
    if name:
        out.add(name.lower())
    return out

def _lev(a, b):
    """Levenshtein distance, capped short-circuit not needed at these sizes."""
    if a == b:
        return 0
    la, lb = len(a), len(b)
    if abs(la - lb) > 2:      # caller only cares about dist <= 2
        return 3
    prev = list(range(lb + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1,
                           prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[lb]

def typo_suspect(target, slugs):
    """Return the nearest existing slug if `target` looks like a typo of it
    (small edit distance), else None. A dangling link with no near match is
    treated as an intentional forward-reference (the memory rules bless
    [[name]] with no file yet), so it stays quiet."""
    thresh = 2 if len(target) >= 5 else 1
    best, best_d = None, thresh + 1
    for s in slugs:
        d = _lev(target, s)
        if d < best_d:
            best, best_d = s, d
            if d == 1:
                break
    return best if best_d <= thresh else None

EVID_ITEM_RE = re.compile(r'^\s*-\s*"?([a-z]+:[^"\n]*?)"?\s*$')

def evidence_of(text):
    """Structural --evidence back-refs out of the frontmatter (DIVE-3106).
    Both layouts: top-level `evidence:` (wiki) and nested under `metadata:`
    (own store). Returns a list of '<kind>:<ref>' strings."""
    if not text.startswith("---"):
        return []
    end = text.find("\n---", 3)
    if end == -1:
        return []
    out, collecting = [], False
    for ln in text[3:end].splitlines():
        st = ln.strip()
        if re.match(r'^evidence:\s*$', st):
            collecting = True
            continue
        if collecting:
            m = EVID_ITEM_RE.match(ln)
            if m:
                out.append(m.group(1).strip())
                continue
            if st and not st.startswith("-"):
                collecting = False
    return out


def ref_exists(store_dir, token):
    if os.path.isabs(token):
        return os.path.exists(token)
    if code_root and os.path.exists(os.path.join(code_root, token)):
        return True
    return os.path.basename(token) in basenames

findings = []
def add(store, f, kind, sev, msg):
    findings.append({"store": store, "file": f, "kind": kind,
                     "severity": sev, "message": msg})

def store_name(store):
    """Stable, agent-unique label: '<home-user>/<project-slug>' for per-user
    stores (…/home/<user>/.claude/projects/<slug>/memory), else the parent dir
    name. Avoids collisions when two agents share a project slug."""
    parts = store.rstrip("/").split("/")
    if ".claude" in parts:
        ci = parts.index(".claude")
        user = parts[ci - 1] if ci >= 1 else "?"
        slug = parts[-2] if len(parts) >= 2 else parts[-1]
        return f"{user}/{slug}"
    return parts[-2] if len(parts) >= 2 else parts[-1]

roster = []
for store in stores:
    if not os.path.isdir(store):
        continue
    sname = store_name(store)
    roster.append(sname)
    try:
        entries = sorted(os.listdir(store))
    except OSError:
        continue
    mem_files = [f for f in entries
                 if f.endswith(".md") and f not in INDEX_NAMES]
    index_file = next((n for n in INDEX_NAMES
                       if os.path.isfile(os.path.join(store, n))), None)

    all_slugs = set()
    docs = {}   # fname -> (name, mtype, body, wordset)
    evid = {}   # fname -> ['<kind>:<ref>', ...]  (DIVE-3106 back-refs)
    for f in mem_files:
        try:
            with open(os.path.join(store, f), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        name, mtype, body = split_front(text)
        all_slugs |= slugs_of(f, name)
        docs[f] = (name, mtype, body, set(WORD_RE.findall(body.lower())))
        evid[f] = evidence_of(text)

    # --- index drift ---
    ROUTER_MARK = "<!-- router:generated -->"
    if index_file:
        try:
            with open(os.path.join(store, index_file), encoding="utf-8", errors="replace") as fh:
                idx = fh.read()
        except OSError:
            idx = ""
        indexed = {os.path.basename(t) for t in MDLINK_RE.findall(idx)}
        # DIVE-3821: a ROUTER deliberately does not name every atom — that is the
        # whole point of it, and the unindexed-file warn would fire once per atom
        # (613 of them on the store this was measured against), burying every real
        # finding under the fix. A dead LINK is still drift and still an error:
        # the router names few files, but the ones it does name must exist.
        #
        # The exemption is keyed on a marker only the GENERATOR emits, never on
        # prose in the file it exempts: an earlier cut matched the string
        # "5dive memory router", which the router's own instructions tell agents
        # to paste — so a genuinely flat index that merely MENTIONED the verb
        # disarmed this check for its whole store, silently. That is the same
        # silent-absence failure this row removes, relocated into the instrument
        # that watches for it (quinn, iteration 1).
        is_router = ROUTER_MARK in idx
        for t in sorted(indexed):
            if t not in INDEX_NAMES and not os.path.isfile(os.path.join(store, t)):
                add(sname, t, "index-drift", "error",
                    f"{index_file} links '{t}' but the file is missing")
        if not is_router:
            for f in mem_files:
                if f not in indexed:
                    add(sname, f, "index-drift", "warn",
                        f"on disk but not listed in {index_file} (won't load into context)")

    # --- dangling links + stale refs ---
    for f, (name, mtype, body, words) in docs.items():
        for m in LINK_RE.findall(body):
            target = m.strip().lower()
            if target and target not in all_slugs:
                # Only warn on likely typos (a near-match to an existing file).
                # A link with no near match is an intentional forward-ref
                # (marks something to write later) — stay quiet, not noise.
                near = typo_suspect(target, all_slugs)
                if near:
                    add(sname, f, "dangling-link", "warn",
                        f"[[{m.strip()}]] resolves to no file — did you mean "
                        f"[[{near}]]?")
        if basenames:
            checked = set()
            for tok, _line in PATH_RE.findall(body):
                if tok in checked or tok.startswith(("http", "@")):
                    continue
                checked.add(tok)
                if ("/" in tok or f"{tok}:" in body) and not ref_exists(store, tok):
                    add(sname, f, "stale-ref", "warn",
                        f"cites '{tok}' which no longer exists in the codebase")

    # --- evidence back-refs (DIVE-3106) ---
    # ONLY file: targets are mechanically walkable offline; task:/cmd:/url:/run:/
    # sha: need the board, a shell, or the network, so the doctor stays silent on
    # them rather than crying wolf. A memory with NO evidence is never flagged —
    # back-refs are additive and their absence is not a defect (lodar, 08-09).
    for f, refs in evid.items():
        for r in refs:
            if not r.startswith("file:"):
                continue
            tok = r[5:].strip()
            tok = re.sub(r':\d+$', '', tok)          # strip :line
            if not tok:
                add(sname, f, "evidence-ref", "warn",
                    "evidence 'file:' back-ref is empty")
            elif basenames and not ref_exists(store, tok):
                add(sname, f, "evidence-ref", "warn",
                    f"evidence back-ref '{tok}' no longer exists — the claim "
                    f"can't be re-walked")

    # --- near-duplicate (Jaccard over body word-sets, same store) ---
    names = list(docs)
    for i in range(len(names)):
        wi = docs[names[i]][3]
        if len(wi) < 12:
            continue
        for j in range(i + 1, len(names)):
            wj = docs[names[j]][3]
            if len(wj) < 12:
                continue
            inter = len(wi & wj)
            if not inter:
                continue
            jac = inter / len(wi | wj)
            if jac >= 0.6:
                add(sname, names[i], "near-dup", "warn",
                    f"{int(jac*100)}% token overlap with '{names[j]}' — merge candidate")

json.dump({"stores": roster, "findings": findings}, sys.stdout)
PYEOF
}

# _memory_doctor — `5dive memory doctor`: run the hygiene scan over the caller's
# own stores + wiki (or --roots / --agent), printing a report or --json.
_memory_doctor() {
  local roots="" agent="" code_root="${MEMORY_DOCTOR_CODE_ROOT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --roots=*)     roots="${1#*=}" ;;
      --agent=*)     agent="${1#*=}" ;;
      --code-root=*) code_root="${1#*=}" ;;
      -h|--help)     _memory_usage; return 0 ;;
      *)             fail "$E_USAGE" "memory doctor: unknown arg: $1" ;;
    esac
    shift
  done
  if [ -z "$roots" ]; then
    local own wiki
    own=$(_memory_own_roots "$agent")
    wiki=$(_memory_wiki_root)
    if [ -n "$own" ] && [ -n "$wiki" ]; then roots="$own,$wiki"
    else roots="${own}${wiki}"; fi
  fi
  [ -n "$roots" ] || fail "$E_NOT_FOUND" "no memory stores found (looked in ~/.claude/projects/*/memory); pass --roots="
  # Default code-root for stale-ref checks: the 5dive monorepo if it's here.
  if [ -z "$code_root" ]; then
    for d in /home/claude/projects/5dive "$HOME/projects/5dive"; do
      [ -d "$d" ] && { code_root="$d"; break; }
    done
  fi

  local dirs=() IFS=,
  for d in $roots; do [ -n "$d" ] && dirs+=("$d"); done
  unset IFS
  local scan
  scan=$(_memory_scan_json "$code_root" "${dirs[@]}")
  [ -n "$scan" ] || scan='{"stores":[],"findings":[]}'
  local findings
  findings=$(jq -c '.findings' <<<"$scan")

  if (( JSON_MODE )); then
    jq -cn --argjson f "$findings" --argjson stores "$(jq -c '.stores' <<<"$scan")" '{ok:true, data:{
      stores_scanned: ($stores | length),
      findings: $f,
      summary: ($f | {
        total: length,
        errors: [.[]|select(.severity=="error")]|length,
        warnings: [.[]|select(.severity=="warn")]|length,
        by_kind: (group_by(.kind) | map({(.[0].kind): length}) | add // {})
      })
    }}'
    return 0
  fi

  local n
  n=$(jq 'length' <<<"$findings")
  if [ "$n" -eq 0 ]; then
    echo "✓ memory hygiene: no issues across ${#dirs[@]} store(s)"
    return 0
  fi
  jq -r '
    group_by(.store) | .[] as $g |
    "── \($g[0].store) ──",
    ($g | sort_by(.kind)[] | "  [\(.severity)] \(.kind)  \(.file): \(.message)"),
    ""
  ' <<<"$findings"
  jq -r '{
    total: length,
    errors: [.[]|select(.severity=="error")]|length,
    warnings: [.[]|select(.severity=="warn")]|length
  } | "summary: \(.total) findings, \(.errors) error, \(.warnings) warn"' <<<"$findings"
  return 0
}

# cmd_memory — dispatch for the `memory` subcommand tree.
# ---- async transcript → atom consolidation (DIVE-3628, DIVE-726 phase 1) ----
#
# THE FAILURE THIS EXISTS FOR: a session window dies and everything it learned
# dies with it, because "compile before you close" is a HABIT and habits are not
# a mechanism. The motivating case is recorded in the wiki: the very discussion
# that produced this row was itself lost to an uncompiled window
# ([[tencentdb-agent-memory-vs-5dive-gap-analysis]]).
#
# SHAPE (their L0→L1→L3, ours): L0 is the raw jsonl transcript, already on disk
# and untouched. L1 is a bounded EXCERPT of it. L3 is a durable markdown atom in
# the agent's own store. The lift is idea-derived, not code-derived — no port.
#
# WHY IT IS ASYNC AND NOT A HOOK: a hook runs inside the dying session and pays
# for itself in that session's context. This pass runs from cron, out of band,
# against transcripts nobody is writing to — so the distillation cost never
# lands on a live window, and a session that dies ABRUPTLY (the actual failure)
# is still consolidated, because nothing is asked of it at death.
#
# SCOPE GUARDS HELD (DIVE-3628 body):
#   - reuses the existing stores. No database, no vector index, no CodeGraph.
#   - every write goes through _memory_add, so the secret tripwire, the dedup
#     warning, the frontmatter shape and the MEMORY.md index line are the SAME
#     ones a hand-compiled memory gets. There is no second write path to audit.
#   - deny-default sharing (DIVE-481): consolidate has NO --store flag and can
#     only ever write `mine`. Publishing to the shared wiki stays a deliberate,
#     curated act. An auto-extractor that could publish fleet-wide is the one
#     shape this must not have.
#
# The three things that make it safe to leave running unattended:
#   1. It never reads the LIVE session. A transcript touched inside --idle-min
#      is skipped. The pass itself runs in a session that is writing a
#      transcript; without this it would distill its own thinking.
#   2. It is idempotent. The ledger records (session, bytes); a re-run over an
#      unchanged transcript does no work and writes nothing. Belt and braces:
#      _memory_add refuses an existing slug without --force, so even a ledger
#      loss cannot duplicate an atom — it re-derives the same slug and conflicts.
#   3. It is bounded. --max-sessions per pass and --max-chars per transcript, so
#      the cron cost is flat whatever the store or the backlog does.
#
# THE DISTILLER IS A SEAM (--distiller). Default is a headless `claude -p`. The
# harness injects a stub, which is what makes the unit test genuinely offline
# rather than offline-looking: the module under test sends no live message, not
# merely the test file.

_MEM_CONSOLIDATE_PROMPT='You are distilling one finished agent session transcript into durable memory atoms.

Return ONLY a JSON object: {"atoms":[...]}. No prose, no code fence.

Each atom: {"type","name","description","body","confidence"}
  type        one of: reference | user | feedback | project
                reference = a durable FACT about the system or the world
                user      = a PREFERENCE or trait of the human you work for
                feedback  = a CONSTRAINT or correction on how work should be done
                project   = an EVENT or ongoing commitment not derivable from the repo
  name        kebab-case slug, <= 64 chars, specific enough to be unique
  description one line; this is what recall ranks on, so make it searchable
  body        2-6 sentences, self-contained. For feedback and project, follow the
              fact with a "**Why:**" line and a "**How to apply:**" line.
  confidence  high | medium | low

RULES
- Only DURABLE and NON-OBVIOUS facts. Nothing the repo, the git history or the
  task board already records. Nothing that only mattered inside this session.
- Absent anything durable, return {"atoms":[]}. An empty answer is a correct
  answer and is much better than filler.
- Convert relative dates ("yesterday", "last week") to absolute ones.
- Never include a token, key, password or credential value. Reference where a
  secret LIVES, never what it is.
- At most 5 atoms.'

# _memory_consolidate_excerpt <jsonl> <max-chars>
# L0 → L1: a bounded plain-text excerpt of one transcript. Tool payloads are the
# bulk of a jsonl and almost never the durable part, so they collapse to a name;
# what survives is what a person said and what the agent concluded.
_memory_consolidate_excerpt() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
path, cap = sys.argv[1], int(sys.argv[2])
out = []
try:
    fh = open(path, encoding="utf-8", errors="replace")
except OSError:
    sys.exit(0)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("type") not in ("user", "assistant"):
            continue
        msg = rec.get("message") or {}
        content = msg.get("content")
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            parts = []
            for blk in content:
                if not isinstance(blk, dict):
                    continue
                if blk.get("type") == "text":
                    parts.append(blk.get("text", ""))
                elif blk.get("type") == "tool_use":
                    parts.append("[tool: %s]" % blk.get("name", "?"))
                elif blk.get("type") == "tool_result":
                    parts.append("[tool result]")
        else:
            continue
        txt = "\n".join(p for p in parts if p and p.strip())
        if not txt.strip():
            continue
        out.append("%s: %s" % (rec.get("type"), txt.strip()))
text = "\n\n".join(out)
# Over the cap, keep the HEAD and the TAIL. The opening carries what the session
# was for and the close carries what it concluded; the middle is the tool churn.
if len(text) > cap:
    half = cap // 2
    text = text[:half] + "\n\n[... transcript middle elided ...]\n\n" + text[-half:]
sys.stdout.write(text)
PYEOF
}

# _memory_consolidate_parse — validate the distiller's JSON, emit one
# TSV row per ACCEPTED atom (type, name, description, confidence, body-b64).
# Anything malformed is dropped with a warning on stderr rather than written: a
# distiller is a model, so the parse layer is a validation boundary, not a
# formality. base64 keeps a multi-line body inside one row.
#
# EXIT 3 = the distiller produced nothing parseable (crashed, was not logged in,
# answered in prose). That is NOT the same event as a session with nothing
# durable in it, and collapsing the two is the whole succeeding-in-appearance
# trap: an unauthed `claude --print` prints "Not logged in" and EXITS 0, so a
# fleet-wide auth lapse would read as "the sessions were quiet" forever. Measured
# on this box 2026-08-20.
_memory_consolidate_parse() {
  # The payload arrives as a FILE, not on stdin: `python3 - <<PY` already spends
  # stdin on the program text, so a parser that read sys.stdin would silently
  # see the python source and drop every atom. It fails as "found nothing",
  # which is exactly the shape a working pass over a quiet session has.
  python3 - "$1" <<'PYEOF'
import base64, json, re, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read().strip()
# Tolerate a fenced block or leading prose — cheaper than failing a whole pass.
m = re.search(r'\{.*\}', raw, re.S)
if not m:
    sys.stderr.write("consolidate: distiller returned no JSON object\n")
    sys.exit(3)
try:
    doc = json.loads(m.group(0))
except ValueError as e:
    sys.stderr.write("consolidate: distiller JSON did not parse (%s)\n" % e)
    sys.exit(3)
atoms = doc.get("atoms")
if not isinstance(atoms, list):
    sys.stderr.write("consolidate: distiller JSON has no atoms[] array\n")
    sys.exit(3)
TYPES = {"reference", "user", "feedback", "project"}
CONF = {"high", "medium", "low"}
for a in atoms[:5]:
    if not isinstance(a, dict):
        continue
    t = str(a.get("type", "")).strip()
    n = str(a.get("name", "")).strip()
    d = " ".join(str(a.get("description", "")).split())
    b = str(a.get("body", "")).strip()
    c = str(a.get("confidence", "")).strip() or "medium"
    if t not in TYPES:
        sys.stderr.write("consolidate: dropped atom with bad type %r\n" % t); continue
    if not re.match(r'^[a-z0-9][a-z0-9-]{0,63}$', n):
        sys.stderr.write("consolidate: dropped atom with bad slug %r\n" % n); continue
    if not d or not b:
        sys.stderr.write("consolidate: dropped atom %r with empty description/body\n" % n); continue
    if c not in CONF:
        c = "medium"
    print("\t".join([t, n, d, c, base64.b64encode(b.encode()).decode()]))
PYEOF
}

_memory_consolidate() {
  local max_sessions=3 idle_min=30 max_chars=20000 distiller="" dry=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-sessions=*) max_sessions="${1#*=}" ;;
      --idle-min=*)     idle_min="${1#*=}" ;;
      --max-chars=*)    max_chars="${1#*=}" ;;
      --distiller=*)    distiller="${1#*=}" ;;
      --dry-run)        dry=1 ;;
      --force)          force=1 ;;
      -h|--help)        _memory_usage; return 0 ;;
      *)                fail "$E_USAGE" "memory consolidate: unknown arg: $1" ;;
    esac
    shift
  done
  printf '%s' "$max_sessions" | grep -qE '^[0-9]+$' || fail "$E_VALIDATION" "--max-sessions must be a number"
  printf '%s' "$idle_min"     | grep -qE '^[0-9]+$' || fail "$E_VALIDATION" "--idle-min must be a number (minutes)"
  printf '%s' "$max_chars"    | grep -qE '^[0-9]+$' || fail "$E_VALIDATION" "--max-chars must be a number"
  [ "$max_chars" -ge 500 ] || fail "$E_VALIDATION" "--max-chars below 500 leaves nothing to distill"

  # Own store only. Same resolution rule as `memory add` so both verbs agree on
  # which dir "mine" means; never invent a store the harness did not bootstrap.
  local dir="" d
  for d in "$HOME"/.claude/projects/*/memory; do
    [ -d "$d" ] || continue
    [ -z "$dir" ] && dir="$d"
    [ -f "$d/MEMORY.md" ] && { dir="$d"; break; }
  done
  [ -n "$dir" ] || fail "$E_NOT_FOUND" "no memory store found under ~/.claude/projects/*/memory"

  local ledger="$dir/.consolidated.tsv"
  [ -f "$ledger" ] || : > "$ledger"

  # Single-flight. Cron can fire a second pass while the first is still inside a
  # distiller call; two passes over the same transcript would race the ledger and
  # double-write. Non-blocking: the second pass declines rather than queues.
  local lockf="$dir/.consolidate.lock"
  # BRACES MATTER: `exec 201>f 2>/dev/null` is TWO permanent redirections, and the
  # second one kills stderr for the whole rest of the pass — every tripwire
  # refusal and dedup warning would vanish and the run would read as "found
  # nothing". Grouping scopes the 2>/dev/null to the open attempt alone.
  { exec 201>"$lockf"; } 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    flock -n 201 || fail "$E_CONFLICT" "another consolidate pass holds $lockf — declining rather than racing it"
  fi

  if [ -z "$distiller" ]; then
    distiller="${FIVEDIVE_MEMORY_DISTILLER:-}"
  fi
  if [ -z "$distiller" ]; then
    command -v claude >/dev/null 2>&1 || [ -x /home/claude/.local/bin/claude ] \
      || fail "$E_NOT_FOUND" "no distiller: pass --distiller=<cmd> or install the claude CLI"
    local _cl; _cl=$(command -v claude 2>/dev/null || echo /home/claude/.local/bin/claude)
    distiller="$_cl --print"
  fi

  local considered=0 processed=0 written=0 refused=0 dupes=0 skipped_live=0 skipped_done=0
  local distill_failed=0
  local -a written_files=()
  local now; now=$(date +%s)
  local t
  # Newest first: the most recent dead session is the one whose loss hurts most.
  while IFS= read -r t; do
    [ -f "$t" ] || continue
    [ "$processed" -ge "$max_sessions" ] && break
    considered=$((considered+1))
    local sid; sid=$(basename "$t" .jsonl)
    local mt; mt=$(stat -c %Y "$t" 2>/dev/null || echo 0)
    local bytes; bytes=$(stat -c %s "$t" 2>/dev/null || echo 0)
    # (1) never the live session — including the one this pass is running in.
    if [ $(( (now - mt) / 60 )) -lt "$idle_min" ]; then
      skipped_live=$((skipped_live+1)); continue
    fi
    # (2) idempotence — same session at the same byte count is already distilled.
    if [ "$force" -ne 1 ] && grep -qF "$(printf '%s\t%s\t' "$sid" "$bytes")" "$ledger" 2>/dev/null; then
      skipped_done=$((skipped_done+1)); continue
    fi
    local excerpt; excerpt=$(_memory_consolidate_excerpt "$t" "$max_chars") || excerpt=""
    if [ -z "$(printf '%s' "$excerpt" | tr -d '[:space:]')" ]; then
      skipped_done=$((skipped_done+1)); continue
    fi
    processed=$((processed+1))
    local rawf; rawf=$(mktemp "${TMPDIR:-/tmp}/5dive-mem-distill.XXXXXX") || continue
    printf '%s\n\n---- TRANSCRIPT ----\n%s\n' "$_MEM_CONSOLIDATE_PROMPT" "$excerpt" \
      | eval "$distiller" > "$rawf" 2>/dev/null || :
    # `x=$(cmd); rc=$?` ABORTS under the bundle's `set -euo pipefail` — errexit
    # fires on the assignment before $? is ever read. The harness runs `set +e`
    # (corpus convention) and so is structurally blind to this; measured against
    # the built bundle 2026-08-20. `|| rc=$?` is the form that survives both.
    local rows prc=0
    rows=$(_memory_consolidate_parse "$rawf") || prc=$?
    rm -f "$rawf"
    if [ "$prc" -eq 3 ]; then
      # No ledger row on a distiller failure. Stamping one would retire the
      # transcript permanently on a transient auth blip — the backlog would be
      # silently consumed by an outage and never re-tried.
      distill_failed=$((distill_failed+1))
      continue
    fi
    local n_written=0 n_refused=0 n_dupe=0
    while IFS=$'\t' read -r a_type a_name a_desc a_conf a_body64; do
      [ -n "${a_name:-}" ] || continue
      local a_body; a_body=$(printf '%s' "$a_body64" | base64 -d 2>/dev/null) || continue
      if [ "$dry" -eq 1 ]; then
        (( JSON_MODE )) || echo "  would write: [$a_type] $a_name — $a_desc"
        n_written=$((n_written+1)); continue
      fi
      # The ONE write path. No --store: consolidate cannot publish (DIVE-481).
      local addout addrc=0
      addout=$(printf '%s\n' "$a_body" | ( _memory_add \
          --name="$a_name" --type="$a_type" --description="$a_desc" \
          --confidence="$a_conf" \
          --provenance="distilled from session $sid ($(date -u +%F))" \
          --evidence="run:$sid" \
          --no-check="auto-distilled by memory consolidate — no author present to write a check (DIVE-3885)" ) 2>&1) || addrc=$?
      if [ "$addrc" -eq 0 ]; then
        n_written=$((n_written+1))
        written_files+=("$dir/${a_type}_$(printf '%s' "$a_name" | tr '-' '_').md")
        # DIVE-3711: NOT in --json. This is the one line only a PRODUCING pass
        # prints, so leaving it on stdout means the envelope is unparseable
        # exactly when atoms were written — `jq -s` over "  ✓ …" + {…} errors,
        # the sweep reads no atom count, and a seat that worked is filed under
        # could-not-run with zero atoms. That is this row's defect wearing the
        # fix's clothes: the headline number stays zero for the working case.
        (( JSON_MODE )) || echo "  ✓ [$a_type] $a_name"
      elif printf '%s' "$addout" | grep -q 'already exists'; then
        n_dupe=$((n_dupe+1))
      else
        # A refusal is a RESULT, not an error to swallow: the secret tripwire
        # firing on a distilled atom is exactly the case we want counted and
        # visible, and it must never look like "nothing was found".
        n_refused=$((n_refused+1))
        echo "  ✗ refused [$a_type] $a_name — $(printf '%s' "$addout" | tail -1)" >&2
      fi
    done <<< "$rows"
    written=$((written+n_written)); refused=$((refused+n_refused)); dupes=$((dupes+n_dupe))
    # Ledger last, and only on a real pass: a dry run must leave the backlog
    # exactly as it found it, or the first real pass silently skips everything.
    if [ "$dry" -eq 0 ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$bytes" "$(date -u +%FT%TZ)" "$n_written" "$n_refused" >> "$ledger"
    fi
  done < <(ls -1t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null)

  # DIVE-3711: a pass in which EVERY attempted distillation failed wrote nothing,
  # and must not exit 0. The old contract — rc 0 whatever happened — is exactly
  # what let the heartbeat log "13 seat(s) distilled" every 6h for four days
  # while the fleet-wide ledger held ONE row: the sweep incremented its success
  # counter on rc, and rc could not tell "wrote atoms" from "the CLI is not
  # logged in". A PARTIAL failure still exits 0 (real work landed) and stays loud
  # on stderr and in the JSON — only a wholly-failed pass is a failed pass, and
  # a pass with nothing to distil (processed=0) is not a failure at all.
  local pass_rc=0
  if [ "$distill_failed" -gt 0 ] && [ "$distill_failed" -ge "$processed" ]; then
    pass_rc=$E_AUTH_REQUIRED
  fi

  if (( JSON_MODE )); then
    jq -nc --argjson considered "$considered" --argjson processed "$processed" \
       --argjson written "$written" --argjson refused "$refused" --argjson dupes "$dupes" \
       --argjson live "$skipped_live" --argjson done "$skipped_done" \
       --argjson dfail "$distill_failed" \
       --argjson ok "$([ "$pass_rc" -eq 0 ] && echo true || echo false)" \
       --arg store "$dir" --arg ledger "$ledger" --argjson dry "$([ "$dry" -eq 1 ] && echo true || echo false)" \
      '{ok:$ok, data:{store:$store, ledger:$ledger, dry_run:$dry, considered:$considered,
        processed:$processed, atoms_written:$written, atoms_refused:$refused,
        atoms_duplicate:$dupes, skipped_live:$live, skipped_consolidated:$done,
        distiller_failed:$dfail}}'
  else
    echo "consolidate: $processed session(s) distilled → $written atom(s) into $dir"
    echo "  skipped: $skipped_live live (touched < ${idle_min}m ago) · $skipped_done already consolidated · $dupes duplicate atom(s)"
    # Trailing `[ x ] && echo` is the last command of the function under errexit
    # when the test is false — it would return 1 and abort the caller. `|| :`.
    [ "$refused" -gt 0 ] && echo "  refused: $refused atom(s) — see stderr (tripwire/validation)" >&2 || :
    # Loud, and never folded into "0 atoms": a distiller that cannot answer is a
    # different event from a session with nothing worth keeping.
    [ "$distill_failed" -gt 0 ] && echo "  DISTILLER FAILED on $distill_failed session(s) — not ledgered, will retry next pass (is the CLI logged in?)" >&2 || :
    [ "$dry" -eq 1 ] && echo "  (dry run — nothing written, ledger untouched)" || :
  fi
  # An INTENTIONAL non-zero exit has to claim the reason, or the EXIT-trap
  # backstop overprints a second envelope ("exited 6 without reporting a reason —
  # this is a bug in the CLI") after the real one. Only `fail`/`policy_refuse`
  # set that flag on their own, and this path uses neither: the pass reported
  # itself, fully, in the block above. Measured against the BUILT bundle — the
  # corpus harness sources the function directly and never sees the trap.
  [ "$pass_rc" -eq 0 ] || mark_reported
  return "$pass_rc"
}

# memory get — DIVE-3821 stage 2: fetch full bodies for the slugs stage 1 named.
#
# The always-loaded index does not scale (main: 634 atoms, 40,991 bytes against a
# 24.4 KB load limit — the tail is silently dropped). claude-mem (Apache-2.0)
# solves the same problem by never loading a flat index: `search` returns rows,
# `get_observations(ids)` fetches only what was chosen. Same idea, our store —
# no new dependency, the ranking and the lifecycle envelope are unchanged.
_memory_get() {
  local slugs=() maxtok=8000 roots="" store="all" agent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-tokens=*) maxtok="${1#*=}" ;;
      --roots=*)      roots="${1#*=}" ;;
      --store=*)      store="${1#*=}" ;;
      --agent=*)      agent="${1#*=}" ;;
      -h|--help)      _memory_usage; return 0 ;;
      --*)            fail "$E_USAGE" "memory get: unknown flag: $1" ;;
      *)              slugs+=("$1") ;;
    esac
    shift
  done
  [ "${#slugs[@]}" -gt 0 ] || { _memory_usage; fail "$E_USAGE" "memory get: at least one slug is required (get them from \`memory search --index\`)"; }
  require_node "memory get"
  case "$store" in all|mine|wiki) : ;; *) fail "$E_VALIDATION" "bad --store '$store' (all | mine | wiki)" ;; esac
  if [ -n "$roots" ] && { [ "$store" != "all" ] || [ -n "$agent" ]; }; then
    fail "$E_USAGE" "--roots overrides scoping — don't combine it with --store/--agent"
  fi
  roots="$(_memory_resolve_roots "$store" "$agent" "$roots")"

  local js; js="$(mktemp -t 5dive-memget.XXXXXX.mjs)" || fail "$E_GENERIC" "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -f '$js'" RETURN
  cat > "$js" <<'MEMGETJS'
// DIVE-3821 — fetch-by-slug over the same roots `memory search` ranks.
import fs from "node:fs";
import path from "node:path";
const argv = process.argv.slice(2);
const opt = (k, d) => { const h = argv.find((a) => a.startsWith(`--${k}=`)); return h ? h.slice(k.length + 3) : d; };
const wanted = argv.filter((a) => !a.startsWith("--"));
const MAX_TOKENS = Number(opt("max-tokens", 8000));
const ROOTS = String(opt("roots", "")).split(",").filter(Boolean);
const estTokens = (s) => Math.ceil(s.length / 4);
function mdFiles(root) {
  const out = [];
  const walk = (d) => {
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) { const full = path.join(d, e.name); if (e.isDirectory()) walk(full); else if (e.isFile() && e.name.endsWith(".md")) out.push(full); }
  };
  walk(root); return out;
}
// Slug normalisation: a row prints the frontmatter `name` when there is one and
// the basename otherwise, and the two differ by - vs _ often enough that an
// exact-match-only fetch would refuse slugs it had just printed.
const norm = (s) => String(s).toLowerCase().replace(/\.md$/, "").replace(/[^a-z0-9]+/g, "");
const byKey = new Map();   // normalised key -> file (first writer wins; both keys registered)
const files = [];
for (const root of ROOTS) for (const f of mdFiles(root)) files.push(f);
for (const f of files) {
  let text = ""; try { text = fs.readFileSync(f, "utf-8"); } catch { continue; }
  const fm = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  const keys = [path.basename(f).replace(/\.md$/, "")];
  if (fm) {
    const n = /^\s*name:\s*["']?(.+?)["']?\s*$/m.exec(fm[1]);
    if (n) keys.push(n[1].trim());
  }
  for (const k of keys) { const nk = norm(k); if (nk && !byKey.has(nk)) byKey.set(nk, f); }
}
let used = 0, found = 0;
const missing = [];
for (const w of wanted) {
  const f = byKey.get(norm(w));
  if (!f) { missing.push(w); continue; }
  let body = ""; try { body = fs.readFileSync(f, "utf-8"); } catch { missing.push(w); continue; }
  const home = process.env.HOME || "";
  const rel = f.replace(`${home}/.claude/projects/`, "").replace(`${home}/projects/5dive/`, "").replace("/home/claude/projects/5dive/", "");
  let cost = estTokens(body);
  let note = "";
  if (used + cost > MAX_TOKENS) {
    const room = Math.max(0, MAX_TOKENS - used) * 4;
    if (room < 400) { console.log(`\n══ ${w} ══  (SKIPPED — token ceiling ${MAX_TOKENS} reached; re-run with fewer slugs or --max-tokens=)`); continue; }
    body = body.slice(0, room);
    note = `\n… TRUNCATED at the ${MAX_TOKENS}-token ceiling — raise --max-tokens= or fetch this slug alone.`;
    cost = estTokens(body);
  }
  used += cost; found++;
  console.log(`\n══ ${w}  ›  ${rel} ══\n`);
  console.log(body.trimEnd() + note);
}
if (missing.length) {
  // A miss names near neighbours: the usual cause is a slug typed from memory
  // rather than copied off a row, and a bare "not found" sends the caller back
  // to a full search it already paid for.
  const all = [...byKey.keys()];
  for (const m of missing) {
    const nm = norm(m);
    const near = all.filter((k) => k.includes(nm.slice(0, Math.max(4, Math.floor(nm.length / 2)))) || nm.includes(k)).slice(0, 5);
    console.error(`memory get: no atom for '${m}'${near.length ? ` — did you mean: ${near.join(", ")}` : ""}`);
  }
}
console.log(`\n— fetched ${found}/${wanted.length} slug(s), ~${used} tokens —`);
// Every slug missing is a failed fetch; a partial fetch still delivered work.
process.exit(found === 0 ? 4 : 0);
MEMGETJS
  node "$js" "${slugs[@]}" --max-tokens="$maxtok" --roots="$roots"
}

# memory router — DIVE-3821: rebuild an always-loaded MEMORY.md as a ROUTER.
#
# The flat index is a treadmill: every atom added grows the file every session
# loads, and past the limit the loader drops the TAIL silently — so the oldest
# facts stop existing without a single error line. The fix is to stop
# enumerating. The router carries the recall protocol, a typed topic map, and
# the newest atoms; the other N-hundred stay on disk, unchanged, reachable
# through `memory search --index` + `memory get`. NOTHING is deleted.
_memory_router() {
  local root="" agent="" budget=20000 recent=20 write=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root=*)    root="${1#*=}" ;;
      --agent=*)   agent="${1#*=}" ;;
      --budget=*)  budget="${1#*=}" ;;
      --recent=*)  recent="${1#*=}" ;;
      --write)     write=1 ;;
      -h|--help)   _memory_usage; return 0 ;;
      *)           fail "$E_USAGE" "memory router: unknown argument: $1" ;;
    esac
    shift
  done
  require_node "memory router"
  if [ -z "$root" ]; then
    # Own (or --agent's) primary store = the one with the most atoms.
    local cand best="" bestn=-1 n
    local IFS=,
    for cand in $(_memory_own_roots "$agent"); do
      n=$(find "$cand" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
      if [ "$n" -gt "$bestn" ]; then bestn="$n"; best="$cand"; fi
    done
    unset IFS
    root="$best"
  fi
  [ -n "$root" ] && [ -d "$root" ] || fail "$E_NOT_FOUND" "no memory store found${agent:+ for agent '$agent'} — pass --root=<dir>"
  [ -w "$root" ] || [ "$write" -eq 0 ] || fail "$E_PERMISSION" "can't write $root/MEMORY.md (per-user 0600 — run as that agent, or as root)"

  local js; js="$(mktemp -t 5dive-memrouter.XXXXXX.mjs)" || fail "$E_GENERIC" "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -f '$js'" RETURN
  cat > "$js" <<'MEMROUTERJS'
// DIVE-3821 — generate a bounded router in place of a flat, truncating index.
import fs from "node:fs";
import path from "node:path";
const argv = process.argv.slice(2);
const opt = (k, d) => { const h = argv.find((a) => a.startsWith(`--${k}=`)); return h ? h.slice(k.length + 3) : d; };
const ROOT = opt("root", "");
const BUDGET = Number(opt("budget", 20000));
const RECENT = Number(opt("recent", 20));
const WRITE = String(opt("write", "0")) === "1";
const INDEX = path.join(ROOT, "MEMORY.md");

const STOP = new Set("a an and are as at be but by for from has have if in into is it its of on or that the than then there these this to was were will with you your our we not no never only own one two md the its it's about after against all also any because been before being both can cannot did do does doing done down during each few first for further had having here how i if into itself just more most must my nor now off once other out over own same should so some such take that's their them themselves they this those through too under until up very what when where which while who whom why will would".split(/\s+/));
const tokenize = (s) => String(s).toLowerCase().replace(/`[^`]*`/g, " ").replace(/[^a-z0-9]+/g, " ").split(" ").filter((t) => t.length > 2 && !STOP.has(t) && !/^\d+$/.test(t));

let entries;
try { entries = fs.readdirSync(ROOT, { withFileTypes: true }); } catch (e) { console.error(`memory router: cannot read ${ROOT}`); process.exit(5); }
const atoms = [];
for (const e of entries) {
  if (!e.isFile() || !e.name.endsWith(".md")) continue;
  if (e.name === "MEMORY.md") continue;
  const full = path.join(ROOT, e.name);
  let text = "", st;
  try { text = fs.readFileSync(full, "utf-8"); st = fs.statSync(full); } catch { continue; }
  const fm = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  const field = (k) => { if (!fm) return ""; const m = new RegExp(`^\\s*${k}:\\s*["']?(.+?)["']?\\s*$`, "m").exec(fm[1]); return m ? m[1].trim() : ""; };
  let desc = field("description").replace(/^>\s*/, "");
  if (!desc) {
    for (const l of text.replace(fm ? fm[0] : "", "").split("\n")) {
      const t = l.trim();
      if (!t || t.startsWith("#") || t.startsWith("|") || t.startsWith("-")) continue;
      desc = t; break;
    }
  }
  let type = field("type") || (fm ? (/^\s*metadata:/m.test(fm[1]) && /type:\s*(\w+)/m.exec(fm[1]) || [])[1] : "") || "";
  if (!type) { const p = e.name.split("_")[0]; type = ["user", "feedback", "project", "reference"].includes(p) ? p : "other"; }
  atoms.push({ slug: field("name") || e.name.replace(/\.md$/, ""), file: e.name, desc, type, mtime: st.mtimeMs, bytes: st.size });
}
atoms.sort((a, b) => b.mtime - a.mtime);

// Carry a hand-written block over verbatim. Direction, standing orders, the one
// or two lines an agent wants in EVERY context — a generated router that eats
// those is a regression, so the generator never owns them.
const KEEP_RE = /<!--\s*router:keep-start\s*-->([\s\S]*?)<!--\s*router:keep-end\s*-->/;
let keep = "";
let oldBytes = 0;
try { const cur = fs.readFileSync(INDEX, "utf-8"); oldBytes = Buffer.byteLength(cur); const m = KEEP_RE.exec(cur); if (m) keep = m[1].trim(); } catch {}

const byType = new Map();
for (const a of atoms) { if (!byType.has(a.type)) byType.set(a.type, []); byType.get(a.type).push(a); }
const typeOrder = [...byType.keys()].sort((x, y) => byType.get(y).length - byType.get(x).length);

function topics(list, k) {
  const c = new Map();
  for (const a of list) for (const t of new Set(tokenize(`${a.slug} ${a.desc}`))) c.set(t, (c.get(t) ?? 0) + 1);
  return [...c.entries()].filter(([, n]) => n >= 2).sort((a, b) => b[1] - a[1]).slice(0, k).map(([t, n]) => `${t}·${n}`);
}
// ROOT is <home>/.claude/projects/<slug>/memory — four levels up is the home
// directory, and the seat name is its basename. Three levels reached `.claude`
// and every regenerated router was titled "(.claude)".
const AGENT = path.basename(path.dirname(path.dirname(path.dirname(path.dirname(ROOT))))).replace(/^agent-/, "") || "this seat";

function build(kTopics, nRecent) {
  const L = [];
  L.push(`# Memory router (${AGENT}) — ${atoms.length} atoms`);
  // Structural marker. `memory doctor` keys its unindexed-file exemption on THIS
  // and on nothing else, so the exemption cannot be handed to a flat index by
  // quoting the router's own documentation. Do not remove it by hand.
  L.push("<!-- router:generated -->");
  L.push("");
  L.push("**This file is not the map. It is the router.** Enumerating every atom here is what");
  L.push("made the old index outgrow the load limit — past it the loader drops the TAIL with no");
  L.push("error, so the oldest facts stop existing silently. Nothing was deleted to shrink this:");
  L.push(`all ${atoms.length} atoms are on disk in this directory, reachable in two stages.`);
  L.push("");
  L.push("```");
  L.push('5dive memory search --index "<topic>"      # stage 1: slug + one line + score');
  L.push("5dive memory get <slug> [<slug>...]        # stage 2: full bodies, only what you chose");
  L.push("```");
  L.push("");
  L.push("**An empty stage-1 result is evidence of absence; a short router is not.** Search before");
  L.push("you conclude a fact is not here, and search with the words the FACT would use, not the");
  L.push("words your task uses.");
  if (keep) { L.push(""); L.push("<!-- router:keep-start -->"); L.push(keep); L.push("<!-- router:keep-end -->"); }
  L.push("");
  L.push("## What is in the store");
  L.push("");
  for (const t of typeOrder) {
    const list = byType.get(t);
    const tt = topics(list, kTopics);
    L.push(`- **${t}** — ${list.length} atoms${tt.length ? ` · ${tt.join(", ")}` : ""}`);
  }
  if (nRecent > 0) {
    L.push("");
    L.push(`## Newest ${Math.min(nRecent, atoms.length)} atoms`);
    L.push("");
    L.push("(The only atoms named by slug here. Everything older is found by searching.)");
    L.push("");
    for (const a of atoms.slice(0, nRecent)) {
      let d = a.desc || "";
      if (d.length > 100) d = d.slice(0, 100) + " …";
      L.push(`- \`${a.slug}\`${d ? ` — ${d}` : ""}`);
    }
  }
  L.push("");
  L.push(`_Generated by \`5dive memory router\` on ${new Date().toISOString().slice(0, 10)} (DIVE-3821). Re-run it after a \`memory consolidate\` pass; hand edits belong between the router:keep markers._`);
  L.push("");
  return L.join("\n");
}

// Fit to budget by shrinking what is cheapest to lose first: the recent list,
// then the topic keywords. The preamble is the protocol — it never shrinks,
// because a router that cannot say how to fetch is worse than no router.
let out = "", kT = 14, nR = RECENT;
for (;;) {
  out = build(kT, nR);
  if (Buffer.byteLength(out) <= BUDGET) break;
  if (nR > 0) { nR = Math.max(0, nR - 5); continue; }
  if (kT > 3) { kT -= 3; continue; }
  break;   // preamble + one line per type is the floor; report it honestly below.
}
const newBytes = Buffer.byteLength(out);
if (WRITE) {
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const bak = `${INDEX}.pre-router-${stamp}`;
  try { if (fs.existsSync(INDEX)) fs.copyFileSync(INDEX, bak); } catch (e) { console.error(`memory router: backup failed (${e.message}) — refusing to overwrite`); process.exit(5); }
  fs.writeFileSync(INDEX, out);
  console.log(`memory router: wrote ${INDEX}`);
  console.log(`  ${atoms.length} atoms indexed · ${oldBytes} B → ${newBytes} B (budget ${BUDGET}) · ${nR} named, ${atoms.length - nR} reachable by search only`);
  if (oldBytes) console.log(`  previous index kept at ${bak}`);
  if (newBytes > BUDGET) console.error(`  WARNING: ${newBytes} B still over the ${BUDGET} B budget with the recent list and keywords at their floor`);
} else {
  console.log(out);
  console.error(`\n— dry run: ${atoms.length} atoms · ${oldBytes} B → ${newBytes} B (budget ${BUDGET}). Pass --write to replace MEMORY.md (the old one is backed up).`);
}
MEMROUTERJS
  node "$js" --root="$root" --budget="$budget" --recent="$recent" --write="$write"
}

cmd_memory() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    search)      _memory_search "$@" ;;
    get|fetch)   _memory_get "$@" ;;
    router)      _memory_router "$@" ;;
    add|compile) _memory_add "$@" ;;
    check)       _memory_check "$@" ;;
    doctor|hygiene) _memory_doctor "$@" ;;
    consolidate|distill) _memory_consolidate "$@" ;;
    ""|-h|--help) _memory_usage ;;
    *)           _memory_usage; fail "$E_USAGE" "memory: unknown subcommand: $sub" ;;
  esac
}
