# Gallery-dl shortcuts.
# Saved-post username priority: explicit argument, GL_REDDIT_USER, then through prompt.
# Set a usual GL_REDDIT_USER in ~/Sync/Ricing/.zshrc-private.zsh if that file is sourced.
# Optional browser:   export GL_REDDIT_BROWSER=firefox
# Reddit video quality: gldl defaults to the 2nd-best video; use -1 for best.
# gl-saved, gl-redditor, and gl-subreddit default to best. Use -2, -3, or -4
# with any command to request that ranked video stream (plus audio, if present).
# Ranks are per post, so a given flag does not guarantee a fixed size or resolution.
# Repeated Reddit runs skip files already present at the same path; check the
# temporary report path printed after each run for errors or missing posts.
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

# gallery-dl imports yt-dlp as a Python module, not through its CLI command.
# Find it in system Python or in the environment behind the yt-dlp executable.
_gl_ytdl_module() {
  emulate -L zsh
  local module executable interpreter
  module="$(command python3 -c 'import yt_dlp; print(yt_dlp.__path__[0])' 2>/dev/null)" || module=''
  if [[ -z "$module" ]]; then
    executable="$(command -v yt-dlp 2>/dev/null)" || executable=''
    if [[ -n "$executable" ]]; then
      executable="${executable:A}"
      interpreter="${executable:h}/python"
      if [[ -x "$interpreter" ]]; then
        module="$(command "$interpreter" -c 'import yt_dlp; print(yt_dlp.__path__[0])' 2>/dev/null)" || module=''
      fi
    fi
  fi
  print -r -- "${module:-yt_dlp}"
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
    if [[ -f "$log" ]] && grep -qi 'No results for' "$log"; then
      problem=1
      if [[ "$saved" == yes ]]; then
        print -u2 -r -- "gl-saved: no saved posts were returned. Verify your Reddit username and browser login/cookies. See $log"
      else
        print -u2 -r -- "gallery-dl returned no results for at least one input. See $log"
      fi
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
# VIDEO_RANK is 1 (best, gallery-dl default) or 2-4 (yt-dlp-ranked video-only stream).
_gl_reddit_run() {
  emulate -L zsh
  local out="$1" layout="$2" report="$3" video_rank="$4"
  shift 4
  case "$video_rank" in
    1|2|3|4) ;;
    *) print -u2 -r -- "Internal error: unknown video rank '$video_rank'"; return 2 ;;
  esac
  local -a destination
  case "$layout" in
    flat)      destination=(-D "$out") ;;
    subreddit) destination=(--destination "$out" -o 'extractor.reddit.directory=["{subreddit}"]') ;;
    author)    destination=(--destination "$out" -o 'extractor.reddit.directory=["{author}"]') ;;
    *) print -u2 -r -- "Internal error: unknown layout '$layout'"; return 2 ;;
  esac

  # Save text bodies, including captions on media posts; ignore link-only bodies.
  local text_processor='[{"name":"metadata","event":"post","mode":"custom","filename":"{title[:100]}_{id}_{author}.txt","skip":true,"filter":"bool(re.search(r\"\\w\", re.sub(r\"\\[[^]]*\\]\\(https?://[^)]+\\)|https?://\\S+\", \"\", (selftext or \"\")))) and (selftext or \"\").strip().lower() not in (\"[deleted]\", \"[removed]\")","content-format":"{title}\n\n{selftext}\n\nhttps://www.reddit.com{permalink}\n"}]'

  local ytdl_module
  ytdl_module="$(_gl_ytdl_module)"
  local -a video_options
  if (( video_rank > 1 )); then
    # Prefer the requested video-only rank with the best audio. If unavailable,
    # fall back through better video ranks, then allow video-only/combined files.
    local -a formats
    local integer level
    for (( level=video_rank; level>=2; level-- )); do formats+=("bv.$level+ba"); done
    formats+=(bv+ba)
    for (( level=video_rank; level>=2; level-- )); do formats+=("bv.$level"); done
    formats+=(bv b)
    video_options=(-o "downloader.ytdl.format=${(j:/:)formats}")
  fi

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
    -o "downloader.ytdl.module=$ytdl_module" \
    "${video_options[@]}" \
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
    print -r -- 'Usage: gldl [-1|-2|-3|-4] URL|REDDIT_POST_ID [URL ...]'
    print -r -- 'Reddit videos default to the 2nd-best video. -1 selects best; -3/-4 select lower ranks.'
    print -r -- 'The displayed video rank is a preference; a missing rank falls back to a better one.'
    print -r -- 'Download to the current directory. Reddit links use browser cookies.'
    print -r -- 'Examples: gldl abc123    gldl -1 abc123    gldl -4 "https://www.reddit.com/r/linux/comments/abc123/"'
    return 0
  fi
  local src video_rank=2 video_flag=''
  local -a inputs
  for src in "$@"; do
    case "$src" in
      -1|-2|-3|-4)
        [[ -z "$video_flag" ]] || { _gl_error gldl 'choose only one video quality flag'; return 2; }
        video_flag="$src"
        video_rank="${src#-}" ;;
      -*) _gl_error gldl "unknown option: $src"; return 2 ;;
      *) inputs+=("$src") ;;
    esac
  done
  (( ${#inputs[@]} )) || { _gl_error gldl 'provide at least one URL or Reddit post ID'; return 2; }
  _gl_check_program gldl || return $?

  local rc=0 err=0
  local -a reddit other
  for src in "${inputs[@]}"; do
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
    local video_label
    case "$video_rank" in
      1) video_label='best' ;;
      2) video_label='2nd-best' ;;
      3) video_label='3rd-best' ;;
      4) video_label='4th-best' ;;
    esac
    print -r -- "gldl: Reddit video preference: $video_label (rank $video_rank; falls back if unavailable)."
    _gl_reddit_run "$PWD" flat "$report" "$video_rank" "${reddit[@]}" || rc=$?
    _gl_reddit_report "$report" "$rc" no || err=1
  elif [[ -n "$video_flag" ]]; then
    _gl_error gldl 'video quality flags apply only to Reddit posts'
    return 2
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

# Download recent saved posts into ~/Downloads/GLDL/reddit_posts_saved_new/{subreddit}/.
gl-saved() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gl-saved [LIMIT] [REDDIT_USERNAME] [-2|-3|-4]'
    print -r -- 'Download newest saved entries, grouped by subreddit. Best video is the default.'
    print -r -- 'Examples: gl-saved 20    gl-saved 50 MyUsername -2'
    print -r -- 'Username: argument overrides GL_REDDIT_USER; if neither is set, prompt asks in a terminal.'
    print -r -- 'Set a usual GL_REDDIT_USER in ~/Sync/Ricing/.zshrc-private.zsh if that file is sourced.'
    print -r -- 'Error reports are stored temporarily under /tmp (or $TMPDIR).'
    return 0
  fi

  local limit='' username="${GL_REDDIT_USER:-}" video_rank=1 arg
  local -a inputs
  for arg in "$@"; do
    case "$arg" in
      -2|-3|-4)
        (( video_rank == 1 )) || { _gl_error gl-saved 'choose only one video quality flag'; return 2; }
        video_rank="${arg#-}" ;;
      -h|--help) gl-saved --help; return 0 ;;
      -*) _gl_error gl-saved "unknown option: $arg"; return 2 ;;
      *) inputs+=("$arg") ;;
    esac
  done
  set -- "${inputs[@]}"
  if _gl_integer "${1:-}"; then
    _gl_positive_integer "$1" || { _gl_error gl-saved 'LIMIT must be positive'; return 2; }
    limit="$1"; shift
  fi
  (( $# <= 1 )) || { _gl_error gl-saved 'too many arguments'; return 2; }
  (( $# == 1 )) && username="${1#u/}"
  if [[ -z "$username" ]]; then
    if [[ -t 0 ]]; then
      read -r "username?gl-saved: Reddit username: " || return 2
    fi
    [[ -n "$username" ]] || {
      _gl_error gl-saved 'Reddit username is missing; pass it, set GL_REDDIT_USER, or run interactively'
      return 2
    }
  fi
  [[ "$username" != *[^[:alnum:]_-]* ]] || { _gl_error gl-saved 'invalid Reddit username'; return 2; }
  _gl_check_program gl-saved reddit || return $?

  local out="$HOME/Downloads/GLDL/reddit_posts_saved_new" report rc=0
  local -a opts
  [[ -n "$limit" ]] && opts+=(--post-range "1-$limit")
  report="$(_gl_reddit_start gl-saved)" || { print -u2 -r -- 'gl-saved: cannot create temporary report directory.'; return 1; }
  print -r -- "Saving posts to $out"
  _gl_reddit_run "$out" subreddit "$report" "$video_rank" "${opts[@]}" "https://www.reddit.com/user/$username/saved/" || rc=$?
  _gl_reddit_report "$report" "$rc" yes
}

# Download submissions into ~/Downloads/GLDL/redditors/{author}/.
gl-redditor() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gl-redditor [LIMIT] [--new|--top] [--time PERIOD] [-2|-3|-4] USER [...]'
    print -r -- 'Default: newest submissions, no limit, best video.'
    print -r -- 'PERIOD: all, year, month, week, day, hour (with --top).'
    print -r -- 'Examples: gl-redditor 100 SomeUser'
    print -r -- '          gl-redditor 200 --top --time month -2 User1 User2'
    return 0
  fi
  local limit='' sort=new period=all video_rank=1
  local -a users urls opts
  if [[ "${1:-}" == -[234] ]]; then
    video_rank="${1#-}"; shift
  fi
  if _gl_integer "${1:-}"; then
    _gl_positive_integer "$1" || { _gl_error gl-redditor 'LIMIT must be positive'; return 2; }
    limit="$1"; shift
  fi
  while (( $# )); do
    case "$1" in
      -2|-3|-4)
        (( video_rank == 1 )) || { _gl_error gl-redditor 'choose only one video quality flag'; return 2; }
        video_rank="${1#-}"; shift ;;
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

  local user out="$HOME/Downloads/GLDL/redditors" report rc=0
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
  _gl_reddit_run "$out" author "$report" "$video_rank" "${opts[@]}" "${urls[@]}" || rc=$?
  _gl_reddit_report "$report" "$rc" no
}

# Download subreddit posts into ~/Downloads/GLDL/subreddits/{subreddit}/.
gl-subreddit() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gl-subreddit [LIMIT] [--top|--new] [--time PERIOD] [--score N] [-2|-3|-4] SUB [...]'
    print -r -- 'Default: top posts from the last year, minimum score 7000, best video.'
    print -r -- '--new downloads newest posts without a score threshold.'
    print -r -- 'Examples: gl-subreddit 100 linux'
    print -r -- '          gl-subreddit 50 --new linux fedora'
    print -r -- '          gl-subreddit 200 --top --time month --score 1000 -2 linux'
    return 0
  fi
  local limit='' sort=top period=year min_score='' time_explicit=0 score_explicit=0 video_rank=1
  local -a subs urls opts
  if [[ "${1:-}" == -[234] ]]; then
    video_rank="${1#-}"; shift
  fi
  if _gl_integer "${1:-}"; then
    _gl_positive_integer "$1" || { _gl_error gl-subreddit 'LIMIT must be positive'; return 2; }
    limit="$1"; shift
  fi
  while (( $# )); do
    case "$1" in
      -2|-3|-4)
        (( video_rank == 1 )) || { _gl_error gl-subreddit 'choose only one video quality flag'; return 2; }
        video_rank="${1#-}"; shift ;;
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

  local sub out="$HOME/Downloads/GLDL/subreddits" report rc=0
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
  _gl_reddit_run "$out" subreddit "$report" "$video_rank" "${opts[@]}" "${urls[@]}" || rc=$?
  _gl_reddit_report "$report" "$rc" no
}
