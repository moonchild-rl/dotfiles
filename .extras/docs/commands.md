## Download saved posts with bdfr
bdfr download ~/BDFR/bdfr_posts_new --user me --saved --authenticate --file-scheme {TITLE}_{POSTID}_{REDDITOR} -L 50

## Backup to external
rsync -aivh --delete "/home/moon/path/to/source/" "/run/media/moon/52344F12344EF90D/path/to/destination/"

### inspect first with:
rsync -aivh --delete --dry-run "/home/moon/path/to/source/" "/run/media/moon/52344F12344EF90D/path/to/destination/" | less


## To sanitize file names (change path/to/folder/ and APPLY = False to APPLY = True if it works):

python3 - <<'PY'
from pathlib import Path
import os

root = Path("/path/to/folder/")
APPLY = False

bad_chars = '<>:"/\\|?*'
reserved = {
    "CON","PRN","AUX","NUL",
    *(f"COM{i}" for i in range(1,10)),
    *(f"LPT{i}" for i in range(1,10)),
}

def sanitize(name: str) -> str:
    new = ''.join('_' if (ch in bad_chars or ord(ch) < 32) else ch for ch in name)
    new = new.rstrip(' .')
    if not new:
        new = "_"
    stem, dot, ext = new.partition(".")
    if stem.upper() in reserved:
        stem += "_"
        new = stem + (dot + ext if dot else "")
    return new

for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for name in filenames + dirnames:
        new = sanitize(name)
        if new != name:
            src = Path(dirpath) / name
            dst = Path(dirpath) / new
            if dst.exists():
                print(f"COLLISION: {src} -> {dst}")
                continue
            print(f"RENAME:   {src} -> {dst}")
            if APPLY:
                src.rename(dst)
PY

## For scripts that backup/sanitize file names check the scripts folder
