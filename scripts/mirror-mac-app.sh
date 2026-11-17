#!/usr/bin/env bash
# DIVE-8626: the Mac app downloads from THIS repo, not from 5dive-desktop.
#
# 5dive-ai/5dive-desktop stays the source repo and builds the .dmg on its own
# v* tags. This copies its latest release's Mac files onto a release here
# (default: this repo's Latest), so
#   https://github.com/5dive-ai/5dive/releases/latest/download/5dive.dmg
# always serves the newest Mac app. A visitor who comes for the app lands on
# 5dive-ai/5dive, the repo with the stars.
#
# Why a copy and not a cross-repo push from 5dive-desktop: the copy needs no
# token beyond this repo's own github.token (5dive-desktop's releases are
# public), and it must run after EVERY CLI release-cut anyway, because each
# nightly tag here becomes the new Latest with no Mac files on it.
#
# Idempotent: a file already present with the same sha256 digest (size when
# GitHub reports no digest) is left alone, so the hourly run is a no-op.
#
# Usage: mirror-mac-app.sh [<tag in this repo>]
# Env:   GH_TOKEN, GITHUB_REPOSITORY (default 5dive-ai/5dive),
#        MAC_APP_SRC_REPO (default 5dive-ai/5dive-desktop),
#        MAC_APP_FILES (default "5dive.dmg"; the .zip was dropped in DIVE-8659:
#        nothing used it, there is no auto-updater),
#        APP_OPTIONAL_FILES (default "5dive-setup.exe", the Windows app,
#        DIVE-8666): copied the same way when the desktop release has it, and
#        skipped with a notice when it does not, so a desktop release from
#        before Windows (or a Windows build that failed) never blocks the .dmg.
set -euo pipefail

dst_repo="${GITHUB_REPOSITORY:-5dive-ai/5dive}"
src_repo="${MAC_APP_SRC_REPO:-5dive-ai/5dive-desktop}"
read -r -a files <<< "${MAC_APP_FILES:-5dive.dmg}"
read -r -a optional <<< "${APP_OPTIONAL_FILES-5dive-setup.exe}"

if [[ -n "${1:-}" ]]; then
  dst_path="repos/${dst_repo}/releases/tags/${1}"
else
  dst_path="repos/${dst_repo}/releases/latest"
fi

src_json="$(gh api "repos/${src_repo}/releases/latest")"
dst_json="$(gh api "$dst_path")"
src_tag="$(jq -r '.tag_name' <<< "$src_json")"
dst_tag="$(jq -r '.tag_name' <<< "$dst_json")"
echo "Mac app: ${src_repo}@${src_tag} -> ${dst_repo}@${dst_tag}"

# "<sha256 digest>|<size>" for one asset name, empty when the release lacks it.
fingerprint() {
  jq -r --arg n "$2" '.assets[] | select(.name == $n) | "\(.digest // "")|\(.size)"' <<< "$1"
}
# Same file? Compare digests when GitHub gave both, sizes otherwise.
same_file() {
  local a_d="${1%|*}" a_s="${1##*|}" b_d="${2%|*}" b_s="${2##*|}"
  [[ -n "$2" ]] || return 1
  if [[ -n "$a_d" && -n "$b_d" ]]; then [[ "$a_d" == "$b_d" ]]; else [[ "$a_s" == "$b_s" ]]; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
copied=0
# Check every source file first, so a broken desktop release copies nothing.
for f in "${files[@]}"; do
  if [[ -z "$(fingerprint "$src_json" "$f")" ]]; then
    echo "::error::${src_repo}@${src_tag} has no ${f} — refusing to copy a partial Mac app."
    exit 1
  fi
done
for f in "${optional[@]}"; do
  if [[ -n "$(fingerprint "$src_json" "$f")" ]]; then
    files+=("$f")
  else
    echo "  ${f}: not on ${src_repo}@${src_tag}, skipped"
  fi
done
for f in "${files[@]}"; do
  want="$(fingerprint "$src_json" "$f")"
  have="$(fingerprint "$dst_json" "$f")"
  if same_file "$want" "$have"; then
    echo "  ${f}: already on ${dst_tag} (${want})"
    continue
  fi
  echo "  ${f}: copying (${want}; ${dst_tag} had ${have:-nothing})"
  gh release download "$src_tag" -R "$src_repo" -p "$f" -D "$work" --clobber
  gh release upload "$dst_tag" -R "$dst_repo" "${work}/${f}" --clobber
  rm -f "${work:?}/${f}"
  copied=$((copied + 1))
done
echo "Mac app: ${copied} file(s) copied onto ${dst_repo}@${dst_tag}"
