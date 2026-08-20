# Download videos with a small-file bias: use the smallest stream as a baseline,
# but allow up to YTQ_MARGIN extra size for better FPS, codec efficiency, or bitrate.
ytq() {
    local cap=${YTQ_HEIGHT:-720}
    local margin=${YTQ_MARGIN:-20}
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

NONE = (None, "none")


def number(x):
    try:
        x = float(x)
        return x if math.isfinite(x) and x > 0 else None
    except (TypeError, ValueError):
        return None


def est_size(f):
    # Best case: yt-dlp already knows the exact or approximate size.
    for key in ("filesize", "filesize_approx"):
        n = number(f.get(key))
        if n:
            return n

    # Otherwise estimate from bitrate and duration.
    br = (
        number(f.get("tbr"))
        or number(f.get("vbr"))
        or number(f.get("abr"))
    )

    if br and duration:
        return br * 1000 * duration / 8

    return None


def codec_rank(v):
    v = (v or "").lower()

    if v.startswith("av01") or "av1" in v:
        return 50
    if v.startswith("vp09.02") or v.startswith("vp9.2"):
        return 45
    if v.startswith("vp09") or v.startswith("vp9"):
        return 40
    if v.startswith(("hev1", "hvc1", "hevc", "h265")):
        return 35
    if v.startswith(("avc1", "h264")):
        return 30
    if v.startswith("vp8"):
        return 20

    return 10


def fmt_size(n):
    if not n:
        return "unknown size"
    return f"{n / 1024 / 1024:.1f} MiB"


# Prefer proper video-only streams so audio can be selected independently.
videos = [
    f for f in formats
    if f.get("vcodec") not in NONE
    and f.get("acodec") in NONE
]

combined = False

# Some sites only expose combined audio/video formats.
if not videos:
    videos = [
        f for f in formats
        if f.get("vcodec") not in NONE
        and f.get("acodec") not in NONE
    ]
    combined = True

if not videos:
    raise SystemExit("ytq: no usable video format found")


# Same soft height cap as your old height:720 setup:
# use the highest height <= cap.
# If nothing exists below it, use the lowest available height above it.
known = []

for f in videos:
    h = number(f.get("height"))
    if h:
        known.append((f, int(h)))

if known:
    below = [h for _, h in known if h <= cap]

    if below:
        target = max(below)
    else:
        target = min(h for _, h in known)

    videos = [
        f for f, h in known
        if h == target
    ]
else:
    target = None


# Find the smallest stream at that resolution.
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
    pool = [(f, None) for f in videos]


# Everything in pool is already within 15% of the smallest stream.
#
# Among those, spend the allowed extra space where it is likely
# to make a visible difference:
#
#   1. higher frame rate
#   2. more efficient/newer codec
#   3. higher bitrate within otherwise similar streams
#   4. smaller file as final tie-breaker
def video_quality(item):
    f, size = item

    return (
        number(f.get("fps")) or 0,
        codec_rank(f.get("vcodec")),
        number(f.get("vbr")) or number(f.get("tbr")) or 0,
        -(size or 0),
    )


video, video_size = max(pool, key=video_quality)

video_id = str(video["format_id"])

print(
    f"ytq: video "
    f"{video.get('height') or '?'}p, "
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


# If there are no separate video/audio streams, use the combined format.
if combined:
    print(video_id)
    raise SystemExit


audios = [
    f for f in formats
    if f.get("vcodec") in NONE
    and f.get("acodec") not in NONE
]

if not audios:
    print(video_id)
    raise SystemExit


# Respect yt-dlp's preferred/original language where that information exists.
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


def abr(f):
    return (
        number(f.get("abr"))
        or number(f.get("tbr"))
        or 0
    )


# Prefer normal audio over DRC variants when both exist.
normal_audio = [
    f for f in audios
    if "drc" not in str(f.get("format_id") or "").lower()
    and "drc" not in str(f.get("format_note") or "").lower()
]

if normal_audio:
    audios = normal_audio


# Don't save a tiny amount of space by wrecking audio quality.
# On YouTube this generally avoids the very low bitrate audio formats.
good = [
    f for f in audios
    if abr(f) >= 96
]

if good:
    audios = good

    # Opus is normally a very good quality/size choice.
    opus = [
        f for f in audios
        if (f.get("acodec") or "").lower().startswith("opus")
    ]

    if opus:
        audios = opus

    audio = min(
        audios,
        key=lambda f: (
            est_size(f) or float("inf"),
            abr(f) or float("inf"),
        ),
    )

else:
    # If every available stream is low bitrate, take the best of them.
    audio = max(audios, key=abr)


audio_id = str(audio["format_id"])

print(
    f"ytq: audio "
    f"{audio.get('acodec')}, "
    f"~{abr(audio):g} kbps, "
    f"{fmt_size(est_size(audio))}",
    file=sys.stderr,
)

print(f"{video_id}+{audio_id}")
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
