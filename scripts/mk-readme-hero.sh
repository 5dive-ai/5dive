#!/bin/bash
# Regenerates the README hero assets: docs/readme-hero-{dark,light}.png (icon +
# wordmark lockup) and docs/readme-tagline-{dark,light}.svg (typed-tagline
# animation). Needs ImageMagick `convert`, python3, and Inter-ExtraBold.otf;
# run from the repo root. Colors track GitHub's dark (#0d1117) / light themes.
set -e
ICON=docs/5dive-logo.png
INTER_XB=/usr/share/fonts/opentype/inter/Inter-ExtraBold.otf
TAG="run a company of AI agents on a server you own"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mk() { # $1=suffix $2=wordcolor
  convert -background none -font "$INTER_XB" -pointsize 230 -fill "$2" label:"5dive" "$T/word.png"
  convert "$ICON" -resize 240x240 "$T/icon.png"
  convert -size 56x1 xc:none "$T/gap.png"
  # -background none matters: gravity +append pads height mismatches with white otherwise
  convert -background none -gravity center "$T/icon.png" "$T/gap.png" "$T/word.png" +append "$T/row.png"
  convert "$T/row.png" -bordercolor none -border 40x30 "$T/banner.png"
  # +repage: resize leaves a stale virtual canvas that breaks later -flatten consumers
  convert "$T/banner.png" -resize 1100x +repage "docs/readme-hero-$1.png"
}
mk dark  '#f0f6fc'
mk light '#16161a'

svg() { # $1=suffix $2=color — SMIL per-char reveal + blinking caret (plays via GitHub camo)
  local out="docs/readme-tagline-$1.svg" spans="" i=0 t end
  while [ $i -lt ${#TAG} ]; do
    t=$(python3 -c "print(f'{0.25+$i*0.045:.3f}')")
    spans+="<tspan opacity=\"0\"><animate attributeName=\"opacity\" to=\"1\" begin=\"${t}s\" dur=\"0.01s\" fill=\"freeze\" calcMode=\"discrete\"/>${TAG:$i:1}</tspan>"
    i=$((i+1))
  done
  end=$(python3 -c "print(f'{0.25+${#TAG}*0.045:.2f}')")
  printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 820 44" width="820" height="44" role="img" aria-label="%s">\n<text x="410" y="30" text-anchor="middle" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace" font-size="24" fill="%s" xml:space="preserve">%s<tspan>▍<animate attributeName="opacity" values="1;0;1" dur="1.1s" begin="%ss" repeatCount="indefinite"/></tspan></text>\n</svg>\n' "$TAG" "$2" "$spans" "$end" > "$out"
}
svg dark  '#9aa4af'
svg light '#57606a'
echo "regenerated: docs/readme-hero-{dark,light}.png docs/readme-tagline-{dark,light}.svg"
