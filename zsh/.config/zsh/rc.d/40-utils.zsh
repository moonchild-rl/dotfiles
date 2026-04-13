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
  out1=$(rsync -ani --ignore-existing --out-format='%n' "$dir1/" "$dir2/" | grep -vx './')
  out2=$(rsync -ani --ignore-existing --out-format='%n' "$dir2/" "$dir1/" | grep -vx './')

  echo "Present in $dir1 but missing in $dir2:"
  [ -n "$out1" ] && printf '%s\n' "$out1" || echo "(none)"

  echo
  echo "Present in $dir2 but missing in $dir1:"
  [ -n "$out2" ] && printf '%s\n' "$out2" || echo "(none)"
}
