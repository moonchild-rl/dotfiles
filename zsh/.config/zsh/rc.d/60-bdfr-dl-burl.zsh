# Download Reddit posts into the current folder via URL or ID.
#
# Examples:
#   burl https://www.reddit.com/r/test/comments/abc123/example/
#   burl abc123
#   burl -wt abc123
#   burl -bn -wt abc123 def456 https://redd.it/ghi789
#
# Options:
#   -bn, --bdfr-scheme  Use BDFR's {REDDITOR}_{TITLE}_{POSTID} naming.
#   -wt, --with-text    Use one BDFR clone pass to download media and archive
#                       post data, create .txt sidecars, and recover Reddit-
#                       hosted images embedded inside self-post text.
#
# Environment:
#   BURL_MAX_WAIT_TIME=300  Override BDFR's maximum wait time.
#   BURL_KEEP_LOG=1         Keep the private per-run temporary directory.
#   BURL_LOG_DIR=/path      Override the runtime root. This may survive reboot.

_burl_log_has_failures() {
  emulate -L zsh

  local log="$1"
  local error_re="$2"

  [[ -s "$log" ]] && grep -Eq -- "$error_re" "$log"
}

_burl_print_log_excerpt() {
  emulate -L zsh

  local log="$1"
  local error_re="$2"
  local limit="${3:-80}"

  if [[ ! -s "$log" ]]; then
    print -u2 "burl: BDFR produced no log output"
    return 0
  fi

  if grep -Eq -- "$error_re" "$log"; then
    grep -E -- "$error_re" "$log" 2>/dev/null |
      tail -n "$limit" >&2
  else
    print -u2 \
      "burl: no known error pattern matched; showing the last $limit log lines:"
    tail -n "$limit" -- "$log" >&2
  fi
}

_burl_report_failure() {
  emulate -L zsh

  local heading="$1"
  local log="$2"
  local display_re="$3"
  shift 3

  local line

  print -u2 ""
  print -u2 "========================================"
  print -u2 "burl: $heading"

  for line in "$@"; do
    print -u2 "$line"
  done

  print -u2 ""
  print -u2 "burl: relevant log lines:"
  _burl_print_log_excerpt "$log" "$display_re"
  print -u2 "========================================"
}

# Convert a bare base36-like Reddit post ID into an unambiguous submission URL.
# This also avoids BDFR archive treating some seven-character IDs as comments.
_burl_normalize_source() {
  emulate -L zsh

  local source="$1"

  if (( ${#source} >= 5 && ${#source} <= 10 )) &&
     [[ "$source" != *[^[:alnum:]]* ]]; then
    print -r -- "https://redd.it/$source"
  else
    print -r -- "$source"
  fi
}

_burl_content_type_extension() {
  emulate -L zsh

  local content_type="${1:l}"

  case "$content_type" in
    image/jpeg|image/jpg)
      print -r -- "jpg"
      ;;
    image/png)
      print -r -- "png"
      ;;
    image/gif)
      print -r -- "gif"
      ;;
    image/webp)
      print -r -- "webp"
      ;;
    image/avif)
      print -r -- "avif"
      ;;
    image/bmp|image/x-ms-bmp)
      print -r -- "bmp"
      ;;
    image/tiff)
      print -r -- "tiff"
      ;;
    *)
      return 1
      ;;
  esac
}

# Download one URL into a temporary file and print its image MIME type.
_burl_try_image_download() {
  emulate -L zsh

  local url="$1"
  local temp_file="$2"
  local error_file="$3"
  local content_type
  local curl_rc

  : >| "$error_file" || return 1
  rm -f -- "$temp_file"

  content_type="$(
    curl \
      --fail \
      --location \
      --silent \
      --show-error \
      --retry 3 \
      --retry-delay 2 \
      --retry-connrefused \
      --connect-timeout 30 \
      --user-agent 'burl/1.0 (BDFR helper)' \
      --output "$temp_file" \
      --write-out '%{content_type}' \
      "$url" \
      2>"$error_file"
  )"
  curl_rc=$?

  if (( curl_rc != 0 )) || [[ ! -s "$temp_file" ]]; then
    rm -f -- "$temp_file"
    return 1
  fi

  content_type="${content_type%%;*}"
  content_type="${content_type:l}"

  if [[ "$content_type" != image/* ]]; then
    print -r -- \
      "curl returned non-image content type '$content_type' for $url" \
      >> "$error_file"
    rm -f -- "$temp_file"
    return 1
  fi

  print -r -- "$content_type"
}

# BDFR's SelfPost downloader can save only .txt for a rich-text/self post even
# when the body contains an inline image. Recover only direct Reddit-hosted
# images found in archived selftext; arbitrary external links are ignored.
_burl_add_inline_reddit_media() {
  emulate -L zsh

  local json_file="$1"
  local work_dir="$2"
  local archive_log="$3"

  local base_name="${json_file:t:r}"
  local url_file
  local media_url
  local download_url
  local original_url
  local temp_file
  local error_file
  local fallback_error_file
  local content_type
  local extension
  local destination
  local existing_extension
  local index=0
  local rc=0

  local -a media_urls

  url_file="$(mktemp "${work_dir%/}/inline-urls.XXXXXX")" || {
    print -r -- \
      "[burl - ERROR] - Could not create an inline-media URL list" \
      >> "$archive_log"
    return 1
  }

  # Reddit rich-text/self posts commonly expose inline uploads as Markdown
  # links to preview.redd.it or i.redd.it. Decode &amp; in query strings and
  # remove duplicate URLs while retaining only Reddit-hosted image endpoints.
  if ! jq -r '
    .selftext
    | gsub("&amp;"; "&")
    | [
        scan(
          "https?://(?:i|preview|external-preview)\\.redd\\.it/[^[:space:]<>\"\\)\\]]+"
        )
        | sub("[.,;:!?]+$"; "")
      ]
    | unique[]
  ' "$json_file" >| "$url_file"; then
    print -r -- \
      "[burl - ERROR] - Could not extract inline Reddit media URLs from ${json_file:t}" \
      >> "$archive_log"
    rm -f -- "$url_file"
    return 1
  fi

  while IFS= read -r media_url; do
    [[ -n "$media_url" ]] && media_urls+=("$media_url")
  done < "$url_file"

  rm -f -- "$url_file"

  (( ${#media_urls[@]} )) || return 0

  for media_url in "${media_urls[@]}"; do
    (( ++index ))

    temp_file="$(mktemp "${work_dir%/}/inline-image.XXXXXX")" || {
      print -r -- \
        "[burl - ERROR] - Could not create a temporary inline-image file" \
        >> "$archive_log"
      rc=1
      continue
    }

    error_file="$(mktemp "${work_dir%/}/inline-curl.XXXXXX")" || {
      rm -f -- "$temp_file"
      print -r -- \
        "[burl - ERROR] - Could not create a temporary curl error file" \
        >> "$archive_log"
      rc=1
      continue
    }

    fallback_error_file="$(mktemp "${work_dir%/}/inline-curl-fallback.XXXXXX")" || {
      rm -f -- "$temp_file" "$error_file"
      print -r -- \
        "[burl - ERROR] - Could not create a temporary curl fallback error file" \
        >> "$archive_log"
      rc=1
      continue
    }

    download_url="$media_url"
    original_url=""

    # preview.redd.it usually points at a resized/converted preview. Prefer the
    # matching original i.redd.it object, then fall back to the preview URL.
    case "$media_url" in
      https://preview.redd.it/*)
        original_url="https://i.redd.it/${${media_url#https://preview.redd.it/}%%\?*}"
        ;;
      http://preview.redd.it/*)
        original_url="https://i.redd.it/${${media_url#http://preview.redd.it/}%%\?*}"
        ;;
    esac

    if [[ -n "$original_url" ]]; then
      content_type="$(
        _burl_try_image_download \
          "$original_url" \
          "$temp_file" \
          "$error_file"
      )"

      if (( $? == 0 )); then
        download_url="$original_url"
      else
        content_type="$(
          _burl_try_image_download \
            "$media_url" \
            "$temp_file" \
            "$fallback_error_file"
        )"

        if (( $? != 0 )); then
          print -r -- \
            "[burl - ERROR] - Could not download inline Reddit image: $media_url" \
            >> "$archive_log"

          [[ -s "$error_file" ]] && cat -- "$error_file" >> "$archive_log"
          [[ -s "$fallback_error_file" ]] && \
            cat -- "$fallback_error_file" >> "$archive_log"

          rm -f -- \
            "$temp_file" \
            "$error_file" \
            "$fallback_error_file"

          rc=1
          continue
        fi
      fi
    else
      content_type="$(
        _burl_try_image_download \
          "$download_url" \
          "$temp_file" \
          "$error_file"
      )"

      if (( $? != 0 )); then
        print -r -- \
          "[burl - ERROR] - Could not download inline Reddit image: $media_url" \
          >> "$archive_log"

        [[ -s "$error_file" ]] && cat -- "$error_file" >> "$archive_log"

        rm -f -- \
          "$temp_file" \
          "$error_file" \
          "$fallback_error_file"

        rc=1
        continue
      fi
    fi

    extension="$(_burl_content_type_extension "$content_type")" || {
      print -r -- \
        "[burl - ERROR] - Unsupported image content type '$content_type' from $download_url" \
        >> "$archive_log"

      rm -f -- \
        "$temp_file" \
        "$error_file" \
        "$fallback_error_file"

      rc=1
      continue
    }

    # Avoid duplicating media that BDFR already downloaded for a one-image
    # post, even when Reddit served a different extension such as WebP.
    if (( ${#media_urls[@]} == 1 )); then
      destination="./${base_name}.${extension}"

      for existing_extension in \
        jpg jpeg png gif webp avif bmp tif tiff; do
        if [[ -e "./${base_name}.${existing_extension}" ]]; then
          destination=""
          break
        fi
      done
    else
      destination="./${base_name}_${index}.${extension}"
    fi

    if [[ -z "$destination" ]]; then
      rm -f -- \
        "$temp_file" \
        "$error_file" \
        "$fallback_error_file"
      continue
    fi

    if [[ -e "$destination" ]]; then
      print -u2 \
        "burl: inline media already exists; not replacing: ${destination#./}"

      rm -f -- \
        "$temp_file" \
        "$error_file" \
        "$fallback_error_file"
      continue
    fi

    if mv -- "$temp_file" "$destination"; then
      print -u2 "burl: wrote inline post image: ${destination#./}"
    else
      print -r -- \
        "[burl - ERROR] - Could not move inline image into place: ${destination#./}" \
        >> "$archive_log"
      rm -f -- "$temp_file"
      rc=1
    fi

    rm -f -- "$error_file" "$fallback_error_file"
  done

  return "$rc"
}

# Promote files produced by a private BDFR clone directory into the CWD.
_burl_promote_clone_files() {
  emulate -L zsh

  local clone_dir="$1"
  local clone_log="$2"
  local artifact
  local destination
  local rc=0

  # BDFR clone writes media/text and archive JSON to one directory. Move only
  # non-JSON download artifacts into the current directory, never replacing an
  # existing file. The JSON stays private for sidecar processing below.
  for artifact in "$clone_dir"/*(N); do
    [[ -f "$artifact" ]] || continue
    [[ "${artifact:e}" == json ]] && continue

    destination="./${artifact:t}"

    if [[ -e "$destination" ]]; then
      print -u2 \
        "burl: existing file kept; clone output not substituted: ${destination#./}"
      continue
    fi

    if mv -- "$artifact" "$destination"; then
      print -u2 "burl: wrote downloaded file: ${destination#./}"
    else
      print -r -- \
        "[burl - ERROR] - Could not move cloned file into place: ${destination#./}" \
        >> "$clone_log"
      rc=1
    fi
  done

  return "$rc"
}

# Process JSON produced by the same BDFR clone invocation that downloaded the
# media. This avoids launching a second PRAW/BDFR process solely for post text.
_burl_process_clone_json() {
  emulate -L zsh

  local clone_dir="$1"
  local work_dir="$2"
  local clone_log="$3"
  local failure_re="$4"

  local rc=0
  local json_count=0
  local json_file
  local text_file

  {
    for json_file in "$clone_dir"/*.json(N); do
      (( ++json_count ))
      text_file="./${json_file:t:r}.txt"

      # Only accept the expected BDFR submission structure.
      if ! jq -e '
        type == "object" and
        (.id | type == "string") and
        (.selftext | type == "string")
      ' "$json_file" >/dev/null 2>&1; then
        rc=1

        print -r -- \
          "[burl - ERROR] - Malformed or unexpected BDFR JSON: ${json_file:t}" \
          >> "$clone_log"

        continue
      fi

      # Recover Reddit-hosted images embedded inside rich-text/self posts.
      # This is deliberately limited to Reddit image hosts.
      _burl_add_inline_reddit_media \
        "$json_file" \
        "$work_dir" \
        "$clone_log" || rc=1

      # Determine whether the body contains useful text.
      if jq -e '
        (.selftext | gsub("^\\s+|\\s+$"; "")) as $text
        | (
            $text != ""
            and ($text | ascii_downcase) != "[removed]"
            and ($text | ascii_downcase) != "[deleted]"
          )
      ' "$json_file" >/dev/null 2>&1; then

        # BDFR clone may already have produced this .txt for a self-post, and
        # the promotion step may already have moved it into the CWD. Never
        # replace any existing file.
        if [[ ! -e "$text_file" ]]; then
          if jq -r '.selftext' "$json_file" >| "$text_file"; then
            print -u2 \
              "burl: wrote post text: ${text_file#./}"
          else
            rm -f -- "$text_file"
            rc=1

            print -r -- \
              "[burl - ERROR] - Could not write post text: ${text_file#./}" \
              >> "$clone_log"
          fi
        fi
      else
        # Remove unusable text that BDFR may have created for a removed,
        # deleted, or empty self-post.
        if [[ -f "$text_file" ]] && {
          ! grep -q '[^[:space:]]' "$text_file" 2>/dev/null ||
          grep -Eqi \
            '^[[:space:]]*\[(removed|deleted)\][[:space:]]*$' \
            "$text_file" \
            2>/dev/null
        }; then
          rm -f -- "$text_file" || {
            rc=1

            print -r -- \
              "[burl - ERROR] - Could not remove unusable text file: ${text_file#./}" \
              >> "$clone_log"
          }
        fi
      fi
    done

    if (( json_count == 0 )); then
      rc=1
      print -r -- \
        "[burl - ERROR] - BDFR clone produced no submission JSON" \
        >> "$clone_log"
    fi

    # BDFR can return 0 even when individual operations failed.
    if _burl_log_has_failures "$clone_log" "$failure_re"; then
      rc=1
    fi

    return "$rc"

  } always {
    # Clone media has already been promoted and archive JSON must never be
    # retained, including when the private error log is kept.
    rm -rf -- "$clone_dir"
  }
}

burl() {
  emulate -L zsh
  setopt localtraps

  local usage
  usage="usage: burl [-bn|--bdfr-scheme] [-wt|--with-text] <url-or-id> [more-urls-or-ids ...]"

  (( $# )) || {
    print -u2 "$usage"
    return 2
  }

  local file_scheme="{TITLE}_{POSTID}_{REDDITOR}"
  local max_wait="${BURL_MAX_WAIT_TIME:-300}"
  local with_text=0

  local -a args
  local -a raw_sources
  local -a sources
  local item
  local source

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
        print -u2 "Options:"
        print -u2 "  --bdfr-scheme, -bn"
        print -u2 "    Use {REDDITOR}_{TITLE}_{POSTID}."
        print -u2 ""
        print -u2 "  --with-text, -wt"
        print -u2 "    Also create .txt sidecars for posts with body text."
        print -u2 "    For self/rich-text posts, also recover direct Reddit-hosted"
        print -u2 "    inline images that BDFR's SelfPost downloader may miss."
        print -u2 "    This uses one BDFR clone pass instead of separate download/archive passes."
        return 0
        ;;

      --bdfr-scheme|-bn)
        file_scheme="{REDDITOR}_{TITLE}_{POSTID}"
        ;;

      --with-text|-wt)
        with_text=1
        ;;

      --)
        raw_sources+=("$@")
        break
        ;;

      -*)
        print -u2 "burl: unknown option: $item"
        print -u2 "$usage"
        return 2
        ;;

      *)
        raw_sources+=("$item")
        ;;
    esac
  done

  (( ${#raw_sources[@]} )) || {
    print -u2 "$usage"
    return 2
  }

  # Normalize once, then give BDFR unambiguous submission URLs in either mode.
  for source in "${raw_sources[@]}"; do
    source="$(_burl_normalize_source "$source")" || return 1
    sources+=("$source")
    args+=(-l "$source")
  done

  if ! (( $+commands[bdfr] )); then
    print -u2 "burl: bdfr not found"
    return 127
  fi

  if (( with_text )) && ! (( $+commands[jq] )); then
    print -u2 "burl: jq not found (required by --with-text)"
    return 127
  fi

  if (( with_text )) && ! (( $+commands[curl] )); then
    print -u2 \
      "burl: curl not found (required by --with-text for inline images)"
    return 127
  fi

  case "$max_wait" in
    ''|*[!0-9]*)
      print -u2 \
        "burl: BURL_MAX_WAIT_TIME must be a non-negative integer"
      return 2
      ;;
  esac

  local runtime_root
  local reboot_safe=0

  if [[ -n ${BURL_LOG_DIR:-} ]]; then
    runtime_root="$BURL_LOG_DIR"
  elif [[
    -n ${XDG_RUNTIME_DIR:-} &&
    -d "$XDG_RUNTIME_DIR" &&
    -O "$XDG_RUNTIME_DIR" &&
    -w "$XDG_RUNTIME_DIR" &&
    -x "$XDG_RUNTIME_DIR"
  ]]; then
    runtime_root="$XDG_RUNTIME_DIR"
    reboot_safe=1
  elif [[
    -d "/run/user/$EUID" &&
    -O "/run/user/$EUID" &&
    -w "/run/user/$EUID" &&
    -x "/run/user/$EUID"
  ]]; then
    runtime_root="/run/user/$EUID"
    reboot_safe=1
  else
    runtime_root="${TMPDIR:-/tmp}"
  fi

  if [[ ! -d "$runtime_root" || ! -w "$runtime_root" || ! -x "$runtime_root" ]]; then
    print -u2 \
      "burl: temporary directory is not usable: $runtime_root"
    return 1
  fi

  local work_dir
  local log
  local rc=0
  local keep_work=0

  work_dir="$(mktemp -d "${runtime_root%/}/burl.XXXXXXXX")" || {
    print -u2 "burl: could not create a private temporary directory"
    return 1
  }

  chmod 700 -- "$work_dir" 2>/dev/null || {
    rm -rf -- "$work_dir"
    print -u2 "burl: could not secure temporary directory: $work_dir"
    return 1
  }

  log="$work_dir/bdfr.log"

  # Clean up on normal returns and catchable interruptions. SIGKILL cannot be
  # trapped; XDG_RUNTIME_DIR and /run/user/$EUID are reboot-volatile.
  trap 'rm -rf -- "$work_dir"; return 130' INT
  trap 'rm -rf -- "$work_dir"; return 143' TERM
  trap 'rm -rf -- "$work_dir"; return 129' HUP

  if (( ! reboot_safe )); then
    print -u2 \
      "burl: warning: $runtime_root is not guaranteed to be cleared at reboot"
    print -u2 \
      "burl: warning: leave BURL_LOG_DIR unset and configure XDG_RUNTIME_DIR for that guarantee"
  fi

  # Use a strict expression to decide whether an exit-0 run had hidden
  # failures, and a broader expression only for displaying useful context.
  local failure_re
  local display_re

  failure_re='(\[[^]]*[[:space:]]-[[:space:]]*(ERROR|CRITICAL)\][[:space:]]*-)|(^|[[:space:]\[])(ERROR|CRITICAL)([[:space:]\]:-]|$)|Traceback \(most recent call last\)|Max retries exceeded|Max wait time exceeded'

  display_re="${failure_re}|HTTP Error[[:space:]]+429|429[[:space:]]+Too Many Requests|Too Many Requests|received[[:space:]]+429[[:space:]]+HTTP response|Response code[[:space:]]+429|[Tt]imed out|[Tt]imeout|[Cc]onnection aborted|[Cc]onnection reset|curl: \([0-9]+\)"

  {
    local -a bdfr_opts
    local clone_dir=""
    local processing_rc=0
    local logged_failure=0

    if (( with_text )); then
      # Clone downloads and archives each Submission object in one BDFR/PRAW
      # process. This avoids the extra Reddit fetch caused by running download
      # and archive as two independent commands.
      clone_dir="$work_dir/clone-output"

      mkdir -m 700 -- "$clone_dir" || {
        print -r -- \
          "[burl - ERROR] - Could not create temporary clone directory: $clone_dir" \
          >> "$log"
        rc=1
      }

      if (( rc == 0 )); then
        bdfr_opts=(
          clone "$clone_dir"
          --folder-scheme ''
          --file-scheme "$file_scheme"
          --filename-restriction-scheme windows
          --format json
          --log "$log"
          --max-wait-time "$max_wait"
        )

        bdfr "${bdfr_opts[@]}" "${args[@]}"
        rc=$?

        # Even when cloning or archiving fails, keep any media/text that was
        # successfully downloaded before the failure.
        _burl_promote_clone_files "$clone_dir" "$log" || processing_rc=1

        _burl_process_clone_json \
          "$clone_dir" \
          "$work_dir" \
          "$log" \
          "$failure_re" || processing_rc=1
      else
        rm -rf -- "$clone_dir"
      fi

      if _burl_log_has_failures "$log" "$failure_re"; then
        logged_failure=1
      fi

      if (( rc != 0 || processing_rc != 0 || logged_failure )); then
        keep_work=1

        if (( rc != 0 )); then
          _burl_report_failure \
            "BDFR CLONE FAILED with exit code $rc" \
            "$log" \
            "$display_re" \
            "burl: files successfully downloaded before the failure were kept" \
            "burl: temporary archive JSON was deleted"
        else
          _burl_report_failure \
            "BDFR CLONE COMPLETED WITH ERRORS" \
            "$log" \
            "$display_re" \
            "burl: some requested post text or media may be missing" \
            "burl: files successfully downloaded were kept" \
            "burl: temporary archive JSON was deleted"
        fi

        (( rc != 0 )) && return "$rc"
        return 1
      fi

      return 0
    fi

    # Normal mode remains a direct media download into the current directory.
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
      keep_work=1

      _burl_report_failure \
        "BDFR FAILED with exit code $rc" \
        "$log" \
        "$display_re" \
        "burl: files already downloaded were kept"

      return "$rc"
    fi

    if _burl_log_has_failures "$log" "$failure_re"; then
      keep_work=1

      _burl_report_failure \
        "BDFR COMPLETED WITH LOGGED ERRORS" \
        "$log" \
        "$display_re" \
        "burl: some requested data may not have downloaded" \
        "burl: files successfully downloaded were kept"

      return 1
    fi

    return 0

  } always {
    if [[ ${BURL_KEEP_LOG:-0} == 1 ]] ||
       (( keep_work && reboot_safe )); then
      print -u2 "burl: kept private temporary data at: $work_dir"

      if (( reboot_safe )); then
        print -u2 "burl: this directory will not survive reboot/full logout"
      else
        print -u2 \
          "burl: warning: this location may survive reboot; remove it manually when finished"
      fi
    else
      rm -rf -- "$work_dir"
    fi
  }
}
