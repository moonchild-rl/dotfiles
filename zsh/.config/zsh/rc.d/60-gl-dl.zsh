# Gallery-dl shortcuts. Source this file from Zsh.
# For saved posts, set: export GL_REDDIT_USER='YourRedditUsername'
# Optional browser:   export GL_REDDIT_BROWSER=firefox
# Run any command with --help for examples.

_gl_positive_integer() {
  emulate -L zsh
  [[ -n "${1:-}" && "$1" != *[^0-9]* && "$1" == *[1-9]* ]]
}

_gl_integer() {
  emulate -L zsh
  [[ -n "${1:-}" && "$1" != *[^0-9]* ]]
}

_gl_error() {
  emulate -L zsh
  print -u2 -r -- "$1: $2"
  print -u2 -r -- "Try '$1 --help'."
  return 2
}

_gl_reddit_id() {
  emulate -L zsh
  [[ ${#1} -ge 5 && ${#1} -le 10 && "$1" != *[^[:alnum:]]* ]]
}

_gl_reddit_url() {
  emulate -L zsh
  if _gl_reddit_id "$1"; then
    print -r -- "https://redd.it/$1"
  else
    print -r -- "$1"
  fi
}

_gl_check_program() {
  emulate -L zsh
  if ! command -v gallery-dl >/dev/null 2>&1; then
    print -u2 -r -- "$1: gallery-dl is not installed or is not in PATH."
    return 127
  fi
  if [[ "${2:-}" == reddit ]] && ! command -v yt-dlp >/dev/null 2>&1; then
    print -u2 -r -- "$1: warning: yt-dlp is missing; Reddit videos may fail."
  fi
}

# Keep each run's reports in a temporary folder, separate from downloads.
_gl_reddit_start() {
  emulate -L zsh
  local report
  report="$(mktemp -d "${TMPDIR:-/tmp}/gallery-dl-${1}.XXXXXXXX")" || return 1
  : > "$report/failed-posts.txt" || return 1
  : > "$report/failed-input-urls.txt" || return 1
  : > "$report/gallery-dl.log" || return 1
  print -r -- "$report"
}

# Show failures and tell the user where to find the complete reports.
_gl_reddit_report() {
  emulate -L zsh
  local report="$1" rc="$2" saved="$3"
  local failed="$report/failed-posts.txt" inputs="$report/failed-input-urls.txt"
  local log="$report/gallery-dl.log"
  local problem=0 auth_hint=0

  if [[ -s "$failed" ]]; then
    problem=1
    print -u2 -r -- "Failed media / posts (full list: $failed):"
    head -n 25 -- "$failed" >&2
    if (( $(wc -l < "$failed") > 25 )); then
      print -u2 -r -- '...more entries in the file above.'
    fi
  fi
  if [[ -s "$inputs" ]]; then
    problem=1
    print -u2 -r -- "Failed input URLs (full list: $inputs):"
    head -n 25 -- "$inputs" >&2
    if (( $(wc -l < "$inputs") > 25 )); then
      print -u2 -r -- '...more entries in the file above.'
    fi
  fi

  if [[ -f "$log" ]] && grep -Eiq 'cookies?:.*(failed|missing|not found|unable)|no cookies|login required|unauthorized|forbidden|HTTP.*(401|403)|error.*(401|403)' "$log"; then
    problem=1
    auth_hint=1
    print -u2 -r -- "Reddit authentication may have failed. Check that you are logged in with ${GL_REDDIT_BROWSER:-firefox} and that gallery-dl can read its cookies."
    print -u2 -r -- 'Set GL_REDDIT_BROWSER if you use a different browser or profile.'
  fi

  if (( ! problem && rc == 0 )) && [[ -f "$log" ]] && grep -Eiq '\[error\]|Failed to download' "$log"; then
    problem=1
    print -u2 -r -- "gallery-dl reported errors. Check $log:"
    grep -Ei '\[error\]|Failed to download' "$log" | head -n 8 >&2
  fi

  if (( rc != 0 )); then
    problem=1
    print -u2 -r -- "gallery-dl exited with status $rc. See $log"
    if [[ "$saved" == yes ]] && (( ! auth_hint )); then
      print -u2 -r -- "Saved posts require a Reddit login. Check cookies in ${GL_REDDIT_BROWSER:-firefox}."
    fi
    if [[ -f "$log" ]]; then
      grep -Ei '\[(error|warning)\]|\[error\]|\[warning\]' "$log" | tail -n 8 >&2
    fi
  elif (( ! problem )); then
    if [[ "$saved" == yes ]] && [[ -f "$log" ]] && grep -qi 'No results for' "$log"; then
      problem=1
      print -u2 -r -- "gl-saved: no saved posts were returned. Verify your Reddit username and browser login/cookies. See $log"
    else
      print -r -- 'Download finished with no reported errors.'
    fi
  fi

  if (( problem )); then
    print -u2 -r -- "Reports: $report"
    return 1
  fi
  print -r -- "Reports: $report (temporary; may be cleared by the OS)"
}

# Internal Reddit downloader. OUT is a folder; LAYOUT is flat, subreddit, or author.
_gl_reddit_run() {
  emulate -L zsh
  local out="$1" layout="$2" report="$3"
  shift 3
  local -a destination
  case "$layout" in
    flat)      destination=(-D "$out") ;;
    subreddit) destination=(--destination "$out" -o 'extractor.reddit.directory=["{subreddit}"]') ;;
    author)    destination=(--destination "$out" -o 'extractor.reddit.directory=["{author}"]') ;;
    *) print -u2 -r -- "Internal error: unknown layout '$layout'"; return 2 ;;
  esac

  # Save a text file for every Reddit post, even text-only posts.
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
    --write-log "$report/gallery-dl.log" \
    --Print-to-file 'error:{title} | https://www.reddit.com{permalink}' "$report/failed-posts.txt" \
    --error-file "$report/failed-input-urls.txt" \
    "${destination[@]}" "$@"
}

# Download any supported link into the current directory, like burl for Reddit.
gldl() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gldl URL|REDDIT_POST_ID [URL ...]'
    print -r -- 'Download to the current directory. Reddit links use Firefox cookies.'
    print -r -- 'Examples: gldl abc123    gldl "https://www.reddit.com/r/linux/comments/abc123/"'
    return 0
  fi
  (( $# > 0 )) || { _gl_error gldl 'provide at least one URL or Reddit post ID'; return 2; }
  _gl_check_program gldl || return $?

  local src rc=0 err=0
  local -a reddit other
  for src in "$@"; do
    case "$src" in
      *://reddit.com/*|*://*.reddit.com/*|*://redd.it/*) reddit+=("$src") ;;
      *)
        if _gl_reddit_id "$src"; then
          reddit+=("$(_gl_reddit_url "$src")")
        elif [[ "$src" == *://* ]]; then
          other+=("$src")
        else
          _gl_error gldl "invalid URL or Reddit post ID: $src"
          err=2
        fi ;;
    esac
  done

  if (( ${#reddit[@]} )); then
    _gl_check_program gldl reddit || return $?
    local report
    report="$(_gl_reddit_start gldl)" || { print -u2 -r -- 'gldl: cannot create temporary report directory.'; return 1; }
    _gl_reddit_run "$PWD" flat "$report" "${reddit[@]}" || rc=$?
    _gl_reddit_report "$report" "$rc" no || err=1
  fi
  if (( ${#other[@]} )); then
    # Keep the normal config for other websites, but ignore its shared archive.
    command gallery-dl -D "$PWD" -o extractor.archive=null "${other[@]}" || {
      print -u2 -r -- 'gldl: some downloads failed (see gallery-dl output).'
      err=1
    }
  fi
  return "$err"
}

# Download recent saved posts into ~/GLDL/reddit_posts_saved_new/{subreddit}/.
gl-saved() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gl-saved [LIMIT] [REDDIT_USERNAME]'
    print -r -- 'Download newest saved entries, grouped by subreddit.'
    print -r -- 'Examples: gl-saved 20    gl-saved 50 MyUsername'
    print -r -- 'Set GL_REDDIT_USER to avoid typing your username.'
    print -r -- 'Error reports are stored temporarily under /tmp (or $TMPDIR).'
    return 0
  fi

  local limit='' username="${GL_REDDIT_USER:-}"
  if _gl_integer "${1:-}"; then
    _gl_positive_integer "$1" || { _gl_error gl-saved 'LIMIT must be positive'; return 2; }
    limit="$1"; shift
  fi
  (( $# <= 1 )) || { _gl_error gl-saved 'too many arguments'; return 2; }
  (( $# == 1 )) && username="${1#u/}"
  [[ -n "$username" ]] || {
    print -u2 -r -- "gl-saved: Reddit username is missing. Set: export GL_REDDIT_USER='YourRedditUsername'"
    print -u2 -r -- 'Or run: gl-saved 20 YourRedditUsername'
    return 2
  }
  [[ "$username" != *[^[:alnum:]_-]* ]] || { _gl_error gl-saved 'invalid Reddit username'; return 2; }
  _gl_check_program gl-saved reddit || return $?

  local out="$HOME/GLDL/reddit_posts_saved_new" report rc=0
  local -a opts
  [[ -n "$limit" ]] && opts+=(--post-range "1-$limit")
  report="$(_gl_reddit_start gl-saved)" || { print -u2 -r -- 'gl-saved: cannot create temporary report directory.'; return 1; }
  print -r -- "Saving posts to $out"
  _gl_reddit_run "$out" subreddit "$report" "${opts[@]}" "https://www.reddit.com/user/$username/saved/" || rc=$?
  _gl_reddit_report "$report" "$rc" yes
}

# Download submissions by one or more Reddit users into ~/GLDL/redditors/.
gl-redditor() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gl-redditor [LIMIT] [--new|--top] [--time PERIOD] USER [...]'
    print -r -- 'Default: newest submissions, no limit.'
    print -r -- 'PERIOD: all, year, month, week, day, hour (with --top).'
    print -r -- 'Examples: gl-redditor 100 SomeUser'
    print -r -- '          gl-redditor 200 --top --time month User1 User2'
    return 0
  fi
  local limit='' sort=new period=all
  local -a users urls opts
  if _gl_integer "${1:-}"; then
    _gl_positive_integer "$1" || { _gl_error gl-redditor 'LIMIT must be positive'; return 2; }
    limit="$1"; shift
  fi
  while (( $# )); do
    case "$1" in
      --new) sort=new; shift ;;
      --top) sort=top; shift ;;
      --time|-t)
        (( $# >= 2 )) || { _gl_error gl-redditor 'missing value for --time'; return 2; }
        period="$2"; shift 2 ;;
      -h|--help) gl-redditor --help; return 0 ;;
      --) shift; users+=("$@"); break ;;
      -*) _gl_error gl-redditor "unknown option: $1"; return 2 ;;
      *) users+=("${1#u/}"); shift ;;
    esac
  done
  (( ${#users[@]} )) || { _gl_error gl-redditor 'provide at least one username'; return 2; }
  case "$period" in
    all|year|month|week|day|hour) ;;
    *) _gl_error gl-redditor "invalid period: $period"; return 2 ;;
  esac
  [[ "$sort" == top || "$period" == all ]] || { _gl_error gl-redditor '--time requires --top'; return 2; }

  local user out="$HOME/GLDL/redditors" report rc=0
  for user in "${users[@]}"; do
    [[ -n "$user" && "$user" != *[^[:alnum:]_-]* ]] || { _gl_error gl-redditor "invalid username: $user"; return 2; }
    if [[ "$sort" == top ]]; then
      urls+=("https://www.reddit.com/user/$user/submitted/?sort=top&t=$period")
    else
      urls+=("https://www.reddit.com/user/$user/submitted/?sort=new")
    fi
  done
  _gl_check_program gl-redditor reddit || return $?
  [[ -n "$limit" ]] && opts+=(--post-range "1-$limit")
  report="$(_gl_reddit_start gl-redditor)" || { print -u2 -r -- 'gl-redditor: cannot create temporary report directory.'; return 1; }
  _gl_reddit_run "$out" author "$report" "${opts[@]}" "${urls[@]}" || rc=$?
  _gl_reddit_report "$report" "$rc" no
}

# Download subreddit posts into ~/GLDL/subreddits/{subreddit}/.
gl-subreddit() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gl-subreddit [LIMIT] [--top|--new] [--time PERIOD] [--score N] SUB [...]'
    print -r -- 'Default: top posts from the last year, minimum score 7000.'
    print -r -- '--new downloads newest posts without a score threshold.'
    print -r -- 'Examples: gl-subreddit 100 linux'
    print -r -- '          gl-subreddit 50 --new linux fedora'
    print -r -- '          gl-subreddit 200 --top --time month --score 1000 linux'
    return 0
  fi
  local limit='' sort=top period=year min_score='' time_explicit=0 score_explicit=0
  local -a subs urls opts
  if _gl_integer "${1:-}"; then
    _gl_positive_integer "$1" || { _gl_error gl-subreddit 'LIMIT must be positive'; return 2; }
    limit="$1"; shift
  fi
  while (( $# )); do
    case "$1" in
      --top) sort=top; shift ;;
      --new) sort=new; shift ;;
      --time|-t)
        (( $# >= 2 )) || { _gl_error gl-subreddit 'missing value for --time'; return 2; }
        period="$2"; time_explicit=1; shift 2 ;;
      --score|--min-score)
        (( $# >= 2 )) || { _gl_error gl-subreddit 'missing value for --score'; return 2; }
        min_score="$2"; score_explicit=1; shift 2 ;;
      -h|--help) gl-subreddit --help; return 0 ;;
      --) shift; subs+=("$@"); break ;;
      -*) _gl_error gl-subreddit "unknown option: $1"; return 2 ;;
      *) subs+=("${1#r/}"); shift ;;
    esac
  done
  (( ${#subs[@]} )) || { _gl_error gl-subreddit 'provide at least one subreddit'; return 2; }
  case "$period" in
    all|year|month|week|day|hour) ;;
    *) _gl_error gl-subreddit "invalid period: $period"; return 2 ;;
  esac
  [[ "$sort" == top || "$time_explicit" == 0 ]] || { _gl_error gl-subreddit '--time requires --top'; return 2; }
  [[ -z "$min_score" || "$min_score" != *[^0-9]* ]] || { _gl_error gl-subreddit '--score must be a nonnegative integer'; return 2; }
  if [[ "$sort" == top && "$score_explicit" == 0 ]]; then
    min_score=7000
  fi

  local sub out="$HOME/GLDL/subreddits" report rc=0
  for sub in "${subs[@]}"; do
    [[ -n "$sub" && "$sub" != *[^[:alnum:]_+]* ]] || { _gl_error gl-subreddit "invalid subreddit: $sub"; return 2; }
    if [[ "$sort" == top ]]; then
      urls+=("https://www.reddit.com/r/$sub/top/?t=$period")
    else
      urls+=("https://www.reddit.com/r/$sub/new/")
    fi
  done
  _gl_check_program gl-subreddit reddit || return $?
  [[ -n "$limit" ]] && opts+=(--post-range "1-$limit")
  [[ -n "$min_score" ]] && opts+=(--post-filter "score >= $min_score")
  report="$(_gl_reddit_start gl-subreddit)" || { print -u2 -r -- 'gl-subreddit: cannot create temporary report directory.'; return 1; }
  _gl_reddit_run "$out" subreddit "$report" "${opts[@]}" "${urls[@]}" || rc=$?
  _gl_reddit_report "$report" "$rc" no
}
