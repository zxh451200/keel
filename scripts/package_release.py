#!/usr/bin/env python3
"""Package exactly the verified release files, including hidden files; no publish."""
import argparse
import hashlib
from pathlib import Path
import zipfile
import stat
from release_evidence import relative_files, sha256
from verify_release_evidence import verify


def plain_parent(path: Path) -> None:
    parent = path.parent
    for item in (parent, *parent.parents):
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise ValueError("ZIP parent must be a real directory")


def package(root: Path, archive: Path) -> None:
    root, archive = root.absolute(), archive.absolute()
    if root == archive or root in archive.parents:
        raise ValueError("ZIP must be outside release root")
    plain_parent(archive)
    if archive.exists() or archive.is_symlink():
        raise ValueError("refuse to overwrite existing ZIP")
    verify(root)
    files = relative_files(root, exclude_evidence=False)
    expected = {p.relative_to(root).as_posix(): sha256(p) for p in files}
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as stream:
        for path in files:
            stream.write(path, path.relative_to(root).as_posix())
    with zipfile.ZipFile(archive) as stream:
        if len(stream.namelist()) != len(expected) or set(stream.namelist()) != set(expected):
            raise ValueError("ZIP coverage mismatch")
        for name, digest in expected.items():
            with stream.open(name) as member:
                actual = hashlib.sha256()
                for chunk in iter(lambda: member.read(1024 * 1024), b""):
                    actual.update(chunk)
            if actual.hexdigest() != digest:
                raise ValueError("ZIP content mismatch: " + name)
    verify(root)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--zip", type=Path, required=True)
    args = parser.parse_args()
    package(args.root, args.zip)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
