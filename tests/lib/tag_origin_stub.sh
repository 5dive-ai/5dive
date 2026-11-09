# DIVE-7973 — the GitHub answers install.sh's tag_came_from_main() reads, as a
# curl-stub fragment. Harnesses that drive the REAL resolve_gh_tag prepend it to
# their curl stub so a fixture tag "came from main" (release-cut's shape: bundle
# commit -> version commit -> a source commit main contains). It answers ONLY
# calls carrying the Accept: application/vnd.github+json header, which no other
# install.sh fetch sends, so it never shadows a harness's own api.github.com arms.
# The check's own behaviour (each refusal shape) is graded in
# tests/install_tag_origin_unit.sh; here it is only a precondition.
tag_origin_ok_stub() {
  cat <<'STUB'
case "$*" in
  *vnd.github+json*api.github.com/repos/*/commits/v*) printf '{"sha":"b0","parents":[{"sha":"a0"}],"files":[{"filename":"5dive"},{"filename":"5dive.sha256"}]}\n'; exit 0 ;;
  *vnd.github+json*api.github.com/repos/*/commits/a0) printf '{"sha":"a0","parents":[{"sha":"c0"}],"files":[{"filename":"CHANGELOG.md"}]}\n'; exit 0 ;;
  *vnd.github+json*api.github.com/repos/*/compare/c0...main) printf '{"status":"ahead"}\n'; exit 0 ;;
esac
STUB
}
