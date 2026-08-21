# Video download helpers:
#   yts     - smallest files
#   ytq     - recommended backup mode; small files with quality trade-offs
#   ytc     - ytq with Firefox cookies
#   yt-dlp  - full quality
#
# ytq targets up to YTQ_RES and may spend up to YTQ_MARGIN
# percent extra space when it buys a meaningful quality improvement.
ytq() {
    local cap=${YTQ_RES:-720}
    local margin=${YTQ_MARGIN:-15}
    local info selector rc

    info=$(mktemp) || return 1

    command yt-dlp \
        --no-playlist \
        --skip-download \
        -J \
        "$@" >"$info" || {
            rc=$?
            rm -f "$info"
            return "$rc"
        }

    selector=$(python3 - "$info" "$cap" "$margin" <<'PY'
import json
import math
import sys

path, cap_s, margin_s = sys.argv[1:]
cap = int(cap_s)
margin = float(margin_s)

with open(path, encoding="utf-8") as fh:
    info = json.load(fh)

formats = info.get("formats") or []
duration = info.get("duration") or 0


def number(x):
    try:
        x = float(x)
        return x if math.isfinite(x) and x > 0 else None
    except (TypeError, ValueError):
        return None


def has_video(f):
    return (f.get("vcodec") or "none").lower() != "none"


def has_audio(f):
    return (f.get("acodec") or "none").lower() != "none"


def stream_res(f):
    """Use the smaller dimension, like yt-dlp's 'res' sort field."""
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

    # Last resort.
    return number(f.get("filesize_approx"))


def fmt_size(n):
    if not n:
        return "unknown size"
    return f"{n / 1024 / 1024:.1f} MiB"


def codec_rank(v):
    """
    Broad compression-efficiency preference.

    Do not distinguish VP9 profile 2 merely because it is profile 2;
    that is commonly associated with 10-bit/HDR and is not automatically
    a reason to spend more space.
    """
    v = (v or "").lower()

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

    This deliberately treats 24/25/30 fps as one general tier instead
    of spending storage just to turn 29.97 into 30 or 25 into 30.
    """
    fps = number(f.get("fps")) or 0
    return 1 if fps >= 45 else 0


# Prefer proper video-only streams.
videos = [
    f for f in formats
    if has_video(f) and not has_audio(f)
]

combined = False

# Fallback for sites exposing only combined formats.
if not videos:
    videos = [
        f for f in formats
        if has_video(f) and has_audio(f)
    ]
    combined = True

if not videos:
    raise SystemExit("ytq: no usable video format found")


# Pick the highest resolution <= cap.
# If nothing exists below it, use the lowest available resolution above it.
known_res = [
    (f, stream_res(f))
    for f in videos
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

    videos = [
        f for f, r in known_res
        if r == target
    ]
else:
    target = None


# Establish the smallest stream as our storage baseline.
sized = [
    (f, est_size(f))
    for f in videos
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


# Crucial difference from the old version:
#
# We spend extra space only for a meaningful FPS tier or a substantially
# more efficient codec. We DO NOT maximize bitrate after entering the pool.
#
# If those things are equal, the smaller stream wins.
def video_rank(item):
    f, size = item

    br = (
        number(f.get("vbr"))
        or number(f.get("tbr"))
        or float("inf")
    )

    return (
        fps_tier(f),
        codec_rank(f.get("vcodec")),
        -(size if size is not None else float("inf")),
        -br,
    )


video, video_size = max(pool, key=video_rank)
video_id = str(video["format_id"])

print(
    f"ytq: video "
    f"{stream_res(video) or '?'}p, "
    f"{video.get('vcodec')}, "
    f"{video.get('fps') or '?'} fps, "
    f"{fmt_size(video_size)}"
    + (
        f" | smallest {fmt_size(baseline)}, "
        f"limit +{margin:g}%"
        if baseline else ""
    ),
    file=sys.stderr,
)


if combined:
    print(video_id)
    raise SystemExit


audios = [
    f for f in formats
    if has_audio(f) and not has_video(f)
]

if not audios:
    print(video_id)
    raise SystemExit


# Respect yt-dlp's preferred/original audio language.
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


def abr(f):
    return (
        number(f.get("abr"))
        or number(f.get("tbr"))
        or 0
    )


# Don't destroy audio quality just to save a few MiB.
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
            (f.get("acodec") or "")
            .lower()
            .startswith("opus")
        )

        return (
            1 if opus else 0,
            -(size if size is not None else float("inf")),
            -abr(f),
        )

    audio, audio_size = max(
        audio_pool,
        key=audio_rank,
    )

else:
    # If everything is below 96 kbps, take the best audio the site has.
    audio = max(audios, key=abr)
    audio_size = est_size(audio)


print(
    f"ytq: audio "
    f"{audio.get('acodec')}, "
    f"~{abr(audio):g} kbps, "
    f"{fmt_size(audio_size)}",
    file=sys.stderr,
)

print(f"{video_id}+{audio['format_id']}")
PY
    )

    rc=$?
    rm -f "$info"

    [ "$rc" -eq 0 ] || return "$rc"

    command yt-dlp \
        --no-playlist \
        -f "$selector" \
        "$@"
}
