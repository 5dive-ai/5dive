#!/usr/bin/env bash
# DIVE-4576 deliverable 4 — what ONE GRADE costs today, per grader clone.
# Method is 5dive-burn-log.sh's: assistant records deduped by message.id, so the
# per-content-block duplication Claude Code writes is not counted twice.
# Prices (Opus 5 list, same as the burn log): in $5/M, out $25/M, cache write 1h
# $10/M, cache read $0.50/M.
set -u
printf 'seat\tturns\tin\tout\tcache_write\tcache_read\tquota\tapi_usd\n'
for d in /home/.5dive-reaped/gr-* /home/agent-gr-*; do
  [[ -d "$d" ]] || continue
  seat=$(basename "$d")
  read -r turns tin tout tcw tcr < <(
    find "$d/.claude/projects" -name '*.jsonl' -print0 2>/dev/null \
    | xargs -0 cat 2>/dev/null \
    | jq -r 'select(.type=="assistant")
             | [(.message.id // .requestId // .uuid), (.message.usage.input_tokens//0),
                (.message.usage.output_tokens//0), (.message.usage.cache_creation_input_tokens//0),
                (.message.usage.cache_read_input_tokens//0)] | @tsv' 2>/dev/null \
    | sort -u -k1,1 \
    | awk -F'\t' '{n++; a+=$2; b+=$3; c+=$4; e+=$5} END {printf "%d %d %d %d %d\n", n+0, a+0, b+0, c+0, e+0}'
  )
  (( turns > 0 )) || continue
  quota=$(( tin + tout + tcw + tcr ))
  usd=$(awk -v i="$tin" -v o="$tout" -v w="$tcw" -v r="$tcr" 'BEGIN{printf "%.2f", i*5/1e6 + o*25/1e6 + w*10/1e6 + r*0.5/1e6}')
  printf '%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n' "$seat" "$turns" "$tin" "$tout" "$tcw" "$tcr" "$quota" "$usd"
done
