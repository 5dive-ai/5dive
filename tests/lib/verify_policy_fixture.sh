# shellcheck shell=bash
# Give a harness an explicit BOX verification policy without copying box.json
# setup into every test. Call this only after STATE_DIR points at a disposable
# fixture tree; default-policy harnesses deliberately do not call it.
fixture_box_verify_policy() { # <always|delivered-only|never>
  local policy="${1:-}" dir="${STATE_DIR:-}"

  case "$policy" in
    always|delivered-only|never) ;;
    *)
      printf 'verify-policy fixture: invalid policy %q\n' "$policy" >&2
      return 2
      ;;
  esac

  case "$dir" in
    ""|/|/var/lib/5dive)
      printf 'verify-policy fixture: REFUSED non-disposable STATE_DIR %q\n' "$dir" >&2
      return 2
      ;;
  esac

  mkdir -p "$dir" || return
  BOX_CONFIG="$dir/box.json"
  printf '{"verify":"%s"}\n' "$policy" > "$BOX_CONFIG" || return
  export BOX_CONFIG
}

# DIVE-4559: the SIZE knob, set beside the policy rather than instead of it.
# Merges into whatever box.json the policy fixture already wrote (or starts one)
# so a harness can ask for `always` + a threshold without the second call
# silently dropping the first.
fixture_box_verify_small() { # <lines|off>
  local small="${1:-}" dir="${STATE_DIR:-}" cur='{}'

  if [[ "$small" != "off" && ! "$small" =~ ^[1-9][0-9]*$ ]]; then
    printf 'verify-small fixture: invalid threshold %q\n' "$small" >&2; return 2
  fi
  case "$dir" in
    ""|/|/var/lib/5dive)
      printf 'verify-small fixture: REFUSED non-disposable STATE_DIR %q\n' "$dir" >&2
      return 2 ;;
  esac

  mkdir -p "$dir" || return
  BOX_CONFIG="${BOX_CONFIG:-$dir/box.json}"
  [[ -r "$BOX_CONFIG" ]] && cur=$(cat "$BOX_CONFIG")
  printf '%s\n' "$(jq --arg s "$small" '.verify_small = $s' <<<"$cur")" > "$BOX_CONFIG" || return
  export BOX_CONFIG
}
