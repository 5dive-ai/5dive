#!/bin/bash
# Regenerates the README hero assets: docs/readme-hero-{dark,light}.png (icon +
# wordmark lockup) (wordmark lockup). Needs ImageMagick `convert`, python3, and Inter-ExtraBold.otf;
# run from the repo root. Colors track GitHub's dark (#0d1117) / light themes.
set -e
INTER_XB=/usr/share/fonts/opentype/inter/Inter-ExtraBold.otf
TAG="run a company of AI agents on a server you own"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mk() { # $1=suffix $2=wordcolor
  convert -background none -font "$INTER_XB" -pointsize 230 -fill "$2" label:"5dive" "$T/word.png"
  convert "$T/word.png" -bordercolor none -border 40x30 "$T/banner.png"
  # +repage: resize leaves a stale virtual canvas that breaks later -flatten consumers
  convert "$T/banner.png" -resize 900x +repage "docs/readme-hero-$1.png"
}
mk dark  '#f0f6fc'
mk light '#16161a'

echo "regenerated: docs/readme-hero-{dark,light}.png"
