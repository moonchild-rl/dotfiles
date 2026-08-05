# Reddit post backup helpers.
#
# Commands and post types:
#   burl
#       Download the post itself through BDFR.
#       - A text/self post is saved as a .txt file.
#       - An image, gallery, video, or other media post saves its media.
#       Therefore, use burl by itself for a normal text-only post.
#
#   btext
#       Fetch only a post's optional body/selftext and save it as a matching
#       .txt file, without requesting comments. This is mainly for media or
#       link posts that also contain useful body text. It creates nothing when
#       the post has no usable body and never replaces an existing file.
#
# Examples:
#   # Text-only post: burl saves the body as .txt.
#   burl https://www.reddit.com/r/test/comments/abc123/example/
#   burl abc123
#
#   # Media post: burl saves the media.
#   burl https://redd.it/def456
#
#   # Media/link post with additional body text: run both commands.
#   burl https://redd.it/ghi789
#   btext https://redd.it/ghi789
#
#   # Use the alternative BDFR-style name ordering with either command.
#   burl -bn abc123 def456
#   btext --bulk-names abc123 def456
#
# Naming:
#   Default:    {TITLE}_{POSTID}_{REDDITOR}
#   Bulk/BDFR:  {REDDITOR}_{TITLE}_{POSTID}
#
# Options accepted by both commands:
#   -bn, --bulk-names, --bdfr-scheme
#       Use BDFR's {REDDITOR}_{TITLE}_{POSTID} ordering.
#
# Environment:
#   BURL_MAX_WAIT_TIME=300
#       Override BDFR's maximum per-retry wait setting.
#
#   BURL_KEEP_LOG=1
#       Keep burl's private per-run temporary directory.
#
#   BURL_LOG_DIR=/path
#       Override burl's runtime root.
#
#   BTEXT_BDFR_CONFIG=/path/to/config.cfg
#       Override the BDFR config used by btext.
#
#   BTEXT_USER_AGENT='btext/1.0 (personal Reddit backup)'
#       Override btext's PRAW user agent.
#
# Notes:
#   * burl handles text-only posts itself; btext is not required for them.
#   * To reproduce the useful part of the old burl -wt/--with-text behavior
#     for a media/link post, run burl and then btext for the same URL or ID.
#   * btext uses BDFR's Python environment, PRAW configuration, and exact
#     Windows-compatible filename formatter, but it never reads comments.

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

# Convert a bare Reddit post ID into an unambiguous submission URL. This avoids
# BDFR archive/download ambiguity around some seven-character IDs.
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

# Print the Python interpreter used by the bdfr console script. This supports
# pipx installations where the system python3 cannot import bdfr or praw.
_burl_bdfr_python() {
  emulate -L zsh

  local bdfr_path="${commands[bdfr]:-}"
  local shebang
  local interpreter
  local command_name

  [[ -n "$bdfr_path" && -r "$bdfr_path" ]] || return 1

  IFS= read -r shebang < "$bdfr_path" || return 1

  if [[ "$shebang" == '#!'* ]]; then
    interpreter="${shebang#\#!}"

    # The usual pip/pipx console-script shebang is one absolute interpreter.
    if [[ "$interpreter" == /* && "$interpreter" != *' '* && -x "$interpreter" ]]; then
      print -r -- "$interpreter"
      return 0
    fi

    # Also handle the common portable form: #!/usr/bin/env python3
    if [[ "$interpreter" == '/usr/bin/env '* ]]; then
      command_name="${interpreter#/usr/bin/env }"
      command_name="${command_name%% *}"

      if [[ -n "$command_name" && -n "${commands[$command_name]:-}" ]]; then
        print -r -- "${commands[$command_name]}"
        return 0
      fi
    fi
  fi

  if [[ -n "${commands[python3]:-}" ]]; then
    print -r -- "${commands[python3]}"
    return 0
  fi

  return 1
}

burl() {
  emulate -L zsh
  setopt localtraps

  local usage
  usage="usage: burl [-bn|--bulk-names|--bdfr-scheme] <url-or-id> [more-urls-or-ids ...]"

  (( $# )) || {
    print -u2 "$usage"
    return 2
  }

  local file_scheme="{TITLE}_{POSTID}_{REDDITOR}"
  local max_wait="${BURL_MAX_WAIT_TIME:-300}"

  local -a args
  local -a raw_sources
  local item
  local source

  while (( $# )); do
    item="$1"
    shift

    case "$item" in
      --help|-h)
        print -u2 "$usage"
        print -u2 ""
        print -u2 "Downloads the submission's primary content."
        print -u2 "Media posts produce media files; text/self posts produce .txt files."
        print -u2 ""
        print -u2 "Default file scheme:"
        print -u2 "  {TITLE}_{POSTID}_{REDDITOR}"
        print -u2 ""
        print -u2 "Options:"
        print -u2 "  --bulk-names, --bdfr-scheme, -bn"
        print -u2 "    Use {REDDITOR}_{TITLE}_{POSTID}."
        print -u2 ""
        print -u2 "Optional text sidecars:"
        print -u2 "  btext [same naming option] <url-or-id> [...]"
        print -u2 "  Use btext to save body text from media/link posts without comments."
        return 0
        ;;

      --bulk-names|--bdfr-scheme|-bn)
        file_scheme="{REDDITOR}_{TITLE}_{POSTID}"
        ;;

      --with-text|-wt)
        print -u2 "burl: --with-text was split into the separate btext command"
        print -u2 "burl: run burl for media and btext for the .txt sidecar"
        return 2
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

  if [[ -z "${commands[bdfr]:-}" ]]; then
    print -u2 "burl: bdfr not found"
    return 127
  fi

  case "$max_wait" in
    ''|*[!0-9]*)
      print -u2 "burl: BURL_MAX_WAIT_TIME must be a non-negative integer"
      return 2
      ;;
  esac

  for source in "${raw_sources[@]}"; do
    source="$(_burl_normalize_source "$source")" || return 1
    args+=(-l "$source")
  done

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
    print -u2 "burl: temporary directory is not usable: $runtime_root"
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

  # Ctrl+C is supported. Completed files in the current directory are kept;
  # only private logs/temp data are removed by these traps.
  trap 'rm -rf -- "$work_dir"; return 130' INT
  trap 'rm -rf -- "$work_dir"; return 143' TERM
  trap 'rm -rf -- "$work_dir"; return 129' HUP

  if (( ! reboot_safe )); then
    print -u2 "burl: warning: $runtime_root is not guaranteed to be cleared at reboot"
    print -u2 \
      "burl: warning: leave BURL_LOG_DIR unset and configure XDG_RUNTIME_DIR for that guarantee"
  fi

  local failure_re
  local display_re

  failure_re='(\[[^]]*[[:space:]]-[[:space:]]*(ERROR|CRITICAL)\][[:space:]]*-)|(^|[[:space:]\[])(ERROR|CRITICAL)([[:space:]\]:-]|$)|Traceback \(most recent call last\)|Max retries exceeded|Max wait time exceeded'

  display_re="${failure_re}|HTTP Error[[:space:]]+429|429[[:space:]]+Too Many Requests|Too Many Requests|received[[:space:]]+429[[:space:]]+HTTP response|Response code[[:space:]]+429|[Tt]imed out|[Tt]imeout|[Cc]onnection aborted|[Cc]onnection reset"

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
        "burl: some requested post content may not have downloaded" \
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

btext() {
  emulate -L zsh
  setopt localtraps

  local usage
  usage="usage: btext [-bn|--bulk-names|--bdfr-scheme] <url-or-id> [more-urls-or-ids ...]"

  (( $# )) || {
    print -u2 "$usage"
    return 2
  }

  local file_scheme="{TITLE}_{POSTID}_{REDDITOR}"
  local -a raw_sources
  local item

  while (( $# )); do
    item="$1"
    shift

    case "$item" in
      --help|-h)
        print -u2 "$usage"
        print -u2 ""
        print -u2 "Downloads only submission body text; comments are never requested."
        print -u2 "This is mainly a sidecar helper for media/link posts with body text."
        print -u2 "For a text-only post, burl already saves the body as .txt."
        print -u2 ""
        print -u2 "Default file scheme:"
        print -u2 "  {TITLE}_{POSTID}_{REDDITOR}.txt"
        print -u2 ""
        print -u2 "Options:"
        print -u2 "  --bulk-names, --bdfr-scheme, -bn"
        print -u2 "    Use {REDDITOR}_{TITLE}_{POSTID}.txt."
        return 0
        ;;

      --bulk-names|--bdfr-scheme|-bn)
        file_scheme="{REDDITOR}_{TITLE}_{POSTID}"
        ;;

      --)
        raw_sources+=("$@")
        break
        ;;

      -*)
        print -u2 "btext: unknown option: $item"
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

  if [[ -z "${commands[bdfr]:-}" ]]; then
    print -u2 "btext: bdfr not found"
    return 127
  fi

  local bdfr_python
  bdfr_python="$(_burl_bdfr_python)" || {
    print -u2 "btext: could not locate the Python interpreter used by bdfr"
    return 127
  }

  # The Python code uses BDFR's installed PRAW and exact filename formatter.
  # It reads only Submission fields and never touches submission.comments.
  "$bdfr_python" - "$file_scheme" "${raw_sources[@]}" <<'PY'
from __future__ import annotations

import configparser
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

try:
    import appdirs
    import praw
    import prawcore
    from bdfr.file_name_formatter import FileNameFormatter
except Exception as exc:
    print(f"btext: could not import BDFR/PRAW modules: {exc}", file=sys.stderr)
    raise SystemExit(127)


ID_RE = re.compile(r"^[0-9a-z]{5,10}$", re.IGNORECASE)


def extract_post_id(source: str) -> str:
    source = source.strip()
    if ID_RE.fullmatch(source):
        return source.lower()

    parsed = urlparse(source if "://" in source else f"https://{source}")
    host = parsed.netloc.lower().split(":", 1)[0]
    parts = [part for part in parsed.path.split("/") if part]

    if host in {"redd.it", "www.redd.it"} and parts and ID_RE.fullmatch(parts[0]):
        return parts[0].lower()

    for marker in ("comments", "gallery"):
        try:
            index = parts.index(marker)
        except ValueError:
            continue

        if index + 1 < len(parts) and ID_RE.fullmatch(parts[index + 1]):
            return parts[index + 1].lower()

    raise ValueError(f"could not find a Reddit submission ID in: {source}")


def load_bdfr_config() -> tuple[configparser.ConfigParser, Path | None]:
    parser = configparser.ConfigParser()
    override = os.environ.get("BTEXT_BDFR_CONFIG")

    if override:
        path = Path(override).expanduser().resolve()
        if not path.is_file():
            raise FileNotFoundError(f"BTEXT_BDFR_CONFIG does not exist: {path}")
        parser.read(path)
        return parser, path

    config_dir = Path(appdirs.AppDirs("bdfr", "BDFR").user_config_dir)
    candidates = (
        Path.cwd() / "config.cfg",
        Path.cwd() / "default_config.cfg",
        config_dir / "config.cfg",
        config_dir / "default_config.cfg",
    )

    for path in candidates:
        if path.is_file():
            parser.read(path)
            return parser, path

    # Match BDFR's final fallback to the packaged default configuration.
    try:
        from importlib import resources

        text = resources.files("bdfr").joinpath("default_config.cfg").read_text(
            encoding="utf-8"
        )
    except Exception as exc:
        raise FileNotFoundError("could not locate a BDFR configuration") from exc

    parser.read_string(text)
    return parser, None


def make_reddit() -> praw.Reddit:
    parser, config_path = load_bdfr_config()

    client_id = parser.get("DEFAULT", "client_id")
    client_secret = parser.get("DEFAULT", "client_secret")
    user_agent = os.environ.get(
        "BTEXT_USER_AGENT", "btext/1.0 (personal Reddit post text backup)"
    )

    kwargs: dict[str, object] = {
        "client_id": client_id,
        "client_secret": client_secret,
        "user_agent": user_agent,
    }

    # Reuse BDFR's authenticated refresh token when one is already present.
    # Otherwise PRAW uses read-only application OAuth with the same client.
    if config_path is not None and parser.has_option("DEFAULT", "user_token"):
        try:
            from bdfr.oauth2 import OAuth2TokenManager

            kwargs["token_manager"] = OAuth2TokenManager(parser, config_path)
        except Exception as exc:
            print(
                f"btext: warning: could not use BDFR user token; using read-only OAuth: {exc}",
                file=sys.stderr,
            )

    return praw.Reddit(**kwargs)


def usable_body(text: str) -> bool:
    stripped = text.strip()
    return bool(stripped) and stripped.lower() not in {"[removed]", "[deleted]"}


def sidecar_path(
    formatter: FileNameFormatter,
    submission: praw.models.Submission,
    file_scheme: str,
) -> Path:
    # These are the same internal steps BDFR uses for media/archive filenames.
    base_name = formatter._format_name(submission, file_scheme).replace("\n", " ")
    return formatter.limit_file_name_length(base_name, ".txt", Path.cwd())


def write_exclusive(path: Path, text: str) -> bool:
    if path.exists():
        return False

    path.parent.mkdir(parents=True, exist_ok=True)
    payload = text if text.endswith("\n") else text + "\n"

    try:
        with path.open("x", encoding="utf-8", newline="") as handle:
            try:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            except BaseException:
                handle.close()
                path.unlink(missing_ok=True)
                raise
    except FileExistsError:
        return False

    return True


def describe_http_error(exc: BaseException) -> str:
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", None)
    if status is not None:
        return f"HTTP {status}: {exc}"
    return str(exc)


def main() -> int:
    if len(sys.argv) < 3:
        print("btext: internal argument error", file=sys.stderr)
        return 2

    file_scheme = sys.argv[1]
    sources = sys.argv[2:]
    formatter = FileNameFormatter(file_scheme, "", "ISO", "windows")

    try:
        reddit = make_reddit()
    except Exception as exc:
        print(f"btext: could not initialize Reddit/PRAW: {exc}", file=sys.stderr)
        return 1

    failed = False

    for source in sources:
        try:
            post_id = extract_post_id(source)
            submission = reddit.submission(id=post_id)

            # Accessing these fields performs the single submission lookup.
            body = submission.selftext or ""
            title = submission.title  # Ensure the object is fully populated.
            _ = title

            if not usable_body(body):
                print(f"btext: no usable post body: {post_id}", file=sys.stderr)
                continue

            destination = sidecar_path(formatter, submission, file_scheme)

            if write_exclusive(destination, body):
                print(f"btext: wrote post text: {destination.name}", file=sys.stderr)
            else:
                print(
                    f"btext: existing file kept; not replacing: {destination.name}",
                    file=sys.stderr,
                )

        except KeyboardInterrupt:
            raise
        except (prawcore.PrawcoreException, praw.exceptions.PRAWException) as exc:
            print(
                f"btext: Reddit request failed for {source}: {describe_http_error(exc)}",
                file=sys.stderr,
            )
            failed = True
        except Exception as exc:
            print(f"btext: failed for {source}: {exc}", file=sys.stderr)
            failed = True

    return 1 if failed else 0


try:
    raise SystemExit(main())
except KeyboardInterrupt:
    print("\nbtext: interrupted; no partial .txt sidecar was kept", file=sys.stderr)
    raise SystemExit(130)
PY
}
