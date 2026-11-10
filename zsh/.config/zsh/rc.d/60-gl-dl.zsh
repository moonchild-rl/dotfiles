# gallery-dl helpers for Zsh.
#
# Set once in your Zsh configuration:
#   export GL_REDDIT_USER='YourRedditUsername'
# Optional: export GL_REDDIT_BROWSER=firefox
#
# gldl URL [...]              Any supported site, files in the current directory.
# gl-reddit URL|POST_ID [...]  Reddit submissions in the current directory.
# gl-saved [N] [USERNAME]     N most recently saved Reddit posts, by subreddit.
# gl-user [N] [options] USER [...]   Submitted posts by Reddit user.
# gl-subreddit [N] [options] SUB [...]   Posts from subreddits.
#
# These Reddit helpers use an isolated configuration to reproduce the working
# REST + Firefox-cookies combination, independent of the ordinary config.json.
# A per-destination archive is deliberately NOT used: existing target filenames
# are skipped, while files missing from the target can be fetched again.

_gl_nonnegative_integer() {
  emulate -L zsh
  [[ -n "${1:-}" && "${1:-}" != *[^0-9]* ]]
}

_gl_positive_integer() {
  emulate -L zsh
  _gl_nonnegative_integer "${1:-}" && [[ "$1" == *[1-9]* ]]
}

_gl_reddit_id() {
  emulate -L zsh
  local source="$1"
  (( ${#source} >= 5 && ${#source} <= 10 )) &&
    [[ "$source" != *[^[:alnum:]]* ]]
}

_gl_reddit_url() {
  emulate -L zsh
  local source="$1"
  if _gl_reddit_id "$source"; then
    print -r -- "https://redd.it/$source"
  else
    print -r -- "$source"
  fi
}

# _gl_reddit_run OUT flat|subreddit|author [gallery-dl options] URL ...
_gl_reddit_run() {
  emulate -L zsh
  local out="$1" layout="$2"
  shift 2

  if ! command -v gallery-dl >/dev/null 2>&1; then
    print -u2 'gallery-dl is not installed or not in PATH.'
    return 127
  fi

  mkdir -p -- "$out" || return 1

  local -a destination
  case "$layout" in
    flat)
      destination=(-D "$out")
      ;;
    subreddit)
      destination=(--destination "$out" -o 'extractor.reddit.directory=["{subreddit}"]')
      ;;
    author)
      destination=(--destination "$out" -o 'extractor.reddit.directory=["{author}"]')
      ;;
    *)
      print -u2 "gl-reddit: unknown layout: $layout"
      return 2
      ;;
  esac

  # A sidecar for EACH post (including posts without images/videos).
  # The 'post' event is supported by gallery-dl's metadata postprocessor.
  local text_processor='[{"name":"metadata","event":"post","mode":"custom","filename":"{title[:100]}_{id}_{author}.txt","skip":true,"filter":"locals().get(\"title\") is not None","content-format":"{title}\n\n{selftext}\n\nhttps://www.reddit.com{permalink}\n"}]'

  command gallery-dl --config-ignore \
    -o extractor.reddit.api=rest \
    -o extractor.reddit.videos=dash \
    -o extractor.reddit.comments=0 \
    -o extractor.reddit.morecomments=false \
    -o extractor.reddit.embeds=false \
    -o extractor.reddit.recursion=0 \
    -o extractor.reddit.selftext=false \
    -o extractor.reddit.previews=true \
    -o extractor.reddit.parent-directory=true \
    -o extractor.skip=true \
    -o extractor.path-restrict=windows+ \
    -o 'extractor.reddit.filename={title[:100]}_{id}_{author}{num:?_//>02}.{extension}' \
    -o "extractor.reddit.postprocessors=$text_processor" \
    -o downloader.ytdl.module=yt_dlp \
    --cookies-from-browser "${GL_REDDIT_BROWSER:-firefox}" \
    --sleep-request 2 \
    --write-log "$out/gallery-dl.log" \
    --Print-to-file 'error:{title} | https://www.reddit.com{permalink}' "$out/failed-posts.txt" \
    --error-file "$out/failed-input-urls.txt" \
    "${destination[@]}" "$@"
}

# Single Reddit submissions into the current directory.
# Bare post IDs (5-10 alphanumeric characters) are supported.
gl-reddit() {
  emulate -L zsh
  if (( $# == 0 )) || [[ "$1" == '-h' || "$1" == '--help' ]]; then
    print 'usage: gl-reddit URL|POST_ID [URL|POST_ID ...]'
    return $(( $# == 0 ? 2 : 0 ))
  fi

  local -a sources
  local source
  for source in "$@"; do
    sources+=("$(_gl_reddit_url "$source")")
  done
  _gl_reddit_run "$PWD" flat "${sources[@]}"
}

# Download anything gallery-dl supports into the current directory.
# Reddit links/IDs use the special Reddit settings. Other sites retain your
# normal gallery-dl config (Twitter, Instagram, Bluesky, etc.).
# Disable the global download archive for one-off downloads so an item archived
# somewhere else does not get skipped here.
gldl() {
  emulate -L zsh
  if (( $# == 0 )) || [[ "$1" == '-h' || "$1" == '--help' ]]; then
    print 'usage: gldl URL|REDDIT_POST_ID [URL ...]'
    return $(( $# == 0 ? 2 : 0 ))
  fi

  if ! command -v gallery-dl >/dev/null 2>&1; then
    print -u2 'gldl: gallery-dl is not installed or not in PATH.'
    return 127
  fi

  local src rc=0
  for src in "$@"; do
    case "$src" in
      *://reddit.com/*|*://www.reddit.com/*|*://old.reddit.com/*|*://redd.it/*)
        gl-reddit "$src" || rc=1
        ;;
      *)
        if _gl_reddit_id "$src"; then
          gl-reddit "$src" || rc=1
        else
          command gallery-dl -D "$PWD" -o extractor.archive=null "$src" || rc=1
        fi
        ;;
    esac
  done
  return "$rc"
}

# gl-saved 100
# gl-saved 100 YourRedditUsername
# gl-saved       (uses configured GL_REDDIT_USER, all accessible saved posts)
gl-saved() {
  emulate -L zsh
  if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    print 'usage: gl-saved [LIMIT] [REDDIT_USERNAME]'
    print 'Set GL_REDDIT_USER once to omit the username.'
    return 0
  fi

  local limit='' username="${GL_REDDIT_USER:-}"
  if [[ -n "${1:-}" ]] && _gl_positive_integer "$1"; then
    limit="$1"
    shift
  elif _gl_nonnegative_integer "${1:-}"; then
    print -u2 'gl-saved: limit must be positive'
    return 2
  fi

  if (( $# > 1 )); then
    print -u2 'usage: gl-saved [LIMIT] [REDDIT_USERNAME]'
    return 2
  fi
  if (( $# == 1 )); then
    username="${1#u/}"
  fi
  if [[ -z "$username" ]]; then
    print -u2 'gl-saved: set GL_REDDIT_USER or supply a username as the last argument.'
    return 2
  fi

  local out="$HOME/GLDL/reddit_posts_saved_new"
  local -a opts
  [[ -n "$limit" ]] && opts+=(--post-range "1-$limit")
  print -r -- "gl-saved: downloading to $out"
  _gl_reddit_run "$out" subreddit "${opts[@]}" "https://www.reddit.com/user/$username/saved/"
}

# Download submitted posts by one or several Reddit users.
# Default: new, all accessible posts, saved to ~/GLDL/redditors/{author}/.
# Examples:
#   gl-user 100 --new SomeUser
#   gl-user 250 --top --time year SomeUser AnotherUser
gl-user() {
  emulate -L zsh
  local limit='' sort=new period=all
  local -a users opts urls
  if _gl_nonnegative_integer "${1:-}"; then
    _gl_positive_integer "$1" || { print -u2 "limit must be a positive integer"; return 2; }
    limit="$1"
    shift
  fi

  while (( $# )); do
    case "$1" in
      --new) sort=new; shift ;;
      --top) sort=top; shift ;;
      --time|-t)
        (( $# >= 2 )) || { print -u2 'gl-user: missing time period'; return 2; }
        period="$2"; shift 2 ;;
      -h|--help)
        print 'usage: gl-user [LIMIT] [--new|--top] [--time all|year|month|week|day|hour] USER [...]'
        return 0 ;;
      --) shift; users+=("$@"); break ;;
      -*) print -u2 "gl-user: invalid option $1"; return 2 ;;
      *) users+=("${1#u/}"); shift ;;
    esac
  done
  (( ${#users[@]} )) || { print -u2 'gl-user: specify at least one Reddit user.'; return 2; }
  case "$period" in
    all|year|month|week|day|hour) ;;
    *) print -u2 'gl-user: invalid time period'; return 2 ;;
  esac
  if [[ "$sort" != top && "$period" != all ]]; then
    print -u2 'gl-user: --time requires --top'; return 2
  fi

  [[ -n "$limit" ]] && opts+=(--post-range "1-$limit")
  local user
  for user in "${users[@]}"; do
    if [[ "$sort" == top ]]; then
      urls+=("https://www.reddit.com/user/$user/submitted/?sort=top&t=$period")
    else
      urls+=("https://www.reddit.com/user/$user/submitted/?sort=new")
    fi
  done
  _gl_reddit_run "$HOME/GLDL/redditors" author "${opts[@]}" "${urls[@]}"
}

# Download posts from one or several subreddits.
# Default: top from last year with score >= 7000 (like BDFR).
# With --new, the default score threshold is disabled.
# Examples:
#   gl-subreddit 100 --top --time year --score 7000 linux
#   gl-subreddit 50 --new fedora linux
gl-subreddit() {
  emulate -L zsh
  local limit='' sort=top period=year min_score='' time_explicit=0 score_explicit=0
  local -a subs urls opts
  if _gl_nonnegative_integer "${1:-}"; then
    _gl_positive_integer "$1" || { print -u2 "limit must be a positive integer"; return 2; }
    limit="$1"; shift
  fi

  while (( $# )); do
    case "$1" in
      --top) sort=top; shift ;;
      --new) sort=new; shift ;;
      --time|-t)
        (( $# >= 2 )) || { print -u2 'gl-subreddit: missing time period'; return 2; }
        period="$2"; time_explicit=1; shift 2 ;;
      --score|--min-score)
        (( $# >= 2 )) || { print -u2 'gl-subreddit: missing minimum score'; return 2; }
        min_score="$2"; score_explicit=1; shift 2 ;;
      -h|--help)
        print 'usage: gl-subreddit [LIMIT] [--top|--new] [--time PERIOD] [--score N] SUB [...]'
        return 0 ;;
      --) shift; subs+=("$@"); break ;;
      -*) print -u2 "gl-subreddit: invalid option $1"; return 2 ;;
      *) subs+=("${1#r/}"); shift ;;
    esac
  done
  (( ${#subs[@]} )) || { print -u2 'gl-subreddit: specify at least one subreddit.'; return 2; }
  case "$period" in
    all|year|month|week|day|hour) ;;
    *) print -u2 'gl-subreddit: invalid time period'; return 2 ;;
  esac
  if [[ -n "$min_score" ]] && ! _gl_nonnegative_integer "$min_score"; then
    print -u2 'gl-subreddit: --score must be a nonnegative integer'; return 2
  fi
  if [[ "$sort" != top && $time_explicit -eq 1 ]]; then
    print -u2 'gl-subreddit: --time requires --top'; return 2
  fi
  if [[ "$sort" == top && $score_explicit -eq 0 ]]; then
    min_score=7000
  fi
  [[ -n "$limit" ]] && opts+=(--post-range "1-$limit")
  [[ -n "$min_score" ]] && opts+=(--post-filter "score >= $min_score")

  local sub
  for sub in "${subs[@]}"; do
    if [[ "$sort" == top ]]; then
      urls+=("https://www.reddit.com/r/$sub/top/?t=$period")
    else
      urls+=("https://www.reddit.com/r/$sub/new/")
    fi
  done
  _gl_reddit_run "$HOME/GLDL/subreddits" subreddit "${opts[@]}" "${urls[@]}"
}
