# Lets yazi change shell directory on exit
y() {
  local tmp="$(mktemp -t yazi-cwd.XXXXXX)"
  yazi "$@" --cwd-file="$tmp"
  if cwd="$(cat "$tmp")" && [ -n "$cwd" ]; then
    cd "$cwd"
  fi
  rm -f "$tmp"
}
