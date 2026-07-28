# BDFR helper functions


## Saved Posts
#
# Usage:
#   bdfr-saved
#   bdfr-saved 100
#   bdfr-saved --verbose
#   bdfr-saved 250 --verbose

bdfr-saved() {
  emulate -L zsh

  local limit=""
  local out="$HOME/BDFR/bdfr_posts_new"
  local -a args
  local -a verbose_args

  if ! command -v bdfr >/dev/null 2>&1; then
    echo "bdfr is not installed or not in PATH."
    return 127
  fi

  # A numeric first argument is the optional limit.
  if [[ "${1:-}" == <-> ]]; then
    limit="$1"
    shift
  fi

  while (( $# > 0 )); do
    case "$1" in
      -v|--verbose)
        verbose_args+=("$1")
        shift
        ;;

      *)
        echo "Unsupported argument for bdfr-saved: $1"
        echo "Usage: bdfr-saved [limit] [-v|--verbose]"
        echo
        echo "Examples:"
        echo "  bdfr-saved"
        echo "  bdfr-saved 100"
        echo "  bdfr-saved --verbose"
        echo "  bdfr-saved 250 --verbose"
        return 1
        ;;
    esac
  done

  mkdir -p -- "$out" || return

  args=(
    download "$out"
    --user me
    --saved
    --authenticate
    --file-scheme "{TITLE}_{POSTID}_{REDDITOR}"
    --filename-restriction-scheme windows
    --no-dupes
    --search-existing
  )

  if [[ -n "$limit" ]]; then
    args+=(--limit "$limit")
  fi

  command bdfr "${args[@]}" "${verbose_args[@]}"
}


## Redditors
#
# Usage:
#   bdfr-redditors redditor1
#   bdfr-redditors 100 redditor1
#   bdfr-redditors redditor1 redditor2
#
#   bdfr-redditors --new redditor1
#   bdfr-redditors --top redditor1
#   bdfr-redditors 100 --top redditor1
#   bdfr-redditors --top --time year redditor1
#
#   bdfr-redditors redditor1 \
#     --file-scheme '{TITLE}_{POSTID}_{REDDITOR}'
#
# Defaults:
#   limit: maximum available from Reddit
#   mode: newest
#   top time period: all
#   file-scheme: {TITLE}_{POSTID}_{REDDITOR}

bdfr-redditors() {
  emulate -L zsh

  local limit=""
  local sort="new"
  local time="all"
  local time_explicit=0
  local file_scheme="{TITLE}_{POSTID}_{REDDITOR}"
  local out="$HOME/Downloads/redditors"

  local -a users
  local -a args
  local user

  if ! command -v bdfr >/dev/null 2>&1; then
    echo "bdfr is not installed or not in PATH."
    return 127
  fi

  # A numeric first argument is the optional limit.
  if [[ "${1:-}" == <-> ]]; then
    limit="$1"
    shift
  fi

  while (( $# > 0 )); do
    case "$1" in
      --new)
        sort="new"
        shift
        ;;

      --top)
        sort="top"
        shift
        ;;

      -S|--sort)
        if (( $# < 2 )); then
          echo "Missing value for $1"
          return 1
        fi

        sort="$2"

        case "$sort" in
          new|top|hot|controversial)
            ;;
          *)
            echo "Unsupported redditor sort: $sort"
            echo "Supported sorts: new, top, hot, controversial"
            return 1
            ;;
        esac

        shift 2
        ;;

      -t|--time)
        if (( $# < 2 )); then
          echo "Missing value for $1"
          return 1
        fi

        time="$2"

        case "$time" in
          all|year|month|week|day|hour)
            ;;
          *)
            echo "Unsupported time period: $time"
            echo "Supported periods: all, year, month, week, day, hour"
            return 1
            ;;
        esac

        time_explicit=1
        shift 2
        ;;

      --file-scheme)
        if (( $# < 2 )); then
          echo "Missing value for --file-scheme"
          return 1
        fi

        file_scheme="$2"

        if [[ "$file_scheme" != *"{POSTID}"* ]]; then
          echo "Refusing file scheme without {POSTID}, because filenames may collide."
          return 1
        fi

        shift 2
        ;;

      --)
        shift
        users+=("$@")
        break
        ;;

      -*)
        echo "Unsupported option for bdfr-redditors: $1"
        echo "Usage: bdfr-redditors [limit] [--new|--top] redditor1 [redditor2 ...]"
        echo "       bdfr-redditors [limit] redditor1 [redditor2 ...] [--time TIME] [--file-scheme SCHEME]"
        return 1
        ;;

      *)
        users+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#users[@]} == 0 )); then
    echo "Usage: bdfr-redditors [limit] [--new|--top] redditor1 [redditor2 ...]"
    echo
    echo "Examples:"
    echo "  bdfr-redditors SomeUser"
    echo "  bdfr-redditors 100 SomeUser"
    echo "  bdfr-redditors --top SomeUser"
    echo "  bdfr-redditors 100 --top SomeUser"
    echo "  bdfr-redditors --top --time year SomeUser"
    return 1
  fi

  if (( time_explicit )) &&
     [[ "$sort" != "top" && "$sort" != "controversial" ]]; then
    echo "--time only applies to top or controversial sorting."
    return 1
  fi

  mkdir -p -- "$out" || return

  args=(
    download "$out"
    --submitted
    --sort "$sort"
    --folder-scheme "{REDDITOR}"
    --file-scheme "$file_scheme"
    --filename-restriction-scheme windows
    --no-dupes
    --search-existing
  )

  if [[ -n "$limit" ]]; then
    args+=(--limit "$limit")
  fi

  if [[ "$sort" == "top" || "$sort" == "controversial" ]]; then
    args+=(--time "$time")
  fi

  for user in "${users[@]}"; do
    args+=(--user "$user")
  done

  command bdfr "${args[@]}"
}


## Subreddits
#
# Usage:
#   bdfr-subreddits linux
#   bdfr-subreddits 100 linux
#   bdfr-subreddits linux fedora
#
#   bdfr-subreddits --top linux
#   bdfr-subreddits --new linux
#   bdfr-subreddits --score 1000 linux
#   bdfr-subreddits --no-min-score linux
#
#   bdfr-subreddits --top --time all --score 500 linux
#   bdfr-subreddits 100 --new linux fedora
#
# Defaults:
#   limit: maximum available from Reddit
#   mode: top
#   top time period: year
#   minimum score in top mode: 7000
#   minimum score in new mode: none
#   file-scheme: {REDDITOR}_{TITLE}_{POSTID}

bdfr-subreddits() {
  emulate -L zsh

  local limit=""
  local sort="top"
  local time="year"
  local time_explicit=0

  local min_score=7000
  local score_explicit=0

  local file_scheme="{REDDITOR}_{TITLE}_{POSTID}"
  local out="$HOME/Downloads/subreddits"

  local -a subs
  local -a args
  local sub

  if ! command -v bdfr >/dev/null 2>&1; then
    echo "bdfr is not installed or not in PATH."
    return 127
  fi

  # A numeric first argument is the optional limit.
  if [[ "${1:-}" == <-> ]]; then
    limit="$1"
    shift
  fi

  while (( $# > 0 )); do
    case "$1" in
      --new)
        sort="new"
        shift
        ;;

      --top)
        sort="top"
        shift
        ;;

      -S|--sort)
        if (( $# < 2 )); then
          echo "Missing value for $1"
          return 1
        fi

        sort="$2"

        case "$sort" in
          new|top|hot|rising|controversial)
            ;;
          *)
            echo "Unsupported subreddit sort: $sort"
            echo "Supported sorts: new, top, hot, rising, controversial"
            return 1
            ;;
        esac

        shift 2
        ;;

      -t|--time)
        if (( $# < 2 )); then
          echo "Missing value for $1"
          return 1
        fi

        time="$2"

        case "$time" in
          all|year|month|week|day|hour)
            ;;
          *)
            echo "Unsupported time period: $time"
            echo "Supported periods: all, year, month, week, day, hour"
            return 1
            ;;
        esac

        time_explicit=1
        shift 2
        ;;

      --score|--min-score)
        if (( $# < 2 )) || [[ "$2" != <-> ]]; then
          echo "Missing numeric value for $1"
          return 1
        fi

        min_score="$2"
        score_explicit=1
        shift 2
        ;;

      --no-min-score)
        min_score=""
        score_explicit=1
        shift
        ;;

      --file-scheme)
        if (( $# < 2 )); then
          echo "Missing value for --file-scheme"
          return 1
        fi

        file_scheme="$2"

        if [[ "$file_scheme" != *"{POSTID}"* ]]; then
          echo "Refusing file scheme without {POSTID}, because filenames may collide."
          return 1
        fi

        shift 2
        ;;

      --)
        shift
        subs+=("$@")
        break
        ;;

      -*)
        echo "Unsupported option for bdfr-subreddits: $1"
        echo "Usage: bdfr-subreddits [limit] [--new|--top] subreddit1 [subreddit2 ...]"
        echo "       bdfr-subreddits [limit] subreddit1 [subreddit2 ...] [--score N] [--time TIME]"
        return 1
        ;;

      *)
        subs+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#subs[@]} == 0 )); then
    echo "Usage: bdfr-subreddits [limit] [--new|--top] subreddit1 [subreddit2 ...]"
    echo
    echo "Examples:"
    echo "  bdfr-subreddits linux"
    echo "  bdfr-subreddits 100 linux"
    echo "  bdfr-subreddits --new linux"
    echo "  bdfr-subreddits --score 1000 linux"
    echo "  bdfr-subreddits --no-min-score linux"
    return 1
  fi

  if (( time_explicit )) &&
     [[ "$sort" != "top" && "$sort" != "controversial" ]]; then
    echo "--time only applies to top or controversial sorting."
    return 1
  fi

  # New posts should not have to accumulate 7000 upvotes first.
  # An explicitly supplied --score still applies in new mode.
  if [[ "$sort" == "new" ]] && (( ! score_explicit )); then
    min_score=""
  fi

  mkdir -p -- "$out" || return

  args=(
    download "$out"
    --sort "$sort"
    --folder-scheme "{SUBREDDIT}"
    --file-scheme "$file_scheme"
    --filename-restriction-scheme windows
    --no-dupes
    --search-existing
  )

  if [[ -n "$limit" ]]; then
    args+=(--limit "$limit")
  fi

  if [[ "$sort" == "top" || "$sort" == "controversial" ]]; then
    args+=(--time "$time")
  fi

  if [[ -n "$min_score" ]]; then
    args+=(--min-score "$min_score")
  fi

  for sub in "${subs[@]}"; do
    args+=(--subreddit "$sub")
  done

  command bdfr "${args[@]}"
}
