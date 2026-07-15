# BDFR helper functions

## Saved Posts
### Usage:
### bdfr-saved
### bdfr-saved 100
### bdfr-saved --verbose
### bdfr-saved 250 --verbose
###
### Defaults:
### limit: 100

bdfr-saved() {
  emulate -L zsh

  local limit=100
  local out="$HOME/BDFR/bdfr_posts_new"
  local -a verbose_args
  local -a args

  if ! command -v bdfr >/dev/null 2>&1; then
    echo "bdfr is not installed or not in PATH."
    return 127
  fi

  while (( $# > 0 )); do
    case "$1" in
      <->)
        limit="$1"
        shift
        ;;

      -v|--verbose)
        verbose_args+=("$1")
        shift
        ;;

      *)
        echo "Usage: bdfr-saved [limit] [-v|--verbose]"
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
    -L "$limit"
  )

  command bdfr "${args[@]}" "${verbose_args[@]}"
}


## Redditors
### Usage:
### bdfr-redditors username1
### bdfr-redditors 100 username1
### bdfr-redditors 100 username1 username2 username3
### bdfr-redditors username1 --sort top
### bdfr-redditors username1 --file-scheme '{TITLE}_{POSTID}_{REDDITOR}'
###
### Defaults:
### limit: 100
### sort: new
### file-scheme: {TITLE}_{POSTID}_{REDDITOR}

bdfr-redditors() {
  emulate -L zsh

  local limit=100
  local sort="new"
  local file_scheme="{TITLE}_{POSTID}_{REDDITOR}"
  local out="$HOME/Downloads/redditors"
  local -a users
  local -a args
  local user

  if ! command -v bdfr >/dev/null 2>&1; then
    echo "bdfr is not installed or not in PATH."
    return 127
  fi

  if [[ "${1:-}" == <-> ]]; then
    limit="$1"
    shift
  fi

  while (( $# > 0 )); do
    case "$1" in
      -S|--sort)
        sort="${2:-}"

        if [[ -z "$sort" ]]; then
          echo "Missing value for $1"
          return 1
        fi

        shift 2
        ;;

      --file-scheme)
        file_scheme="${2:-}"

        if [[ -z "$file_scheme" ]]; then
          echo "Missing value for --file-scheme"
          return 1
        fi

        if [[ "$file_scheme" != *"{POSTID}"* ]]; then
          echo "Refusing file scheme without {POSTID}, because filenames may collide."
          return 1
        fi

        shift 2
        ;;

      -*)
        echo "Unsupported option for bdfr-redditors: $1"
        echo "Usage: bdfr-redditors [limit] redditor1 [redditor2 ...] [--sort SORT] [--file-scheme SCHEME]"
        return 1
        ;;

      *)
        users+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#users[@]} == 0 )); then
    echo "Usage: bdfr-redditors [limit] redditor1 [redditor2 ...] [--sort SORT] [--file-scheme SCHEME]"
    return 1
  fi

  mkdir -p -- "$out" || return

  args=(
    download "$out"
    --submitted
    --sort "$sort"
    --limit "$limit"
    --folder-scheme "{REDDITOR}"
    --file-scheme "$file_scheme"
    --filename-restriction-scheme windows
    --no-dupes
    --search-existing
  )

  for user in "${users[@]}"; do
    args+=(--user "$user")
  done

  command bdfr "${args[@]}"
}


## Subreddits
### Usage:
### bdfr-subreddits linux
### bdfr-subreddits 100 linux
### bdfr-subreddits 100 linux fedora
### bdfr-subreddits linux --sort new
### bdfr-subreddits linux --sort top --time all
### bdfr-subreddits 100 linux --sort top --time month --min-score 500
### bdfr-subreddits linux --file-scheme '{SUBREDDIT}_{TITLE}_{POSTID}'
###
### Defaults:
### limit: none
### sort: top
### time: year
### min-score: 7000
### file-scheme: {REDDITOR}_{TITLE}_{POSTID}

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
  local sub

  if ! command -v bdfr >/dev/null 2>&1; then
    echo "bdfr is not installed or not in PATH."
    return 127
  fi

  if [[ "${1:-}" == <-> ]]; then
    limit="$1"
    shift
  fi

  while (( $# > 0 )); do
    case "$1" in
      -S|--sort)
        sort="${2:-}"

        if [[ -z "$sort" ]]; then
          echo "Missing value for $1"
          return 1
        fi

        shift 2
        ;;

      -t|--time)
        time="${2:-}"

        if [[ -z "$time" ]]; then
          echo "Missing value for $1"
          return 1
        fi

        shift 2
        ;;

      --min-score)
        min_score="${2:-}"

        if [[ -z "$min_score" || "$min_score" != <-> ]]; then
          echo "Missing numeric value for --min-score"
          return 1
        fi

        shift 2
        ;;

      --file-scheme)
        file_scheme="${2:-}"

        if [[ -z "$file_scheme" ]]; then
          echo "Missing value for --file-scheme"
          return 1
        fi

        if [[ "$file_scheme" != *"{POSTID}"* ]]; then
          echo "Refusing file scheme without {POSTID}, because filenames may collide."
          return 1
        fi

        shift 2
        ;;

      -*)
        echo "Unsupported option for bdfr-subreddits: $1"
        echo "Usage: bdfr-subreddits [limit] subreddit1 [subreddit2 ...] [--sort SORT] [--time TIME] [--min-score N] [--file-scheme SCHEME]"
        return 1
        ;;

      *)
        subs+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#subs[@]} == 0 )); then
    echo "Usage: bdfr-subreddits [limit] subreddit1 [subreddit2 ...] [--sort SORT] [--time TIME] [--min-score N] [--file-scheme SCHEME]"
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

  command bdfr "${args[@]}"
}
