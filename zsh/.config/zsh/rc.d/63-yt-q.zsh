ytq() {
    local cap=${YTQ_RES:-720}
    local margin=${YTQ_MARGIN:-15}
    local info selector rc

    info=$(mktemp) || return 1

    # Extract metadata for one media item.
    #
    # --playlist-items 1 matters for sites that internally expose a single
    # post as a playlist/collection (Reddit can do this).
    command yt-dlp \
        --no-playlist \
        --playlist-items 1 \
        --skip-download \
        -J \
        "$@" >"$info"

    rc=$?

    if (( rc != 0 )); then
        rm -f -- "$info"
        return "$rc"
    fi

    selector=$(python3 - "$info" "$cap" "$margin" <<'PY'
import json
import math
import sys

path, cap_s, margin_s = sys.argv[1:]
cap = int(cap_s)
margin = float(margin_s)


def fail(message):
    print(f"ytq: {message}", file=sys.stderr)
    raise SystemExit(1)


with open(path, encoding="utf-8") as fh:
    root = json.load(fh)


def find_media_info(obj):
    """
    Find the first actual media object containing formats.

    yt-dlp -J returns a whole playlist object for playlist-like URLs.
    Some sites, including Reddit, may internally represent a post this way
    even when the user thinks of it as one piece of media.
    """
    if not isinstance(obj, dict):
        return None

    formats = obj.get("formats")
    if isinstance(formats, list) and formats:
        return obj

    entries = obj.get("entries") or []

    for entry in entries:
        found = find_media_info(entry)
        if found is not None:
            return found

    return None


info = find_media_info(root)

if info is None:
    fail("no media entry with usable format information found")


formats = [
    f for f in (info.get("formats") or [])
    if isinstance(f, dict)
    and f.get("format_id") is not None
    and not f.get("has_drm")
]

duration = info.get("duration") or 0


def number(x):
    try:
        x = float(x)
        return x if math.isfinite(x) and x > 0 else None
    except (TypeError, ValueError):
        return None


def has_video(f):
    codec = str(f.get("vcodec") or "none").lower()

    # "images" is used for things such as storyboards and is not an
    # ordinary playable video stream.
    return codec not in ("none", "images")


def has_audio(f):
    codec = str(f.get("acodec") or "none").lower()
    return codec != "none"


def stream_res(f):
    """
    Use the smaller dimension, like yt-dlp's 'res' sort field.

    This also behaves sensibly for portrait video:
    1080x1920 -> 1080p.
    """
    w = number(f.get("width"))
    h = number(f.get("height"))

    if w and h:
        return int(min(w, h))
    if h:
        return int(h)
    if w:
        return int(w)

    return None


def est_size(f):
    # Prefer a real Content-Length/filesize when available.
    exact = number(f.get("filesize"))
    if exact:
        return exact

    # Otherwise estimate from the appropriate bitrate.
    if has_video(f) and not has_audio(f):
        br = number(f.get("vbr")) or number(f.get("tbr"))
    elif has_audio(f) and not has_video(f):
        br = number(f.get("abr")) or number(f.get("tbr"))
    else:
        br = (
            number(f.get("tbr"))
            or number(f.get("vbr"))
            or number(f.get("abr"))
        )

    if br and duration:
        return br * 1000 * duration / 8

    return number(f.get("filesize_approx"))


def fmt_size(n):
    if not n:
        return "unknown size"
    return f"{n / 1024 / 1024:.1f} MiB"


def codec_rank(v):
    """
    Broad compression-efficiency preference.

    VP9 profile 2 is not treated specially merely for being profile 2;
    it is commonly associated with 10-bit/HDR and does not automatically
    justify spending more storage.
    """
    v = str(v or "").lower()

    if v.startswith("av01") or "av1" in v:
        return 4

    if v.startswith(
        ("vp09", "vp9", "hev1", "hvc1", "hevc", "h265")
    ):
        return 3

    if v.startswith(("avc1", "h264")):
        return 2

    if v.startswith("vp8"):
        return 1

    return 0


def fps_tier(f):
    """
    Only pay extra for a frame-rate increase likely to be obvious.

    24/25/30 fps are treated as one general tier.
    """
    fps = number(f.get("fps")) or 0
    return 1 if fps >= 45 else 0


def choose_video(candidates):
    """
    Pick a video from one family of formats.

    candidates must either all be video-only or all be combined A/V.
    """

    if not candidates:
        return None, None

    # Highest resolution <= cap.
    # If nothing exists at/below the cap, use the lowest resolution above it.
    known_res = [
        (f, stream_res(f))
        for f in candidates
    ]

    known_res = [
        (f, r)
        for f, r in known_res
        if r
    ]

    if known_res:
        below = [
            r for _, r in known_res
            if r <= cap
        ]

        if below:
            target = max(below)
        else:
            target = min(r for _, r in known_res)

        candidates = [
            f for f, r in known_res
            if r == target
        ]

    # Establish the smallest stream as the storage baseline.
    sized = [
        (f, est_size(f))
        for f in candidates
    ]

    known_sizes = [
        (f, size)
        for f, size in sized
        if size
    ]

    if known_sizes:
        baseline = min(size for _, size in known_sizes)
        limit = baseline * (1 + margin / 100)

        pool = [
            (f, size)
            for f, size in known_sizes
            if size <= limit
        ]
    else:
        baseline = None
        pool = sized

    if not pool:
        return None, None

    def video_rank(item):
        f, size = item

        br = (
            number(f.get("vbr"))
            or number(f.get("tbr"))
            or float("inf")
        )

        # Spend storage only for meaningful FPS/codec advantages.
        # If those are equal, prefer the smaller stream.
        return (
            fps_tier(f),
            codec_rank(f.get("vcodec")),
            -(size if size is not None else float("inf")),
            -br,
        )

    chosen, chosen_size = max(pool, key=video_rank)
    return chosen, (chosen_size, baseline)


def abr(f):
    return (
        number(f.get("abr"))
        or number(f.get("tbr"))
        or 0
    )


def choose_audio(candidates):
    if not candidates:
        return None, None

    audios = list(candidates)

    # Respect yt-dlp's preferred/original audio language when supplied.
    numeric_lang = [
        (f, f.get("language_preference"))
        for f in audios
        if isinstance(f.get("language_preference"), (int, float))
    ]

    if numeric_lang:
        best_lang = max(value for _, value in numeric_lang)

        audios = [
            f for f, value in numeric_lang
            if value == best_lang
        ]

    # Prefer normal audio over DRC variants.
    normal_audio = [
        f for f in audios
        if "drc" not in str(f.get("format_id") or "").lower()
        and "drc" not in str(f.get("format_note") or "").lower()
    ]

    if normal_audio:
        audios = normal_audio

    # Don't sacrifice too much audio quality just to save a few MiB.
    good = [
        f for f in audios
        if abr(f) >= 96
    ]

    if good:
        sized_audio = [
            (f, est_size(f))
            for f in good
        ]

        known_audio = [
            (f, size)
            for f, size in sized_audio
            if size
        ]

        if known_audio:
            audio_baseline = min(
                size for _, size in known_audio
            )

            # Allow Opus to cost a little more, but not arbitrarily more.
            audio_pool = [
                (f, size)
                for f, size in known_audio
                if size <= audio_baseline * 1.10
            ]
        else:
            audio_pool = sized_audio

        def audio_rank(item):
            f, size = item

            opus = (
                str(f.get("acodec") or "")
                .lower()
                .startswith("opus")
            )

            return (
                1 if opus else 0,
                -(size if size is not None else float("inf")),
                -abr(f),
            )

        return max(audio_pool, key=audio_rank)

    # If everything is below 96 kbps, use the best audio available.
    audio = max(audios, key=abr)
    return audio, est_size(audio)


video_only = [
    f for f in formats
    if has_video(f) and not has_audio(f)
]

combined = [
    f for f in formats
    if has_video(f) and has_audio(f)
]

audios = [
    f for f in formats
    if has_audio(f) and not has_video(f)
]


# Preferred case: separate video + separate audio.
#
# Only use this path when BOTH types actually exist.
if video_only and audios:
    video, video_info = choose_video(video_only)

    if video is None:
        fail("could not choose a usable video stream")

    video_size, baseline = video_info

    audio, audio_size = choose_audio(audios)

    if audio is None:
        fail("could not choose a usable audio stream")

    print(
        f"ytq: video "
        f"{stream_res(video) or '?'}p, "
        f"{video.get('vcodec') or '?'}, "
        f"{video.get('fps') or '?'} fps, "
        f"{fmt_size(video_size)}"
        + (
            f" | smallest {fmt_size(baseline)}, "
            f"limit +{margin:g}%"
            if baseline else ""
        ),
        file=sys.stderr,
    )

    print(
        f"ytq: audio "
        f"{audio.get('acodec') or '?'}, "
        f"~{abr(audio):g} kbps, "
        f"{fmt_size(audio_size)}",
        file=sys.stderr,
    )

    print(
        f"{video['format_id']}+{audio['format_id']}"
    )

    raise SystemExit


# Important fallback:
#
# Some sites expose a video-only stream but do NOT expose a usable
# separate audio stream. The old ytq selected that video-only stream and
# produced a silent download.
#
# If a combined A/V format exists, use that instead.
if combined:
    video, video_info = choose_video(combined)

    if video is None:
        fail("could not choose a usable combined video/audio stream")

    video_size, baseline = video_info

    print(
        f"ytq: combined "
        f"{stream_res(video) or '?'}p, "
        f"{video.get('vcodec') or '?'}, "
        f"{video.get('acodec') or '?'}, "
        f"{video.get('fps') or '?'} fps, "
        f"{fmt_size(video_size)}"
        + (
            f" | smallest {fmt_size(baseline)}, "
            f"limit +{margin:g}%"
            if baseline else ""
        ),
        file=sys.stderr,
    )

    print(video["format_id"])
    raise SystemExit


# Last resort: a genuinely video-only source.
if video_only:
    video, video_info = choose_video(video_only)

    if video is not None:
        video_size, baseline = video_info

        print(
            "ytq: warning: site exposes video but no usable audio "
            "or combined A/V format",
            file=sys.stderr,
        )

        print(
            f"ytq: video "
            f"{stream_res(video) or '?'}p, "
            f"{video.get('vcodec') or '?'}, "
            f"{video.get('fps') or '?'} fps, "
            f"{fmt_size(video_size)}",
            file=sys.stderr,
        )

        print(video["format_id"])
        raise SystemExit


fail("no usable video format found")
PY
    )

    rc=$?
    rm -f -- "$info"

    if (( rc != 0 )); then
        print -u2 "ytq: custom selection failed; falling back to yt-dlp's native selection"

        command yt-dlp \
            --no-playlist \
            --playlist-items 1 \
            -f 'bv*+ba/b' \
            --format-sort-reset \
            -S "res:${cap},+size" \
            "$@"

        return $?
    fi

    command yt-dlp \
        --no-playlist \
        --playlist-items 1 \
        -f "$selector" \
        "$@"
}
