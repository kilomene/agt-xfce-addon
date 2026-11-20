#!/usr/bin/env python3
"""Build an AGT add-on package from a directory.

The directory must hold addon.json at its root:
    {"id": "hello-tool", "name": "Hello Tool", "version": "1.0.0",
     "description": "...", "bin": ["hello-tool"]}
plus the payload (bin/, lib/, anything else the tool needs).
Symlinks inside the directory are carried the bootstrap way: they
are written into SYMLINKS.txt (target<-linkpath, the arrow is
U+2190) instead of into the zip, because a zip cannot be trusted
to preserve them; both install doors apply SYMLINKS.txt.

Usage:
    python3 make_addon.py <dir> [--out <dir>]

Writes <id>-<version>.zip (default out dir: ./addon-packages) and
prints the sha256 pin and the addon-install command to send once
the package is hosted at a URL the phone can download.
"""

import argparse
import hashlib
import json
import os
import sys
import zipfile

IDCHARS = "abcdefghijklmnopqrstuvwxyz0123456789-"


def valid_id(i):
    return (
        1 <= len(i) <= 63
        and i[0] in "abcdefghijklmnopqrstuvwxyz0123456789"
        and all(c in IDCHARS for c in i)
    )


def valid_bin(n):
    return n not in ("", ".", "..") and "/" not in n and "\\" not in n


def main():
    ap = argparse.ArgumentParser(description="Build an AGT add-on package.")
    ap.add_argument("dir", help="package source directory with addon.json at its root")
    ap.add_argument("--out", default=os.path.expanduser("~/workspace/agt-phoenix/addon-packages"))
    args = ap.parse_args()

    src = os.path.abspath(args.dir)
    manifest_path = os.path.join(src, "addon.json")
    if not os.path.exists(manifest_path):
        sys.exit(f"no addon.json at {manifest_path}")
    with open(manifest_path, encoding="utf-8") as f:
        m = json.load(f)
    mid, name, ver = m.get("id", ""), m.get("name", ""), m.get("version", "")
    binl = m.get("bin", [])
    if not valid_id(mid):
        sys.exit(f"bad add-on id: {mid!r}")
    if not name or not ver:
        sys.exit("addon.json needs a name and a version")
    if not isinstance(binl, list) or any(not valid_bin(b) for b in binl):
        sys.exit("addon.json bin entries must be bare file names")
    for b in binl:
        if not os.path.exists(os.path.join(src, "bin", b)):
            sys.exit(f"bin entry {b} has no file at bin/{b}")

    files = []   # (arcname, fullpath) regular files
    links = []   # (target, arcname) symlinks
    for root, dirs, names in os.walk(src):
        dirs.sort()
        for n in sorted(names):
            full = os.path.join(root, n)
            arc = os.path.relpath(full, src)
            if os.path.islink(full):
                links.append((os.readlink(full), arc))
            else:
                files.append((arc, full))
        for n in list(dirs):
            full = os.path.join(root, n)
            if os.path.islink(full):
                arc = os.path.relpath(full, src)
                links.append((os.readlink(full), arc))
                dirs.remove(n)

    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, f"{mid}-{ver}.zip")
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, full in files:
            info = zipfile.ZipInfo.from_file(full, arc)
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(info, fh.read())
        if links:
            text = "".join(f"{t}←{p}\n" for t, p in sorted(links, key=lambda x: x[1]))
            z.writestr("SYMLINKS.txt", text)
    data = open(out_path, "rb").read()
    sha = hashlib.sha256(data).hexdigest()
    print(f"package: {out_path}")
    print(f"id:      {mid}  version: {ver}")
    print(f"size:    {len(data)} bytes")
    print(f"sha256:  {sha}")
    print("once hosted at a URL the phone can reach, install with:")
    print(f"  python3 agt_jobs.py addon-install --device <device> --url <URL> --sha256 {sha}")


if __name__ == "__main__":
    main()
