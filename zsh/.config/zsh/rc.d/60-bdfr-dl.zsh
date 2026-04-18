# Download reddit posts into the current folder via URL or ID
# Examples
# burl https://www.reddit.com/r/test/comments/abc123/example/
# burl abc123
# burl abc123 def456 https://redd.it/ghi789
burl() {
  (( $# )) || {
    print -u2 "usage: burl <url-or-id> [more-urls-or-ids ...]"
    return 2
  }

  local args=()
  local item
  for item in "$@"; do
    args+=(-l "$item")
  done

  bdfr download . \
    --folder-scheme '' \
    "${args[@]}"
}
