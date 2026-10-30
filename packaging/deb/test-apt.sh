#!/usr/bin/env bash
# DIVE-6800: the apt repo's acceptance arms. apt-repo.yml runs them on every
# PR that touches packaging and before every publish.
#
#   test-apt.sh signature <repo-dir>
#       On any host, no root, apt state in a temp dir: the signed repo is
#       accepted with its own key, and the same repo with ONE byte of Release
#       changed is refused. The refusal is what proves the signature is read.
#
#   test-apt.sh fresh <base-url>                 (root, clean Ubuntu container)
#       The README's two lines, run as written with only the URL swapped for
#       <base-url>: the newest version installs and the box is set up.
#
#   test-apt.sh upgrade <base-url> <old> <new>   (root, clean Ubuntu container)
#       Install <old>, set up, `apt-get upgrade`, set up again: the box moves
#       from <old> to <new>, and postinst said so in one line.
set -euo pipefail

PUBLIC_BASE="https://5dive-ai.github.io/5dive/apt"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# A clean Ubuntu server has these; the ubuntu:24.04 image does not. systemctl
# is stubbed for the same reason docker/Dockerfile stubs it: no systemd as PID 1
# in a container, and install.sh's only call is a daemon-reload.
prep_container() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq sudo curl ca-certificates >/dev/null
  ln -sf /bin/true /usr/local/bin/systemctl
  # The README's `apt install` asks [Y/n]; a person answers it, a container
  # has no one to. Nothing else about the lines changes.
  echo 'APT::Get::Assume-Yes "true";' > /etc/apt/apt.conf.d/90assume-yes
}

# The README's lines, between the apt-lines markers, with the public URL
# replaced. Read from the README so the doc and the test cannot drift apart.
readme_lines() {
  local base="$1" readme="${README:-$here/../../README.md}"
  awk '/<!-- apt-lines:start -->/{s=1;next} /<!-- apt-lines:end -->/{s=0} s && !/^```/' "$readme" \
    | sed "s#${PUBLIC_BASE}#${base}#g"
}

cli_version() { grep -m1 'readonly FIVE_VERSION=' /usr/local/bin/5dive | sed -E 's/.*="([^"]+)".*/\1/'; }
pkg_version() { dpkg-query -W -f='${Version}' 5dive; }
# apt runs dpkg (and so postinst) on a pseudo-terminal (Dpkg::Use-Pty), whose
# ONLCR turns every line postinst prints into "...\r\n". The CI log hides the
# \r, so an exact-line match on raw apt output never hits. Strip it, then match
# the WHOLE line: a prefix or a different message is still a miss. No pipe:
# under pipefail an early-exiting grep -q would SIGPIPE its writer and miss.
said() { grep -qxF -- "$1" <<<"${2//$'\r'/}"; } # <exact line> <apt output>

# Sourced (tests/apt_package_unit.sh), only the helpers above are defined.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

case "${1:-}" in
  signature)
    repo="$(cd "$2" && pwd)"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    run_update() { # <repo-dir> <tag>
      local d="$work/$2"
      mkdir -p "$d/parts" "$d/prefs" "$d/lists/partial" "$d/cache/archives/partial"
      echo "deb [signed-by=$repo/5dive.gpg] file://$1 stable main" > "$d/parts/5dive.list"
      apt-get -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts="$d/parts" \
        -o Dir::Etc::preferencesparts="$d/prefs" -o Dir::State::Lists="$d/lists" \
        -o Dir::Cache="$d/cache" -o Debug::NoLocking=1 --error-on=any update 2>&1
    }
    out="$(run_update "$repo" good)" || fail "the signed repo was refused: $out"
    pass "signed repo accepted with its own key"
    cp -a "$repo" "$work/bad"
    sed -i 's/^Label: 5dive$/Label: 5divf/' "$work/bad/dists/stable/InRelease"
    if out="$(run_update "$work/bad" bad)"; then fail "a changed InRelease was ACCEPTED — the signature is not being checked"; fi
    grep -qiE 'BADSIG|not signed|signature' <<<"$out" || fail "a changed InRelease was refused, but not for its signature: $out"
    pass "changed InRelease refused for its signature"
    ;;

  fresh)
    base="$2"; prep_container
    lines="$(readme_lines "$base")"
    [[ "$(grep -c . <<<"$lines")" -eq 2 ]] || fail "expected the README's two apt lines, got: $lines"
    echo "$lines" | sed 's/^/  $ /'
    bash -euo pipefail -c "$lines" 2>&1 | tee /tmp/fresh.log
    v="$(pkg_version)"
    [[ "$(cli_version)" == "$v" ]] || fail "package $v installed but the box runs $(cli_version)"
    pass "README lines installed 5dive $v and the box runs it"
    ;;

  upgrade)
    base="$2" old="$3" new="$4"; prep_container
    bash -euo pipefail -c "$(readme_lines "$base" | head -1)"
    apt-get update -qq
    out="$(apt-get install -y "5dive=$old" 2>&1)" || fail "install of $old failed: $out"
    said 'Next: sudo 5dive-setup' "$out" || fail "postinst on a new box did not print 'Next: sudo 5dive-setup': $out"
    pass "postinst on a new box: 'Next: sudo 5dive-setup'"
    5dive-setup > /tmp/setup-old.log 2>&1 || { tail -40 /tmp/setup-old.log; fail "5dive-setup at $old failed"; }
    [[ "$(cli_version)" == "$old" ]] || fail "after setup at $old the box runs $(cli_version)"
    pass "box set up at $old"
    out="$(apt-get upgrade -y 2>&1)" || fail "apt-get upgrade failed: $out"
    [[ "$(pkg_version)" == "$new" ]] || fail "apt-get upgrade left the package at $(pkg_version), not $new"
    said "Next: sudo 5dive-setup (moves this box from $old to $new)" "$out" \
      || fail "postinst on upgrade did not name the move: $out"
    pass "apt-get upgrade moved the package $old -> $new and said what to run"
    5dive-setup > /tmp/setup-new.log 2>&1 || { tail -40 /tmp/setup-new.log; fail "5dive-setup at $new failed"; }
    grep -q "upgraded: $old" /tmp/setup-new.log || { tail -20 /tmp/setup-new.log; fail "the second setup did not take the --upgrade path"; }
    [[ "$(cli_version)" == "$new" ]] || fail "after the second setup the box runs $(cli_version), not $new"
    pass "5dive-setup moved the box $old -> $new"
    ;;

  *) echo "usage: test-apt.sh signature <repo-dir> | fresh <base-url> | upgrade <base-url> <old> <new>" >&2; exit 2 ;;
esac
