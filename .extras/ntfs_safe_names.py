#!/usr/bin/env python3

# dry run
# ./ntfs_safe_names.py /path/to/folder

# dry run + save plan
# ./ntfs_safe_names.py /path/to/folder --manifest rename-plan.tsv

# actually rename
# ./ntfs_safe_names.py /path/to/folder --apply

# use a different replacement string
# ./ntfs_safe_names.py /path/to/folder --replacement "_" --apply

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

BAD_CHARS = '<>:"/\\|?*'
RESERVED = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
    # Windows also treats these superscript variants as reserved device names.
    "COM¹",
    "COM²",
    "COM³",
    "LPT¹",
    "LPT²",
    "LPT³",
}


@dataclass(frozen=True)
class RenameOp:
    src: Path
    dst: Path


@dataclass(frozen=True)
class Collision:
    directory: Path
    target_name: str
    source_names: tuple[str, ...]


def sanitize_component(name: str, replacement: str = "_") -> str:
    """
    Sanitize one path component for Windows/NTFS-friendly use.

    Rules handled:
    - replace reserved characters and control chars 0..31
    - strip trailing spaces and periods
    - avoid reserved DOS device names like CON, NUL, COM1, etc.
    - ensure result is not empty
    """
    new = "".join(
        replacement if (ch in BAD_CHARS or ord(ch) < 32) else ch for ch in name
    )

    new = new.rstrip(" .")

    if not new:
        new = replacement

    stem, dot, ext = new.partition(".")
    if stem.upper() in RESERVED:
        stem += replacement
        new = stem + (dot + ext if dot else "")

    return new


def windows_key(name: str) -> str:
    """
    Normalize a name the way this tool uses for collision detection.

    We compare case-insensitively because ordinary Windows usage is
    case-insensitive for file and directory names.
    """
    return name.casefold()


def iter_tree_bottom_up(root: Path) -> Iterable[tuple[Path, list[str], list[str]]]:
    for dirpath, dirnames, filenames in os.walk(root, topdown=False, followlinks=False):
        yield Path(dirpath), dirnames, filenames


def build_plan(root: Path, replacement: str) -> tuple[list[RenameOp], list[Collision]]:
    ops: list[RenameOp] = []
    collisions: list[Collision] = []

    for dirpath, dirnames, filenames in iter_tree_bottom_up(root):
        names = list(dirnames) + list(filenames)

        target_map: dict[str, list[str]] = {}
        for name in names:
            target = sanitize_component(name, replacement)
            key = windows_key(target)
            target_map.setdefault(key, []).append(name)

            if target != name:
                ops.append(RenameOp(src=dirpath / name, dst=dirpath / target))

        for key, src_names in target_map.items():
            distinct = sorted(set(src_names))
            if len(distinct) > 1:
                # All these names would collapse to the same target on NTFS-safe output.
                target_name = sanitize_component(distinct[0], replacement)
                collisions.append(
                    Collision(
                        directory=dirpath,
                        target_name=target_name,
                        source_names=tuple(distinct),
                    )
                )

    # Deepest paths first so children are renamed before parents.
    ops.sort(key=lambda op: (len(op.src.parts), str(op.src)), reverse=True)
    collisions.sort(key=lambda c: str(c.directory))
    return ops, collisions


def validate_replacement(value: str) -> str:
    if not value:
        raise argparse.ArgumentTypeError("replacement must not be empty")
    if any(ch in BAD_CHARS or ord(ch) < 32 for ch in value):
        raise argparse.ArgumentTypeError(
            f"replacement contains an invalid character: {value!r}"
        )
    if value.rstrip(" .") != value:
        raise argparse.ArgumentTypeError(
            "replacement must not end with a space or period"
        )
    return value


def write_manifest(path: Path, ops: list[RenameOp], root: Path) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("old_path\tnew_path\n")
        for op in ops:
            old_rel = op.src.relative_to(root)
            new_rel = op.dst.relative_to(root)
            f.write(f"{old_rel.as_posix()}\t{new_rel.as_posix()}\n")


def print_plan(ops: list[RenameOp], root: Path) -> None:
    if not ops:
        print("No renames needed.")
        return

    print("Planned renames:")
    for op in ops:
        print(f"  {op.src.relative_to(root)}  ->  {op.dst.relative_to(root)}")


def print_collisions(collisions: list[Collision], root: Path) -> None:
    if not collisions:
        return

    print("\nConflicts found. Nothing will be changed.", file=sys.stderr)
    print("These entries would collapse to the same NTFS-safe name:\n", file=sys.stderr)

    for c in collisions:
        rel_dir = c.directory.relative_to(root)
        shown_dir = "." if str(rel_dir) == "." else rel_dir.as_posix()
        print(f"[{shown_dir}] -> {c.target_name!r}", file=sys.stderr)
        for name in c.source_names:
            print(f"    {name}", file=sys.stderr)
        print(file=sys.stderr)


def apply_plan(ops: list[RenameOp]) -> None:
    for op in ops:
        if not op.src.exists():
            raise RuntimeError(f"Source disappeared before rename: {op.src}")

        if op.dst.exists():
            raise RuntimeError(
                f"Destination already exists, refusing to overwrite: {op.dst}"
            )

        op.src.rename(op.dst)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Make filenames under a directory NTFS-safe without overwriting files.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "root",
        help="Root directory whose contents should be checked/renamed",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually perform the renames. Without this flag, the script is dry-run only.",
    )
    parser.add_argument(
        "--replacement",
        default="_",
        type=validate_replacement,
        help="String used to replace invalid characters",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        help="Optional TSV file to write the rename plan to",
    )

    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()

    if not root.exists():
        print(f"Error: path does not exist: {root}", file=sys.stderr)
        return 1
    if not root.is_dir():
        print(f"Error: not a directory: {root}", file=sys.stderr)
        return 1

    ops, collisions = build_plan(root, args.replacement)

    print_plan(ops, root)

    if args.manifest:
        write_manifest(args.manifest, ops, root)
        print(f"\nWrote manifest: {args.manifest}")

    print(f"\nSummary: {len(ops)} rename(s), {len(collisions)} conflict set(s)")

    if collisions:
        print_collisions(collisions, root)
        return 2

    if not args.apply:
        print("\nDry run only. Re-run with --apply to perform the renames.")
        return 0

    if not ops:
        print("\nNothing to do.")
        return 0

    apply_plan(ops)
    print("\nDone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
