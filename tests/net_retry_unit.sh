#!/usr/bin/env bash
# DIVE-8088 — CI steps survive a mirror or download hiccup without a human re-run.
#
#   R1  apt-shaped 404 on attempt 1, clean on attempt 2: the step passes, ran twice
#   R2  NEGATIVE CONTROL: a download that fails every time still fails the step,
#       with its own exit code, and the last lines name the mirror error
#   R3  a failure that is NOT a download (a bad package name, a failing check) is
#       never retried: one run, same exit code, no net-retry line
#   R4  green on attempt 1: one run, nothing added
#   W1  every image build and apt step on the 2026-11-10 red list goes through
#       scripts/net-retry.sh (a step dropped from the wrapper turns this red)
#   H1  the Hermes recipe's own curl flags survive one 429 from a local server
#   H2  MUTATION: the same flags without --retry fail on that same single 429, so
#       H1 is green because of the flag, not because the server healed
#
# No root, no docker, no outside network: stub commands and a loopback server.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d /tmp/net-retry.XXXXXX)
SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

RETRY="$PWD/scripts/net-retry.sh"
export NET_RETRY_SLEEPS="0 0"   # three attempts, no waiting

# A stub step: fails with <msg> and exit <rc> for its first <n> runs, then passes.
# Counts its runs in $TMP/<name>.n.
mkstub() {
  local name="$1" n="$2" rc="$3" msg="$4"
  cat > "$TMP/$name" <<EOF
#!/usr/bin/env bash
c=\$(( \$(cat "$TMP/$name.n" 2>/dev/null || echo 0) + 1 )); echo "\$c" > "$TMP/$name.n"
if (( c <= $n )); then printf '%s\n' "$msg" >&2; exit $rc; fi
echo "step done"
EOF
  chmod +x "$TMP/$name"
}
runs() { cat "$TMP/$1.n" 2>/dev/null || echo 0; }

MIRROR='E: Failed to fetch http://security.ubuntu.com/ubuntu/pool/main/p/perl/perl-base_5.34.0-3ubuntu1.10_amd64.deb  404  Not Found [IP: 192.0.2.10 80]'

# R1
mkstub r1 1 100 "$MIRROR"
out="$("$RETRY" "$TMP/r1" 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$(runs r1)" == 2 ]] && grep -q 'attempt 1/3 failed on a download error' <<<"$out"; then
  ok_t "R1 mirror 404 once, then clean: passes on attempt 2"
else bad_t "R1 mirror 404 once" "rc=$rc runs=$(runs r1) out=$out"; fi

# R2 — negative control
mkstub r2 99 100 "$MIRROR"
out="$("$RETRY" "$TMP/r2" 2>&1)"; rc=$?
if (( rc == 100 )) && [[ "$(runs r2)" == 3 ]] && tail -3 <<<"$out" | grep -qF '404  Not Found'; then
  ok_t "R2 mirror 404 every time: still fails (rc 100) after 3 attempts, mirror error in the last lines"
else bad_t "R2 negative control" "rc=$rc runs=$(runs r2) tail=$(tail -3 <<<"$out")"; fi

# R3 — not a download error
mkstub r3 99 100 'E: Unable to locate package shellchek'
out="$("$RETRY" "$TMP/r3" 2>&1)"; rc=$?
if (( rc == 100 )) && [[ "$(runs r3)" == 1 ]] && ! grep -q 'net-retry' <<<"$out"; then
  ok_t "R3 a non-download failure fails at once, unretried"
else bad_t "R3 non-download failure" "rc=$rc runs=$(runs r3) out=$out"; fi
mkstub r3b 99 1 'FAIL: package 0.1 installed but the box runs 0.2'
out="$("$RETRY" "$TMP/r3b" 2>&1)"; rc=$?
if (( rc == 1 )) && [[ "$(runs r3b)" == 1 ]]; then ok_t "R3 a failing check fails at once, unretried"
else bad_t "R3 failing check" "rc=$rc runs=$(runs r3b)"; fi

# R4
mkstub r4 0 0 ""
out="$("$RETRY" "$TMP/r4" 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$(runs r4)" == 1 ]] && [[ "$out" == "step done" ]]; then ok_t "R4 green first time: one run, output unchanged"
else bad_t "R4 green first time" "rc=$rc runs=$(runs r4) out=$out"; fi

# W1 — the wiring. Every docker build/run that pulls from an Ubuntu mirror, and every
# runner apt step, in the workflows that went red on 2026-11-10.
w1_bad=""
for f in install-smoke docker-image init-smoke harness-smoke apt-repo offline-update; do
  y=".github/workflows/$f.yml"
  while IFS= read -r line; do
    w1_bad+="$f: $line"$'\n'
  done < <(grep -E '^\s*(run: )?(sudo apt-get update|docker build |docker run --rm (--network host )?-v .*ubuntu:24\.04)' "$y" \
             | grep -v 'net-retry' || true)
  grep -q 'net-retry.sh' "$y" || w1_bad+="$f: no net-retry at all"$'\n'
done
if [[ -z "$w1_bad" ]]; then ok_t "W1 every image build and apt step on the red list goes through net-retry"
else bad_t "W1 unwrapped fetch steps" "$w1_bad"; fi

# H1/H2 — the Hermes download, with the recipe's own curl flags.
flags="$(grep -oE 'curl( -[-a-zA-Z0-9]+( [0-9]+)?)+ https://raw\.githubusercontent\.com/NousResearch' src/header.sh \
         | head -1 | sed -E 's#^curl ##; s# https://.*##')"
if [[ "$flags" != *--retry* ]]; then
  bad_t "H1 Hermes recipe curl has --retry" "flags='$flags'"
elif ! command -v python3 >/dev/null; then
  bad_t "H1 needs python3 for the local 429 server" ""
else
  cat > "$TMP/srv.py" <<'PY'
import http.server, sys, os
state = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        n = int(open(state).read()) if os.path.exists(state) else 0
        open(state, "w").write(str(n + 1))
        if n == 0:
            self.send_response(429); self.send_header("Retry-After", "1"); self.end_headers(); return
        body = b"echo installer\n"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("localhost", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  python3 "$TMP/srv.py" "$TMP/port" "$TMP/hits" & SRV_PID=$!
  for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  url="http://localhost:$(cat "$TMP/port")/scripts/install.sh"
  # shellcheck disable=SC2086  # the recipe's flags, word-split as the recipe does
  if body="$(curl $flags "$url" 2>"$TMP/h1.err")" && [[ "$body" == "echo installer" ]] && [[ "$(cat "$TMP/hits")" == 2 ]]; then
    ok_t "H1 recipe flags ($flags) survive one 429"
  else bad_t "H1 recipe flags vs one 429" "body=$body hits=$(cat "$TMP/hits" 2>/dev/null)"; fi
  rm -f "$TMP/hits"
  bare="$(sed -E 's/--retry [0-9]+//' <<<"$flags")"
  # shellcheck disable=SC2086
  if ! curl $bare "$url" >/dev/null 2>&1; then ok_t "H2 mutation: without --retry the same 429 fails"
  else bad_t "H2 mutation: without --retry the 429 did not fail — H1 proves nothing" ""; fi
fi

echo "---"
echo "net-retry: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
