# To show existing file differences between two folders
missingfiles() {
  if [ "$#" -ne 2 ]; then
    echo "Usage: missingfiles <dir1> <dir2>"
    return 1
  fi

  local dir1="${1%/}"
  local dir2="${2%/}"

  if [ ! -d "$dir1" ]; then
    echo "Not a directory: $dir1"
    return 1
  fi

  if [ ! -d "$dir2" ]; then
    echo "Not a directory: $dir2"
    return 1
  fi

  local out1 out2
  out1=$(rsync -ani --ignore-existing --out-format='%n' "$dir1/" "$dir2/" | grep -vx './' | grep -v '/$' || true)
  out2=$(rsync -ani --ignore-existing --out-format='%n' "$dir2/" "$dir1/" | grep -vx './' | grep -v '/$' || true)

  echo "Present in $dir1 but missing in $dir2:"
  [ -n "$out1" ] && printf '%s\n' "$out1" || echo "(none)"

  echo
  echo "Present in $dir2 but missing in $dir1:"
  [ -n "$out2" ] && printf '%s\n' "$out2" || echo "(none)"
}

# # To count all files in a folder and its subfolders
# Usage:
#   filec              Count all regular files in the current directory and its subfolders
#   filec <directory>  Count all regular files in the specified directory and its subfolders
filec() {
  if [ "$#" -gt 1 ]; then
    echo "Usage: filec [directory]"
    return 1
  fi

  local dir="${1:-.}"

  if [ ! -d "$dir" ]; then
    echo "Not a directory: $dir"
    return 1
  fi

  find "$dir" -type f -printf '.' | wc -c
}

# lfiles [N] — recursively list the N largest files under the current directory
# (default: 20), sorted largest first
lfiles() {
    local n=${1:-20}
    local rec bytes filepath

    find . -type f -printf '%s\t%p\0' 2>/dev/null |
        sort -z -nr -k1,1 |
        head -z -n "$n" |
        while IFS= read -r -d '' rec; do
            bytes=${rec%%$'\t'*}
            filepath=${rec#*$'\t'}
            printf '%9s  %s\n' \
                "$(numfmt --to=iec-i --suffix=B "$bytes")" \
                "$filepath"
        done
}
