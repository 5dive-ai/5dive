# -------- the box's identity to the 5dive API (DIVE-5168, DIVE-9324) --------
#
# Every box->API caller that authenticates as the BOX (bug reports, the a2a
# vouch, the first-job intro, the helper handover, premium-team updates) reads
# the same CONNECTORD_TOKEN the same way. These three lived in cmd_partner.sh
# until `5dive partner hire` moved to the hosted plugin (DIVE-9324); the
# callers stayed in core, so the reads did too.

# Where the box identity lives. FIVE_CONNECTORD_ENV is the harness seam; nothing
# on a box sets it.
_box_connectord_env() { printf '%s' "${FIVE_CONNECTORD_ENV:-/etc/5dive/connectord.env}"; }

# The API this box talks to: /etc/5dive/api-base wins (DIVE-7558, header.sh),
# then FIVE_API_BASE, then production.
_box_api_base() { five_api_base; }

# _box_token — the box's CONNECTORD_TOKEN on stdout. An inherited
# CONNECTORD_TOKEN wins, else the `CONNECTORD_TOKEN=` line of the env file.
#   rc 0  token printed
#   rc 1  the file exists and this seat cannot read it (sandboxed seat)
#   rc 2  no file / no token line (not a managed 5dive box)
_box_token() {
  local f t=""
  if [[ -n "${CONNECTORD_TOKEN:-}" ]]; then printf '%s' "$CONNECTORD_TOKEN"; return 0; fi
  f=$(_box_connectord_env)
  if [[ -e "$f" && ! -r "$f" ]]; then return 1; fi
  [[ -r "$f" ]] || return 2
  t=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$f" 2>/dev/null | head -n 1) || t=""
  t="${t%$'\r'}"; t="${t#\"}"; t="${t%\"}"; t="${t#\'}"; t="${t%\'}"
  [[ -n "$t" ]] || return 2
  printf '%s' "$t"
}
