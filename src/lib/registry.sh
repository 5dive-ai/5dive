with_registry_lock() {
  local fn="$1"; shift
  if [[ "${IN_REGISTRY_LOCK:-0}" == "1" ]]; then
    "$fn" "$@"
    return
  fi
  ensure_state
  (
    flock -x 200
    IN_REGISTRY_LOCK=1
    "$fn" "$@"
  ) 200>"$REGISTRY_LOCK"
}

registry_read() {
  [[ -f "$REGISTRY" ]] && cat "$REGISTRY" || echo '{"agents":{}}'
}

registry_write() {
  # stdin -> registry, atomic
  local tmp
  tmp=$(mktemp "${REGISTRY}.XXXXXX")
  cat > "$tmp"
  chown root:claude "$tmp"
  chmod 640 "$tmp"
  mv "$tmp" "$REGISTRY"
}
