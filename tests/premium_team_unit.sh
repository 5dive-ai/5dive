#!/usr/bin/env bash
# DIVE-9109 — a PREMIUM team file: signed by 5dive's team key, stamped with its
# buyer, checked by `5dive team import <file>`.
#
# WHAT IS PINNED, through the real producer (packaging/premium-team/build.sh),
# the real unwrap/verify (src/cmd_team_pack.sh, src/lib/offline_update.sh's root
# chain) and the real `team import` → `up` path (agent CLI calls stubbed):
#   B1  the producer makes ONE .gz: manifest.json, manifest.sig, payload/team.tar.gz;
#       the buyer is on the signed wrapper AND inside the team's own manifest;
#   B1e the producer takes the ceremony page's PUBLIC file as --trust;
#   B2  the producer refuses a key the certificate does not approve, a
#       certificate for another kind, and a gzip that is not a team bundle;
#   V1  a good file imports: every seat comes up, the import names the buyer,
#       and the box keeps the signed label (version, buyer) without the trust blob;
#   R1  the team changed after signing                       -> refused
#   R2  the label changed after signing (buyer renamed)       -> refused
#   R3  signed by an OFFICE APP key the root certified        -> refused
#   R4  a team key certified by something other than the root -> refused
#   R5  an expired team key                                   -> refused
#   R6  a revoked team key                                    -> refused
#   R7  a box with no root key                                -> refused
#   R8  an extra member in the wrapper                        -> refused
#   R9  the team inside names another buyer than the label    -> refused
#   and every refusal creates nothing and names the reason.
#
# COVERAGE LIMIT: agents are not provisioned (needs real unix users); the
# selling side (who gets a file, when) is the API's and is not here.
#
# Run: bash tests/premium_team_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - premium_team_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
for t in openssl jq sha256sum base64 python3; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; SUMMARY_PRINTED=1; exit 0; }; done

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/marketplace.sh src/task/routing.sh src/cmd_compose.sh \
         src/cmd_project.sh src/cmd_pack.sh src/cmd_team_pack.sh src/lib/offline_update.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/premium-team.XXXXXX)"
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR" "$TMP/tmpd" "$TMP/k" "$TMP/ostate"
tasks_db_init
export TMPDIR="$TMP/tmpd" TEAM_AUTH_PROFILE=fixture
BUILD=packaging/premium-team/build.sh

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# ---- keys: a throwaway root, a team key, an office key, a rogue "root" ------
K="$TMP/k"
key(){ openssl genpkey -algorithm ed25519 -out "$K/$1.pem" 2>/dev/null; openssl pkey -in "$K/$1.pem" -pubout -out "$K/$1.pub" 2>/dev/null; }
kid(){ openssl pkey -pubin -in "$K/$1.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
sign(){ openssl pkeyutl -sign -inkey "$K/$1.pem" -rawin -in "$2" -out "$3"; }
trustdir(){ # <out-dir> <signer> <key> <kind> <not_after> [revoked-id...]
  local d="$1" s="$2" k="$3" kind="$4" na="$5"; shift 5; mkdir -p "$d"
  jq -cjn --arg k "$kind" --arg id "$(kid "$k")" --rawfile p "$K/$k.pub" --argjson n "$na" \
    '{format:1, kind:$k, key_id:$id, pubkey:$p, not_after:$n}' >"$d/team-key.json"; sign "$s" "$d/team-key.json" "$d/team-key.sig"
  jq -cjn '{format:1, kind:"5dive-revocations", serial:1, revoked:$ARGS.positional}' --args "$@" >"$d/revoked.json"; sign root "$d/revoked.json" "$d/revoked.sig"; }
for n in root team office rogue; do key "$n"; done
NOW=$(date +%s); LATER=$((NOW + 86400 * 30))
trustdir "$TMP/t-good"    root  team   5dive-team-key       "$LATER"
trustdir "$TMP/t-office"  root  office 5dive-office-app-key "$LATER"
trustdir "$TMP/t-rogue"   rogue team   5dive-team-key       "$LATER"
trustdir "$TMP/t-expired" root  team   5dive-team-key       $((NOW - 60))
trustdir "$TMP/t-revoked" root  team   5dive-team-key       "$LATER" "$(kid team)"
export OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$K/root.pub" OFFLINE_UPDATE_ROOT_PUBKEY_PEM="" OFFLINE_UPDATE_STATE_DIR="$TMP/ostate"
chmod 644 "$K/root.pub"

# ---- the team bundle a `team export` writes (two seats) ---------------------
B="$TMP/bundle"; mkdir -p "$B/packs"
printf '{"kind":"5dive-team","format":1,"team":"research","memory":false,"agents":["boss","ana"]}\n' >"$B/manifest.json"
cat >"$B/team.5dive.yaml" <<'YAML'
version: 2
name: research
agents:
  boss:
    type: claude
    role: Head of research
    pack_file: packs/boss.tar.gz
  ana:
    type: claude
    role: Analyst
    reports_to: boss
    pack_file: packs/ana.tar.gz
YAML
for n in boss ana; do
  d=$(mktemp -d); printf '{"packFormat":1,"name":"%s"}\n' "$n" >"$d/manifest.json"
  tar -czf "$B/packs/$n.tar.gz" -C "$d" manifest.json; rm -rf "$d"
done
tar -czf "$TMP/research.team.tar.gz" -C "$B" manifest.json team.5dive.yaml packs

mk() { # <out> <trust-dir> <key> [extra build args]
  local o="$1" t="$2" k="$3"; shift 3
  bash "$BUILD" --bundle="$TMP/research.team.tar.gz" --key="$K/$k.pem" --trust="$t" \
    --buyer-account=acct-42 --buyer-name="Acme Research" --version=1.0.0 -o "$o" "$@" >/dev/null 2>"$o.err"
}

# ============ B1. the producer ===============================================
mk "$TMP/good.gz" "$TMP/t-good" team; rc=$?
eq_t 'B1 the producer makes a file' 0 "$rc"
eq_t 'B1b one .gz: manifest, signature, team' 'manifest.json manifest.sig payload/team.tar.gz ' \
  "$(tar -tzf "$TMP/good.gz" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
eq_t 'B1c the signed label names the team, version and buyer' 'research 1.0.0 acct-42 Acme Research' \
  "$(tar -xzOf "$TMP/good.gz" manifest.json | jq -r '"\(.team) \(.version) \(.buyer.account) \(.buyer.name)"')"
eq_t 'B1d the team inside carries the buyer too' 'acct-42 Acme Research' \
  "$(tar -xzOf "$TMP/good.gz" payload/team.tar.gz | tar -xzOf - manifest.json | jq -r '"\(.licensed_to.account) \(.licensed_to.name)"')"

# B1e: the ceremony page's PUBLIC file works as --trust (base64 fields).
jq -n --arg a "$(base64 -w0 <"$TMP/t-good/team-key.json")" --arg b "$(base64 -w0 <"$TMP/t-good/team-key.sig")" \
      --arg c "$(base64 -w0 <"$TMP/t-good/revoked.json")" --arg d "$(base64 -w0 <"$TMP/t-good/revoked.sig")" \
  '{root_pubkey_pem:"x", root_fingerprint:"y", team_key_json_b64:$a, team_key_sig_b64:$b, revoked_json_b64:$c, revoked_sig_b64:$d}' >"$TMP/pub-team.json"
mk "$TMP/b1e.gz" "$TMP/pub-team.json" team; rc=$?
eq_t 'B1e the ceremony'"'"'s PUBLIC team file is taken as --trust, giving the same certificate' "0 $(tar -xzOf "$TMP/good.gz" manifest.json | jq -r .trust.team_key)" \
  "$rc $(tar -xzOf "$TMP/b1e.gz" manifest.json 2>/dev/null | jq -r .trust.team_key)"

# ============ B2. the producer's refusals ====================================
mk "$TMP/b2a.gz" "$TMP/t-good" office; rc=$?
if (( rc != 0 )) && grep -q 'not the key the certificate' "$TMP/b2a.gz.err" && [[ ! -e "$TMP/b2a.gz" ]]; then ok_t 'B2a a key the certificate does not approve is refused'
else bad_t 'B2a wrong key not refused' "rc=$rc $(cat "$TMP/b2a.gz.err")"; fi
mk "$TMP/b2b.gz" "$TMP/t-office" office; rc=$?
if (( rc != 0 )) && grep -q 'not for a premium team key' "$TMP/b2b.gz.err"; then ok_t 'B2b a certificate for another kind of key is refused'
else bad_t 'B2b office certificate not refused' "rc=$rc $(cat "$TMP/b2b.gz.err")"; fi
bash "$BUILD" --bundle="$B/packs/boss.tar.gz" --key="$K/team.pem" --trust="$TMP/t-good" --buyer-account=a --version=1.0.0 -o "$TMP/b2c.gz" >/dev/null 2>"$TMP/b2c.err"; rc=$?
if (( rc != 0 )) && grep -q 'not a team bundle' "$TMP/b2c.err"; then ok_t 'B2c one agent pack is not taken for a team'
else bad_t 'B2c non-team bundle not refused' "rc=$rc $(cat "$TMP/b2c.err")"; fi

# ============ V1. import a good file =========================================
REG='{"agents":{}}'
registry_read()   { printf '%s' "$REG"; }
require_root()    { :; }
ensure_state()    { :; }
ensure_state_ro() { :; }
resolve_agent_model()  { :; }
resolve_agent_effort() { :; }
PERSONA="$TMP/persona"; mkdir -p "$PERSONA"
persona_target() { printf '%s/%s.md' "$PERSONA" "$1"; }
persona_append_block() { printf '%s' "$3" >> "$PERSONA/new-$1.md"; }
_teams_get() { printf 'REGISTRY %s\n' "$1" >>"$TMP/registry.log"; return 1; }
cat >"$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
exit 0
SH
chmod +x "$TMP/fake5dive"
export REC="$TMP/rec.log"; : >"$REC"
_compose_self() { printf '%s' "$TMP/fake5dive"; }

( cmd_team import "$TMP/good.gz" ) >"$TMP/v1.out" 2>&1; rc=$?
eq_t 'V1 a signed premium file imports' 0 "$rc"
ok_all=1; for n in boss ana; do grep -qE "^agent import /[^ ]*/packs/${n}\.tar\.gz --as=${n}( |$)" "$REC" || ok_all=0; done
if (( ok_all )); then ok_t 'V1b every seat comes up from its own pack inside the file'
else bad_t 'V1b seats did not import from the file' "$(cat "$REC")"; fi
if grep -q 'signed by 5dive: premium team research 1.0.0, licensed to Acme Research (account acct-42)' "$TMP/v1.out"; then ok_t 'V1c the import says who signed it and whose copy it is'
else bad_t 'V1c no signed/licensed line' "$(tail -5 "$TMP/v1.out")"; fi
REC_F="$STATE_DIR/premium-teams/research.json"
if [[ -f "$REC_F" ]] && [[ "$(jq -r '"\(.version) \(.buyer.account) \(has("trust"))"' "$REC_F")" == '1.0.0 acct-42 false' ]]; then
  ok_t 'V1d the box keeps the signed label (version, buyer), not the trust blob'
else bad_t 'V1d no label kept' "$(cat "$REC_F" 2>&1)"; fi
eq_t 'V1e no unpacked file is left behind' '' "$(find "$TMP/tmpd" -mindepth 1 2>/dev/null | head -3)"

# ============ R. refusals ====================================================
refused() { # <label> <file> <fragment> [env...]
  local label="$1" f="$2" frag="$3"; shift 3
  : >"$REC"; db "DELETE FROM team_members; DELETE FROM projects;" >/dev/null 2>&1; rm -rf "$STATE_DIR/teams" "$STATE_DIR/premium-teams"
  ( for e in "$@"; do export "${e?}"; done; cmd_team import "$f" ) >"$TMP/r.out" 2>&1; local rc=$?
  if (( rc != 0 )) && grep -qF -- "$frag" "$TMP/r.out" && grep -q 'Nothing was imported' "$TMP/r.out" \
     && [[ -z "$(grep '^agent ' "$REC")" && ! -e "$STATE_DIR/premium-teams/research.json" ]]; then ok_t "$label"
  else bad_t "$label" "rc=$rc rec=$(head -2 "$REC") $(tail -3 "$TMP/r.out")"; fi
}
repack() { # <src.gz> <out.gz> <python-edit-of-dir> — unpack, edit in place, pack again
  local d; d=$(mktemp -d); tar -xzf "$1" -C "$d"
  python3 -I - "$d" <<<"$3"
  tar -czf "$2" -C "$d" $(cd "$d" && find . -type f -printf '%P\n' | LC_ALL=C sort); rm -rf "$d"
}

# R1: swap the team for another (unsigned) one.
repack "$TMP/good.gz" "$TMP/r1.gz" 'import sys, shutil; shutil.copy("'"$TMP"'/research.team.tar.gz", sys.argv[1] + "/payload/team.tar.gz")'
refused 'R1 the team changed after signing is refused' "$TMP/r1.gz" 'changed after the file was signed'
# R2: rename the buyer on the label.
repack "$TMP/good.gz" "$TMP/r2.gz" 'import sys, json; p = sys.argv[1] + "/manifest.json"; m = json.load(open(p)); m["buyer"]["name"] = "Someone Else"; open(p, "w").write(json.dumps(m, separators=(",", ":")))'
refused 'R2 a label changed after signing is refused' "$TMP/r2.gz" 'signature does not match'
# R3: an office app key's certificate in a premium file (the producer refuses it, so the file is built by hand).
repack "$TMP/good.gz" "$TMP/r3.gz" 'import sys, json, base64, subprocess
d = sys.argv[1]; t = "'"$TMP"'/t-office"; p = d + "/manifest.json"; m = json.load(open(p))
b = lambda f: base64.b64encode(open(t + "/" + f, "rb").read()).decode()
m["trust"] = {"team_key": b("team-key.json"), "team_key_sig": b("team-key.sig"), "revoked": b("revoked.json"), "revoked_sig": b("revoked.sig")}
open(p, "w").write(json.dumps(m, separators=(",", ":")))
subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", "'"$K"'/office.pem", "-rawin", "-in", p, "-out", d + "/manifest.sig"], check=True)'
refused 'R3 a file signed by the office app key is refused' "$TMP/r3.gz" 'not certified for premium teams'
mk "$TMP/r4.gz" "$TMP/t-rogue" team;   refused 'R4 a team key certified by another key than the root is refused' "$TMP/r4.gz" "not certified by 5dive's root key"
mk "$TMP/r5.gz" "$TMP/t-expired" team; refused 'R5 an expired team key is refused' "$TMP/r5.gz" 'expired on'
mk "$TMP/r6.gz" "$TMP/t-revoked" team; refused 'R6 a revoked team key is refused' "$TMP/r6.gz" 'has been revoked'
refused 'R7 a box with no root key refuses every premium file' "$TMP/good.gz" 'holds no 5dive root key' \
  OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$TMP/none.pem" OFFLINE_UPDATE_ROOT_PUBKEY_PEM=
repack "$TMP/good.gz" "$TMP/r8.gz" 'import sys; open(sys.argv[1] + "/extra.txt", "w").write("x")'
refused 'R8 an extra member in the wrapper is refused' "$TMP/r8.gz" 'something other than its manifest'
# R9: the team inside is stamped for acct-42 but the (correctly signed) label names acct-7.
mkdir -p "$TMP/r9"; tar -xzf "$TMP/good.gz" -C "$TMP/r9"
sha=$(sha256sum "$TMP/r9/payload/team.tar.gz" | awk '{print $1}')
jq -cj --arg s "$sha" '.buyer.account = "acct-7" | .files["payload/team.tar.gz"] = $s' "$TMP/r9/manifest.json" >"$TMP/r9/m" && mv "$TMP/r9/m" "$TMP/r9/manifest.json"
sign team "$TMP/r9/manifest.json" "$TMP/r9/manifest.sig"
tar -czf "$TMP/r9.gz" -C "$TMP/r9" manifest.json manifest.sig payload/team.tar.gz
refused 'R9 a team stamped for another buyer than its signed label is refused' "$TMP/r9.gz" 'does not match its signed label'

# ============ C. a plain (unsigned) team bundle is unchanged =================
: >"$REC"; db "DELETE FROM team_members; DELETE FROM projects;" >/dev/null 2>&1; rm -rf "$STATE_DIR/teams" "$STATE_DIR/premium-teams"
( cmd_team import "$TMP/research.team.tar.gz" ) >"$TMP/c1.out" 2>&1; rc=$?
if (( rc == 0 )) && ! grep -q 'signed by 5dive' "$TMP/c1.out" && [[ ! -e "$STATE_DIR/premium-teams" ]]; then
  ok_t 'C1 a plain team bundle still imports, with no premium label'
else bad_t 'C1 plain bundle changed' "rc=$rc $(tail -3 "$TMP/c1.out")"; fi

SUMMARY_PRINTED=1
printf '\n%s\n' "premium_team_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
