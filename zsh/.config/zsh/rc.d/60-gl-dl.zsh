# gldl URL|POST_ID [...]       Download links into the current folder.
# gl-saved [LIMIT]            Download your newest saved Reddit posts.
#   Output: ~/Downloads/GLDL/reddit_posts_saved_new/{subreddit}/
# gl-redditor [LIMIT] USER [...]   Download users' submissions, newest first.
#   Output: ~/Downloads/GLDL/redditors/{author}/
# gl-subreddit [LIMIT] SUB [...]   Download top posts from the last year (score >= 7000).
#   Output: ~/Downloads/GLDL/subreddits/{subreddit}/; --new selects newest posts instead.
#
# Omit LIMIT for all available posts. Run any command with --help for options/examples.
# Reddit uses Firefox cookies; set GL_REDDIT_BROWSER for another browser/profile.
# gl-saved uses GL_REDDIT_USER from your shell (usually set in
# ~/Sync/Ricing/.zshrc-private.zsh), otherwise it prompts for your username.
# Video: best by default, except gldl uses 2nd-best (-1 selects best).
# -2/-3/-4 prefer lower video ranks; missing ranks fall back to a better one.
# gl-redditor/gl-subreddit keep the oldest identical media collection examined
# this run in each folder, removing repost media and its text sidecar. Galleries
# stay complete: [abc] and [abc, def] both stay. Reports are stored temporarily.

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

  if [[ -s "$report/unsupported-urls.txt" ]]; then
    problem=1
    print -u2 -r -- "Unsupported media (not backed up): $report/unsupported-urls.txt"
    head -n 25 -- "$report/unsupported-urls.txt" >&2
  fi

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
    print -u2 -r -- "The download run failed with status $rc. See $log"
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

# Run gallery-dl and deduplicate complete media collections after a clean run.
# Include external hosts; lock the directory without creating a lock file.
_gl_reddit_backup() {
  emulate -L zsh
  command -v python3 >/dev/null 2>&1 || { print -u2 -r -- 'Reddit media deduplication requires python3.'; return 127; }
  command python3 - "$@" <<'PY'
import collections, fcntl, hashlib, json, math, os, pathlib, re, stat, subprocess, sys

def backup():
    out, report = sys.argv[1:3]
    root = pathlib.Path(out).resolve()
    root.mkdir(parents=True, exist_ok=True)
    report = pathlib.Path(report)
    lock = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache = {}
        def describe(relative, fresh=False):
            path = pathlib.Path(relative)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('media path outside backup directory')
            path = root / path
            if any(p.is_symlink() for p in (path, *path.parents) if p != root and root in p.parents):
                raise ValueError('refusing symlinked media paths')
            info = path.stat()
            if not stat.S_ISREG(info.st_mode):
                raise ValueError('media path is not a regular file')
            stamp = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
            if fresh or relative not in cache or cache[relative][0] != stamp:
                digest = hashlib.sha256()
                with path.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(chunk)
                after = path.stat()
                if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != stamp or not info.st_size:
                    raise ValueError('empty or changing media file; cleanup stopped')
                cache[relative] = (stamp, {'path': relative, 'size': info.st_size, 'sha256': digest.hexdigest()})
            return cache[relative][1]
        def valid(files, fresh=False):
            try:
                return bool(files) and all(describe(f['path'], fresh) == f for f in files)
            except (OSError, ValueError):
                return False
        source = "[m.get(k) for m in [(locals().get('crosspost_parent_list') or [locals()])[-1]] for k in ('url', 'gallery_data')]"
        fields = {'gl_id': '{id}', 'gl_created': '{created_utc}',
                  'gl_folder': '{_path.realdirectory}', 'gl_source': '\fE ' + source}
        inherited = {key: '{_parent[' + key + ']}' for key in fields}
        inherited['gl_sidecar'] = '{_parent[gl_sidecar]}'
        hooks = [
            {'name': 'metadata', 'event': 'post', 'mode': 'modify', 'fields': fields, 'filter': "category == 'reddit'"},
            {'name': 'metadata', 'event': 'post,prepare,child', 'mode': 'modify', 'fields': inherited,
             'filter': "category != 'reddit' and bool(locals().get('_parent'))"},
            {'name': 'metadata', 'event': 'after,skip', 'mode': 'jsonl',
             'directory': str(report), 'filename': 'media.jsonl',
             'include': ['gl_id', 'gl_created', 'gl_folder', 'gl_source', 'gl_sidecar', '_path']},
        ]
        command = sys.argv[3:]
        command += ['-o', 'extractor.postprocessors=' + json.dumps(hooks),
                    '-o', 'extractor.parent-metadata=_parent', '--destination', str(root),
                    '--write-unsupported', str(report / 'unsupported-urls.txt')]
        result = subprocess.run(command)
        log = (report / 'gallery-dl.log').read_text(errors='replace')
        problems = any((report / name).exists() and (report / name).stat().st_size
                       for name in ('failed-posts.txt', 'failed-input-urls.txt', 'unsupported-urls.txt'))
        if result.returncode or problems or re.search(r'\[(?:error|warning)\]', log, re.I):
            print('Media cleanup skipped: downloads reported problems; all files retained.', file=sys.stderr)
            return result.returncode if result.returncode > 0 else 1
        media = report / 'media.jsonl'
        posts = {}
        for line in media.read_text().splitlines() if media.exists() else ():
            row = json.loads(line)
            key = (str(pathlib.Path(row['gl_folder']).relative_to(root)), row['gl_id'])
            post = posts.setdefault(key, {'folder': key[0], 'id': key[1],
                'created': float(row['gl_created']), 'source': row['gl_source'], 'files': {}, 'sidecars': set()})
            relative = str(pathlib.Path(row['_path']).relative_to(root))
            post['files'][relative] = describe(relative)
            if row.get('gl_sidecar'):
                post['sidecars'].add(str(pathlib.Path(row['gl_sidecar']).relative_to(root)))
        for post in posts.values():
            # Compare against the declared gallery size, including unavailable
            # items. Never mistake a partially downloaded gallery for a single.
            src = post['source']
            gallery = src[1]
            expected = len(gallery['items']) if isinstance(gallery, dict) else None
            if (expected is not None and expected != len(post['files'])) or (not gallery and '/gallery/' in (src[0] or '')):
                raise ValueError('incomplete gallery; all downloaded files retained')
            if not math.isfinite(post['created']):
                raise ValueError('invalid Reddit timestamp')
            post['files'] = list(post['files'].values())
        groups = collections.defaultdict(list)
        for post in posts.values():
            signature = (post['folder'], tuple(sorted((f['size'], f['sha256']) for f in post['files'])))
            groups[signature].append(post)
        pending = {}
        retained = set()
        retained_sidecars = set()
        reposts = []
        for group in groups.values():
            group.sort(key=lambda p: (p['created'], p['id']))
            winner = group[0]
            retained.update(file['path'] for file in winner['files'])
            retained_sidecars.update(winner['sidecars'])
            for post in group[1:]:
                reposts.append((post, winner))
                for file in post['files']:
                    pending[file['path']] = {'file': file, 'kept': winner['files']}
        pending = {path: item for path, item in pending.items() if path not in retained}
        # Hashes and the removal plan live only in memory. An interruption can
        # leave extra copies; the oldest complete collection stays untouched.
        removed = 0
        for path, item in list(pending.items()):
            if not (root / path).exists():
                continue
            if not valid(item['kept'], fresh=True) or describe(path, fresh=True) != item['file']:
                raise ValueError('retained media changed; duplicate cleanup stopped')
            (root / path).unlink()
            removed += 1
        # Remove only the exact sidecar recorded by the text writer, after all
        # of the repost's own media is gone. Keep text-only and retained posts.
        removed_sidecars = 0
        for post, winner in reposts:
            if any(file['path'] not in retained and (root / file['path']).exists() for file in post['files']):
                continue
            for path in post['sidecars'] - retained_sidecars - retained:
                if not (root / path).exists():
                    continue
                if not valid(winner['files'], fresh=True):
                    raise ValueError('retained media changed; sidecar cleanup stopped')
                describe(path, fresh=True)
                (root / path).unlink()
                removed_sidecars += 1
        print(f'Media check: removed {removed} duplicate media file(s) and {removed_sidecars} text sidecar(s).')
        return 0
    finally:
        os.close(lock)

try:
    sys.exit(backup())
except (OSError, ValueError, KeyError, TypeError) as exc:
    print(f'Reddit media check failed: {exc}', file=sys.stderr)
    try:
        with (pathlib.Path(sys.argv[2]) / 'gallery-dl.log').open('a') as stream:
            stream.write(f'\n[error] Reddit media check failed: {exc}\n')
    except OSError:
        pass
    sys.exit(1)
except KeyboardInterrupt:
    sys.exit(130)
PY
}

# Internal Reddit downloader. OUT is a folder; LAYOUT is flat, subreddit, or author.
# VIDEO_RANK is 1 (best, gallery-dl default) or 2-4 (yt-dlp-ranked video-only stream).
_gl_reddit_run() {
  emulate -L zsh
  local out="$1" layout="$2" report="$3" video_rank="$4"
  shift 4
  local deduplicate=no
  if [[ "${1:-}" == --deduplicate ]]; then
    deduplicate=yes
    shift
  fi
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
  local text_processor='[{"name":"metadata","event":"post","mode":"custom","filename":"{title[:100]}_{id}_{author}.txt","metadata-path":"gl_sidecar","skip":true,"filter":"bool(re.search(r\"\\w\", re.sub(r\"\\[[^]]*\\]\\(https?://[^)]+\\)|https?://\\S+\", \"\", (selftext or \"\")))) and (selftext or \"\").strip().lower() not in (\"[deleted]\", \"[removed]\")","content-format":"{title}\n\n{selftext}\n\nhttps://www.reddit.com{permalink}\n"}]'

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

  local -a download
  download=(gallery-dl --config-ignore \
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
    "${destination[@]}" "$@")
  if [[ "$deduplicate" == yes ]]; then
    _gl_reddit_backup "$out" "$report" "${download[@]}"
  else
    command "${download[@]}"
  fi
}

# Download any supported link into the current directory, like burl for Reddit.
gldl() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gldl [-1|-2|-3|-4] URL|POST_ID [...]'
    print -r -- 'Download here. Reddit video: 2nd-best by default; -1 selects best.'
    print -r -- 'Examples: gldl abc123    gldl -1 "https://www.reddit.com/r/linux/comments/abc123/"'
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
    print -r -- 'Usage: gl-saved [LIMIT] [-2|-3|-4]'
    print -r -- 'Download newest saved entries, grouped by subreddit. Best video is the default.'
    print -r -- 'Examples: gl-saved 20    gl-saved 50 -2'
    print -r -- 'Username: GL_REDDIT_USER, otherwise a prompt.'
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
  (( $# == 0 )) || { _gl_error gl-saved 'only LIMIT and video flags are accepted; set GL_REDDIT_USER for your account'; return 2; }
  if [[ -z "$username" ]]; then
    if [[ -t 0 ]]; then
      read -r "username?gl-saved: Reddit username: " || return 2
    fi
    [[ -n "$username" ]] || {
      _gl_error gl-saved 'Reddit username is missing; set GL_REDDIT_USER or run interactively'
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
  _gl_reddit_run "$out" author "$report" "$video_rank" --deduplicate "${opts[@]}" "${urls[@]}" || rc=$?
  _gl_reddit_report "$report" "$rc" no
}

# Download subreddit posts into ~/Downloads/GLDL/subreddits/{subreddit}/.
gl-subreddit() {
  emulate -L zsh
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    print -r -- 'Usage: gl-subreddit [LIMIT] [--top|--new] [--time PERIOD] [--score N] [-2|-3|-4] SUB [...]'
    print -r -- 'Default: top posts from the last year, minimum score 7000, best video.'
    print -r -- '--new downloads newest posts without a score threshold.'
    print -r -- 'PERIOD: all, year, month, week, day, hour (with --top).'
    print -r -- 'Examples: gl-subreddit 100 linux'
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
  _gl_reddit_run "$out" subreddit "$report" "$video_rank" --deduplicate "${opts[@]}" "${urls[@]}" || rc=$?
  _gl_reddit_report "$report" "$rc" no
}
