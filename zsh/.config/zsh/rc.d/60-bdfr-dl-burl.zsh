# Download Reddit posts into the current folder via URL or ID.
#
# Examples:
#   burl https://www.reddit.com/r/test/comments/abc123/example/
#   burl abc123
#   burl abc123 def456 https://redd.it/ghi789
#
# Naming:
#   Default:
#     {TITLE}_{POSTID}_{REDDITOR}
#
#   Match BDFR's default/bulk naming scheme:
#     burl -bn abc123
#
# Optional override:
#   BURL_MAX_WAIT_TIME=0 burl abc123
#
burl() {
  emulate -L zsh

  local usage
  usage="usage: burl [-bn|--bdfr-scheme] <url-or-id> [more-urls-or-ids ...]"

  (( $# )) || {
    print -u2 "$usage"
    return 2
  }

  local file_scheme="{TITLE}_{POSTID}_{REDDITOR}"
  local max_wait="${BURL_MAX_WAIT_TIME:-600}"

  local -a args
  local item

  while (( $# )); do
    item="$1"
    shift

    case "$item" in
      --help|-h)
        print -u2 "$usage"
        print -u2 ""
        print -u2 "Default file scheme:"
        print -u2 "  {TITLE}_{POSTID}_{REDDITOR}"
        print -u2 ""
        print -u2 "BDFR/bulk-compatible file scheme:"
        print -u2 "  --bdfr-scheme, -bn, --bulk-scheme, --old-scheme, --legacy-scheme"
        print -u2 "  {REDDITOR}_{TITLE}_{POSTID}"
        return 0
        ;;

      --bdfr-scheme|-bn|--bulk-scheme|--old-scheme|--legacy-scheme)
        file_scheme="{REDDITOR}_{TITLE}_{POSTID}"
        ;;

      # Kept as a harmless compatibility no-op for old muscle memory/scripts.
      --no-convert|-nc)
        ;;

      --)
        # Everything after "--" is treated as a link/ID, even if it starts with "-".
        while (( $# )); do
          args+=(-l "$1")
          shift
        done
        break
        ;;

      -*)
        print -u2 "burl: unknown option: $item"
        print -u2 "$usage"
        return 2
        ;;

      *)
        args+=(-l "$item")
        ;;
    esac
  done

  (( ${#args[@]} )) || {
    print -u2 "$usage"
    return 2
  }

  if ! (( $+commands[bdfr] )); then
    print -u2 "burl: bdfr not found"
    return 127
  fi

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

  local log
  local rc=0
  local partial_rc=0
  local keep_log=0

  log="$(mktemp "${log_dir%/}/bdfr.XXXXXX.log")" || return 1

  # Match actual log/error signals, not arbitrary lowercase words like "error"
  # inside post titles or filenames.
  local error_re
  error_re='(^|[[:space:]\[])(ERROR|CRITICAL)([[:space:]\]:-]|$)|Traceback \(most recent call last\)|HTTP Error 429|429 Too Many Requests|Too Many Requests|[Tt]imed out|[Tt]imeout|[Cc]onnection aborted|[Cc]onnection reset|Max retries exceeded'

  {
    local -a bdfr_opts
    bdfr_opts=(
      download .
      --folder-scheme ''
      --file-scheme "$file_scheme"
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
        grep -E "$error_re" "$log" 2>/dev/null | tail -n 40 >&2
      fi

      return "$rc"
    fi

    # BDFR can exit 0 while individual submissions/media failed.
    # Only treat clear log-level/errors as partial failures.
    if [[ -s "$log" ]] && grep -Eq "$error_re" "$log"; then
      partial_rc=1
      keep_log=1

      print -u2 ""
      print -u2 "========================================"
      print -u2 "burl: BDFR completed, but the log contains errors"
      print -u2 "burl: temporary log kept at: $log"
      print -u2 "========================================"
      print -u2 ""
      print -u2 "burl: relevant log lines:"

      grep -E "$error_re" "$log" 2>/dev/null | tail -n 80 >&2
    fi

    return "$partial_rc"

  } always {
    if (( keep_log )) || [[ -n ${BURL_KEEP_LOG:-} ]]; then
      print -u2 "burl: kept temporary log: $log"
    else
      rm -f -- "$log"
    fi
  }
}
