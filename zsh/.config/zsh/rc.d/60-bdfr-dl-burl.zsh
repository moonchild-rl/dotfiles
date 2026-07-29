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

## Create .txt sidecars from BDFR archive JSON in a private temporary folder.
_burl_add_post_text() {
  emulate -L zsh

  local file_scheme="$1"
  local log_dir="$2"
  shift 2

  (( $# )) || return 0

  local archive_dir
  local archive_log
  local rc=0
  local keep_log=0
  local json_file
  local text_file

  archive_dir="$(mktemp -d "${log_dir%/}/text-sidecars.XXXXXX")" || return 1

  archive_log="$(mktemp "${log_dir%/}/bdfr-text.XXXXXX.log")" || {
    rm -rf -- "$archive_dir"
    return 1
  }

  # Match actual log/error signals, not arbitrary words appearing in titles.
  local error_re
  error_re='(^|[[:space:]\[])(ERROR|CRITICAL)([[:space:]\]:-]|$)|Traceback \(most recent call last\)|HTTP Error 429|429 Too Many Requests|Too Many Requests|[Tt]imed out|[Tt]imeout|[Cc]onnection aborted|[Cc]onnection reset|Max retries exceeded'

  {
    local -a archive_args
    local source

    archive_args=(
      archive "$archive_dir"
      --folder-scheme ''
      --file-scheme "$file_scheme"
      --filename-restriction-scheme windows
      --format json
      --log "$archive_log"
    )

    for source in "$@"; do
      archive_args+=(-l "$source")
    done

    bdfr "${archive_args[@]}"

    if (( $? != 0 )); then
      rc=1
      keep_log=1
    fi

    for json_file in "$archive_dir"/*.json(N); do
      text_file="./${json_file:t:r}.txt"

      # Only accept the expected BDFR submission structure.
      if ! jq -e '
        type == "object" and
        (.id | type == "string") and
        (.selftext | type == "string")
      ' "$json_file" >/dev/null 2>&1; then
        rc=1
        keep_log=1

        print -u2 \
          "burl: malformed or unexpected BDFR JSON: ${json_file:t}"

        continue
      fi

      # Determine whether the body contains useful text.
      if jq -e '
        (.selftext | gsub("^\\s+|\\s+$"; "")) as $text
        | (
            $text != ""
            and ($text | ascii_downcase) != "[removed]"
            and ($text | ascii_downcase) != "[deleted]"
          )
      ' "$json_file" >/dev/null 2>&1; then

        # A text-only Reddit post already has this .txt file because the
        # normal BDFR downloader created it. Never replace an existing file.
        if [[ ! -e "$text_file" ]]; then
          if jq -r '.selftext' "$json_file" >| "$text_file"; then
            print -u2 \
              "burl: wrote post text: ${text_file#./}"
          else
            rm -f -- "$text_file"

            rc=1
            keep_log=1

            print -u2 \
              "burl: could not write post text: ${text_file#./}"
          fi
        fi
      else
        # A text-only post may have caused BDFR itself to create a .txt
        # containing [removed], [deleted], or nothing. Remove such files.
        if [[ -f "$text_file" ]] && {
          ! grep -q '[^[:space:]]' "$text_file" 2>/dev/null ||
          grep -Eqi \
            '^[[:space:]]*\[(removed|deleted)\][[:space:]]*$' \
            "$text_file" \
            2>/dev/null
        }; then
          rm -f -- "$text_file" || {
            rc=1
            keep_log=1

            print -u2 \
              "burl: could not remove unusable text file: ${text_file#./}"
          }
        fi
      fi
    done

    # BDFR can sometimes return 0 even though individual operations failed.
    if [[ -s "$archive_log" ]] &&
       grep -Eq "$error_re" "$archive_log"; then
      rc=1
      keep_log=1
    fi

    if (( rc != 0 )); then
      print -u2 ""
      print -u2 "========================================"
      print -u2 "burl: POST TEXT PROCESSING FAILED"
      print -u2 "burl: downloaded media was kept"
      print -u2 "burl: temporary JSON files were deleted"
      print -u2 "burl: temporary log kept at: $archive_log"
      print -u2 "========================================"

      if [[ -s "$archive_log" ]]; then
        print -u2 ""
        print -u2 "burl: last relevant post-text log lines:"

        grep -E "$error_re" "$archive_log" 2>/dev/null |
          tail -n 40 >&2
      fi
    fi

    return "$rc"

  } always {
    # No JSON archive or malformed JSON is retained.
    rm -rf -- "$archive_dir"

    if (( keep_log )) || [[ -n ${BURL_KEEP_LOG:-} ]]; then
      print -u2 "burl: kept temporary log: $archive_log"
    else
      rm -f -- "$archive_log"
    fi
  }
}

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
  local -a sources
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
        print -u2 "BDFR-compatible file scheme:"
        print -u2 "  --bdfr-scheme, -bn"
        print -u2 "  {REDDITOR}_{TITLE}_{POSTID}"
        return 0
        ;;

      --bdfr-scheme|-bn)
        file_scheme="{REDDITOR}_{TITLE}_{POSTID}"
        ;;

      -*)
        print -u2 "burl: unknown option: $item"
        print -u2 "$usage"
        return 2
        ;;

      *)
        sources+=("$item")
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

  if ! (( $+commands[jq] )); then
    print -u2 "burl: jq not found (required for Reddit post text)"
    return 127
  fi

  case "$max_wait" in
    ''|*[!0-9]*)
      print -u2 \
        "burl: BURL_MAX_WAIT_TIME must be a non-negative integer"
      return 2
      ;;
  esac

  local tmp_root

  if [[ -n ${BURL_LOG_DIR:-} ]]; then
    tmp_root="$BURL_LOG_DIR"
  elif [[
    -n ${XDG_RUNTIME_DIR:-} &&
    -d "$XDG_RUNTIME_DIR" &&
    -w "$XDG_RUNTIME_DIR"
  ]]; then
    tmp_root="$XDG_RUNTIME_DIR"
  else
    tmp_root="${TMPDIR:-/tmp}"
  fi

  if [[ ! -d "$tmp_root" || ! -w "$tmp_root" ]]; then
    print -u2 \
      "burl: temporary directory is not writable: $tmp_root"
    return 1
  fi

  local log_dir="${tmp_root%/}/burl-logs"

  mkdir -p -- "$log_dir" || {
    print -u2 \
      "burl: could not create log directory: $log_dir"
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
      --filename-restriction-scheme windows
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

        grep -E "$error_re" "$log" 2>/dev/null |
          tail -n 40 >&2
      fi

      return "$rc"
    fi

    # Download only the post data needed to derive optional .txt sidecars.
    # Archive JSON is confined to a temporary directory and then deleted.
    _burl_add_post_text \
      "$file_scheme" \
      "$log_dir" \
      "${sources[@]}" ||
        partial_rc=1

    # BDFR can exit 0 while individual submissions/media failed.
    # Only treat clear log-level/errors as partial failures.
    if [[ -s "$log" ]] &&
       grep -Eq "$error_re" "$log"; then
      partial_rc=1
      keep_log=1

      print -u2 ""
      print -u2 "========================================"
      print -u2 "burl: BDFR completed, but the log contains errors"
      print -u2 "burl: temporary log kept at: $log"
      print -u2 "========================================"
      print -u2 ""
      print -u2 "burl: relevant log lines:"

      grep -E "$error_re" "$log" 2>/dev/null |
        tail -n 80 >&2
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
