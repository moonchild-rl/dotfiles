# Download posts/media with gallery-dl into the current directory.
# Uses the normal gallery-dl config, but overrides the target directory to ".".
#
# Examples:
#   gldl https://www.reddit.com/r/test/comments/abc123/example/
#   gldl https://twitter.com/user/status/123456789
#   gldl https://www.instagram.com/p/SHORTCODE/
gldl() {
  emulate -L zsh

  if ! (( $+commands[gallery-dl] )); then
    print -u2 "gldl: gallery-dl not found"
    return 127
  fi

  (( $# )) || {
    print -u2 "usage: gldl <url> [more-urls ...]"
    return 2
  }

  gallery-dl -D . "$@"
}
