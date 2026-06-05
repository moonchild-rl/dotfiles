# Download reddit posts into the current folder via URL or ID
# Examples:
#   burl https://www.reddit.com/r/test/comments/abc123/example/
#   burl abc123
#   burl abc123 def456 https://redd.it/ghi789
#
# Disable conversion:
#   burl --no-convert abc123
#   burl -nc abc123
#
# Defaults:
#   BDFR max wait time defaults to 600 seconds.
#
# Optional overrides:
#   BURL_MAX_WAIT_TIME=1200 burl abc123
#   BURL_MAX_WAIT_TIME=0 burl abc123
#   BURL_KEEP_LOG=1 burl abc123
#
# Behavior:
#   Clean BDFR run, no suspicious errors:
#     temporary log is deleted
#
#   BDFR exits non-zero:
#     temporary log is kept
#
#   BDFR exits zero but log contains errors like 429/timeouts:
#     temporary log is kept
#     function returns 1
burl() {
  emulate -L zsh

  (( $# )) || {
    print -u2 "usage: burl [--no-convert|-nc] <url-or-id> [more-urls-or-ids ...]"
      return 2
    }

  local convert=1
  local -a args
  local item

  for item in "$@"; do
    case "$item" in
      --no-convert|-nc)
        convert=0
        ;;
      *)
        args+=(-l "$item")
        ;;
    esac
  done

  (( ${#args[@]} )) || {
    print -u2 "usage: burl [--no-convert|-nc] <url-or-id> [more-urls-or-ids ...]"
      return 2
    }

  if ! (( $+commands[bdfr] )); then
    print -u2 "burl: bdfr not found"
    return 127
  fi

  local max_wait="${BURL_MAX_WAIT_TIME:-600}"

  case "$max_wait" in
    ''|*[!0-9]*)
      print -u2 "burl: BURL_MAX_WAIT_TIME must be a non-negative integer"
      return 2
      ;;
  esac

  local tmp_root

  if [[ -n ${BURL_LOG_DIR:-} ]]; then
    tmp_root="$BURL_LOG_DIR"
  elif [[ -n ${XDG_RUNTIME_DIR:-} && -d "$XDG_RUNTIME_DIR" && -w "$XDG_RUNTIME_DIR" ]]; then
    tmp_root="$XDG_RUNTIME_DIR"
  else
    tmp_root="${TMPDIR:-/tmp}"
  fi

  if [[ ! -d "$tmp_root" || ! -w "$tmp_root" ]]; then
    print -u2 "burl: temporary directory is not writable: $tmp_root"
    return 1
  fi

  local log_dir="${tmp_root%/}/burl-logs"

  mkdir -p -- "$log_dir" || {
    print -u2 "burl: could not create log directory: $log_dir"
    return 1
  }

  chmod 700 "$log_dir" 2>/dev/null || true

  local marker log
  local rc=0
  local partial_rc=0
  local keep_log=0

  marker="$(mktemp "${tmp_root%/}/burl.marker.XXXXXX")" || return 1
  log="$(mktemp "${log_dir%/}/bdfr.XXXXXX.log")" || {
    rm -f -- "$marker"
    return 1
  }

  {
    local -a bdfr_opts
    bdfr_opts=(
      download .
      --folder-scheme ''
      --log "$log"
      --max-wait-time "$max_wait"
    )

    bdfr "${bdfr_opts[@]}" "${args[@]}"
    rc=$?

    if (( rc != 0 )); then
      keep_log=1

      print -u2 ""
      print -u2 "========================================"
      print -u2 "burl: BDFR FAILED with exit code $rc"
      print -u2 "burl: temporary log kept at: $log"
      print -u2 "========================================"

      if [[ -s "$log" ]]; then
        print -u2 ""
        print -u2 "burl: last relevant log lines:"
        grep -Ei '(ERROR|CRITICAL|Traceback|failed|429|timed out|timeout|connection aborted|connection reset)' "$log" 2>/dev/null | tail -n 40 >&2
      fi

      return "$rc"
    fi

    # BDFR can exit 0 while individual submissions/media failed.
    # Treat those as partial failures so the function visibly reports them.
    if [[ -s "$log" ]] && grep -Eiq '(ERROR|CRITICAL|Traceback|failed|429|timed out|timeout|connection aborted|connection reset)' "$log"; then
      partial_rc=1
      keep_log=1

      print -u2 ""
      print -u2 "========================================"
      print -u2 "burl: BDFR completed, but the log contains errors"
      print -u2 "burl: temporary log kept at: $log"
      print -u2 "========================================"
      print -u2 ""
      print -u2 "burl: relevant log lines:"

      grep -Ei '(ERROR|CRITICAL|Traceback|failed|429|timed out|timeout|connection aborted|connection reset)' "$log" 2>/dev/null | tail -n 80 >&2
    fi

    if (( convert )); then
      if (( $+commands[ffmpeg] )); then
        find . -type f -cnewer "$marker" -iname '*.gif' -exec sh -c '
          size_of() {
            wc -c < "$1" | tr -d "[:space:]"
          }

          for f do
            out="${f%.*}.mp4"

            if [ -e "$out" ]; then
              echo "Skipping GIF conversion, output exists: $out" >&2
              continue
            fi

            ffmpeg -hide_banner -loglevel error -y -i "$f" \
              -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
              -an -movflags +faststart -pix_fmt yuv420p "$out" || {
                rm -f -- "$out"
                echo "GIF conversion failed: $f" >&2
                continue
              }

            old_size=$(size_of "$f")
            new_size=$(size_of "$out")

            if [ "$new_size" -lt "$old_size" ]; then
              echo "Converted GIF to smaller MP4: $f -> $out ($old_size -> $new_size bytes)" >&2
              rm -- "$f"
            else
              rm -- "$out"
            fi
          done
        ' sh {} +
      else
        print -u2 "burl: ffmpeg not found; skipping GIF -> MP4 conversion"
      fi

      if (( $+commands[cwebp] )); then
        find . -type f -cnewer "$marker" \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -exec sh -c '
          size_of() {
            wc -c < "$1" | tr -d "[:space:]"
          }

          for f do
            out="${f%.*}.webp"

            if [ -e "$out" ]; then
              echo "Skipping WebP conversion, output exists: $out" >&2
              continue
            fi

            cwebp -quiet -q 85 "$f" -o "$out" || {
              rm -f -- "$out"
              echo "WebP conversion failed: $f" >&2
              continue
            }

            old_size=$(size_of "$f")
            new_size=$(size_of "$out")

            if [ "$new_size" -lt "$old_size" ]; then
              echo "Converted: $f -> $out ($old_size -> $new_size bytes)" >&2
              rm -- "$f"
            else
              rm -- "$out"
            fi
          done
        ' sh {} +
      else
        print -u2 "burl: cwebp not found; skipping image -> WebP conversion"
      fi
    fi

    return "$partial_rc"

  } always {
    rm -f -- "$marker"

    if (( keep_log )) || [[ -n ${BURL_KEEP_LOG:-} ]]; then
      print -u2 "burl: kept temporary log: $log"
    else
      rm -f -- "$log"
    fi
  }
}
