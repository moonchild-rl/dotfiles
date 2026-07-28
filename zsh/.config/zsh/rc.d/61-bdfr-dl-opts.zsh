# BDFR helper functions

_bdfr_need_command() {
  emulate -L zsh

  if ! command -v bdfr >/dev/null 2>&1; then
    echo "bdfr is not installed or not in PATH."
    return 127
  fi
}

_bdfr_positive_integer() {
  emulate -L zsh

  [[ "${1:-}" == <-> ]] && (( $1 > 0 ))
}

_bdfr_require_postid_scheme() {
  emulate -L zsh

  local scheme="$1"

  if [[ -z "$scheme" ]]; then
    echo "Missing value for --file-scheme"
    return 1
  fi

  if [[ "$scheme" != *"{POSTID}"* ]]; then
    echo "Refusing file scheme without {POSTID}, because filenames may collide."
    return 1
  fi
}


## Saved posts
#
# Usage:
#   bdfr-saved [limit] [--verbose]
#   bdfr-saved --help
#
# Examples:
#   bdfr-saved
#   bdfr-saved 250
#   bdfr-saved 250 --verbose
#
# Defaults:
#   limit: maximum available from Reddit
#   output: ~/BDFR/bdfr_posts_new
#   file-scheme: {TITLE}_{POSTID}_{REDDITOR}

bdfr-saved() {
  emulate -L zsh

  local limit=""
  local out="$HOME/BDFR/bdfr_posts_new"
  local -a args
  local -a verbose_args

  _bdfr_need_command || return

  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: bdfr-saved [limit] [--verbose]"
    echo
    echo "Examples:"
    echo "  bdfr-saved"
    echo "  bdfr-saved 250"
    echo "  bdfr-saved 250 --verbose"
    return 0
  fi

  # A numeric first argument is the optional limit.
  if [[ "${1:-}" == <-> ]]; then
    if ! _bdfr_positive_integer "$1"; then
      echo "Limit must be a positive integer."
      return 1
    fi

    limit="$1"
    shift
  fi

  while (( $# > 0 )); do
    case "$1" in
      -v|--verbose)
        verbose_args+=("$1")
        shift
        ;;

      -h|--help)
        echo "Usage: bdfr-saved [limit] [--verbose]"
        return 0
        ;;

      *)
        echo "Unsupported argument for bdfr-saved: $1"
        echo "Usage: bdfr-saved [limit] [--verbose]"
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
# Intended use: pass a limit and choose new or top posts.
#
# Usage:
#   bdfr-redditors [limit] [--new|--top] [--verbose] redditor1 [redditor2 ...]
#   bdfr-redditors [limit] --top [--time PERIOD] [--verbose] redditor1 [...]
#   bdfr-redditors --help
#
# Examples:
#   bdfr-redditors 100 --new SomeUser
#   bdfr-redditors 250 --top SomeUser
#   bdfr-redditors 500 --top --time year SomeUser AnotherUser
#
# Defaults:
#   limit: maximum available from Reddit
#   sort: new
#   top time period: all
#   output: ~/Downloads/redditors
#   folder-scheme: {REDDITOR}
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
  local -a verbose_args
  local user

  _bdfr_need_command || return

  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: bdfr-redditors [limit] [--new|--top] [--verbose] redditor1 [...]"
    echo "       bdfr-redditors [limit] --top [--time all|year|month|week|day|hour] [--verbose] redditor1 [...]"
    echo
    echo "Examples:"
    echo "  bdfr-redditors 100 --new SomeUser"
    echo "  bdfr-redditors 250 --top SomeUser"
    echo "  bdfr-redditors 500 --top --time year SomeUser AnotherUser"
    return 0
  fi

  # A numeric first argument is the optional limit.
  if [[ "${1:-}" == <-> ]]; then
    if ! _bdfr_positive_integer "$1"; then
      echo "Limit must be a positive integer."
      return 1
    fi

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

      -v|--verbose)
        verbose_args+=("$1")
        shift
        ;;

      -S|--sort)
        if (( $# < 2 )); then
          echo "Missing value for $1"
          return 1
        fi

        case "$2" in
          new|top)
            sort="$2"
            ;;
          *)
            echo "Unsupported redditor sort: $2"
            echo "Use --new or --top."
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

        case "$2" in
          all|year|month|week|day|hour)
            time="$2"
            ;;
          *)
            echo "Unsupported time period: $2"
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

        _bdfr_require_postid_scheme "$2" || return
        file_scheme="$2"
        shift 2
        ;;

      -h|--help)
        echo "Usage: bdfr-redditors [limit] [--new|--top] [--verbose] redditor1 [...]"
        return 0
        ;;

      --)
        shift
        users+=("$@")
        break
        ;;

      -*)
        echo "Unsupported option for bdfr-redditors: $1"
        echo "Usage: bdfr-redditors [limit] [--new|--top] [--verbose] redditor1 [...]"
        return 1
        ;;

      *)
        users+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#users[@]} == 0 )); then
    echo "Usage: bdfr-redditors [limit] [--new|--top] [--verbose] redditor1 [...]"
    echo
    echo "Examples:"
    echo "  bdfr-redditors 100 --new SomeUser"
    echo "  bdfr-redditors 250 --top SomeUser"
    echo "  bdfr-redditors 500 --top --time year SomeUser AnotherUser"
    return 1
  fi

  if (( time_explicit )) && [[ "$sort" != "top" ]]; then
    echo "--time only applies when using --top."
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

  if [[ "$sort" == "top" ]]; then
    args+=(--time "$time")
  fi

  for user in "${users[@]}"; do
    args+=(--user "$user")
  done

  command bdfr "${args[@]}" "${verbose_args[@]}"
}


## Subreddits
#
# Intended use: download top posts, with adjustable time and score filters.
#
# Usage:
#   bdfr-subreddits [limit] [--time PERIOD] [--score N] [--verbose] subreddit1 [...]
#   bdfr-subreddits --help
#
# Examples:
#   bdfr-subreddits 100 --time year --score 7000 linux
#   bdfr-subreddits 250 --time month --score 1000 linux fedora
#   bdfr-subreddits --time all --score 5000 wallpapers
#
# Defaults:
#   limit: maximum available from Reddit
#   sort: top
#   time period: year
#   minimum score: 7000
#   output: ~/Downloads/subreddits
#   folder-scheme: {SUBREDDIT}
#   file-scheme: {REDDITOR}_{TITLE}_{POSTID}

bdfr-subreddits() {
  emulate -L zsh

  local limit=""
  local sort="top"
  local time="year"
  local min_score=7000
  local file_scheme="{REDDITOR}_{TITLE}_{POSTID}"
  local out="$HOME/Downloads/subreddits"

  local -a subs
  local -a args
  local -a verbose_args
  local sub

  _bdfr_need_command || return

  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: bdfr-subreddits [limit] [--time all|year|month|week|day|hour] [--score N] [--verbose] subreddit1 [...]"
    echo
    echo "Examples:"
    echo "  bdfr-subreddits 100 --time year --score 7000 linux"
    echo "  bdfr-subreddits 250 --time month --score 1000 linux fedora"
    echo "  bdfr-subreddits --time all --score 5000 wallpapers"
    return 0
  fi

  # A numeric first argument is the optional limit.
  if [[ "${1:-}" == <-> ]]; then
    if ! _bdfr_positive_integer "$1"; then
      echo "Limit must be a positive integer."
      return 1
    fi

    limit="$1"
    shift
  fi

  while (( $# > 0 )); do
    case "$1" in
      --top)
        # Accepted for readability; top is already the only subreddit mode here.
        sort="top"
        shift
        ;;

      -v|--verbose)
        verbose_args+=("$1")
        shift
        ;;

      -S|--sort)
        if (( $# < 2 )); then
          echo "Missing value for $1"
          return 1
        fi

        if [[ "$2" != "top" ]]; then
          echo "Unsupported subreddit sort: $2"
          echo "This helper is intentionally limited to top posts."
          return 1
        fi

        sort="top"
        shift 2
        ;;

      -t|--time)
        if (( $# < 2 )); then
          echo "Missing value for $1"
          return 1
        fi

        case "$2" in
          all|year|month|week|day|hour)
            time="$2"
            ;;
          *)
            echo "Unsupported time period: $2"
            echo "Supported periods: all, year, month, week, day, hour"
            return 1
            ;;
        esac

        shift 2
        ;;

      --score|--min-score)
        if (( $# < 2 )) || ! _bdfr_positive_integer "$2"; then
          echo "Missing positive numeric value for $1"
          return 1
        fi

        min_score="$2"
        shift 2
        ;;

      --file-scheme)
        if (( $# < 2 )); then
          echo "Missing value for --file-scheme"
          return 1
        fi

        _bdfr_require_postid_scheme "$2" || return
        file_scheme="$2"
        shift 2
        ;;

      -h|--help)
        echo "Usage: bdfr-subreddits [limit] [--time PERIOD] [--score N] [--verbose] subreddit1 [...]"
        return 0
        ;;

      --)
        shift
        subs+=("$@")
        break
        ;;

      -*)
        echo "Unsupported option for bdfr-subreddits: $1"
        echo "Usage: bdfr-subreddits [limit] [--time PERIOD] [--score N] [--verbose] subreddit1 [...]"
        return 1
        ;;

      *)
        subs+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#subs[@]} == 0 )); then
    echo "Usage: bdfr-subreddits [limit] [--time PERIOD] [--score N] [--verbose] subreddit1 [...]"
    echo
    echo "Examples:"
    echo "  bdfr-subreddits 100 --time year --score 7000 linux"
    echo "  bdfr-subreddits 250 --time month --score 1000 linux fedora"
    echo "  bdfr-subreddits --time all --score 5000 wallpapers"
    return 1
  fi

  mkdir -p -- "$out" || return

  args=(
    download "$out"
    --sort "$sort"
    --time "$time"
    --min-score "$min_score"
    --folder-scheme "{SUBREDDIT}"
    --file-scheme "$file_scheme"
    --filename-restriction-scheme windows
    --no-dupes
    --search-existing
  )

  if [[ -n "$limit" ]]; then
    args+=(--limit "$limit")
  fi

  for sub in "${subs[@]}"; do
    args+=(--subreddit "$sub")
  done

  command bdfr "${args[@]}" "${verbose_args[@]}"
}
