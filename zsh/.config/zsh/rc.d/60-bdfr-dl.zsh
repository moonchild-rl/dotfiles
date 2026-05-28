# Download reddit posts into the current folder via URL or ID
# Examples:
#   burl https://www.reddit.com/r/test/comments/abc123/example/
#   burl abc123
#   burl abc123 def456 https://redd.it/ghi789
#
# Disable conversion:
#   burl --no-convert abc123
#   burl -nc abc123
burl() {
  emulate -L zsh

  (( $# )) || {
    print -u2 "usage: burl [--no-convert|-nc] <url-or-id> [more-urls-or-ids ...]"
    return 2
  }

  local convert=1
  local args=()
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

  local marker
  marker="$(mktemp)" || return 1

  bdfr download . \
    --folder-scheme '' \
    "${args[@]}"

  local rc=$?
  if (( rc != 0 )); then
    rm -f "$marker"

    print -u2 ""
    print -u2 "========================================"
    print -u2 "burl: BDFR FAILED with exit code $rc"
    print -u2 "========================================"

    return "$rc"
  fi

  if (( convert )); then
	if (( $+commands[ffmpeg] )); then
	  find . -type f -cnewer "$marker" -iname '*.gif' -exec sh -c '
	    for f do
	      out="${f%.*}.mp4"

	      if [ -e "$out" ]; then
		echo "Skipping GIF conversion, output exists: $out" >&2
		continue
	      fi

	      ffmpeg -hide_banner -loglevel error -i "$f" \
		-movflags +faststart -pix_fmt yuv420p "$out" || {
		  rm -f -- "$out"
		  continue
		}

	      old_size=$(stat -c%s "$f")
	      new_size=$(stat -c%s "$out")

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
        for f do
          out="${f%.*}.webp"

          if [ -e "$out" ]; then
            echo "Skipping WebP conversion, output exists: $out" >&2
            continue
          fi

          cwebp -quiet -q 85 "$f" -o "$out" || {
            rm -f -- "$out"
            continue
          }

	  old_size=$(stat -c%s "$f")
	  new_size=$(stat -c%s "$out")

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

  rm -f "$marker"
}
