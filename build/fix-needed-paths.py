#!/usr/bin/env python3
"""Rewrite absolute-path DT_NEEDED entries in staged add-on ELFs to
plain basenames.

Root cause: the bootstrap stage's libz.so carries no SONAME, so when
ld linked add-on libraries against it by path it recorded the full
build-machine path (…/stage/usr/lib/libz.so) as the DT_NEEDED name.
That path does not exist on the phone, so the Android linker refuses
to load anything that needs it ("CANNOT LINK EXECUTABLE ... library
.../libz.so not found"). The phone resolves the plain name fine via
LD_LIBRARY_PATH / RUNPATH, exactly like the other bootstrap libs.

The replacement is shorter than the original string, so it is
written in place inside .dynstr with NUL padding; offsets and section
sizes do not change. Only strings that readelf reports as DT_NEEDED
values are touched (never RPATH/RUNPATH or debug strings).

Usage: fix-needed-paths.py <tree-root>
Exit 0 always; prints one line per patched file.
"""
import re
import subprocess
import sys

ROOT = sys.argv[1]
STAGE_MARK = "/stage/usr/lib/"


def dynstr_offset(path):
    out = subprocess.run(["readelf", "-S", path], capture_output=True,
                         text=True).stdout
    for line in out.splitlines():
        m = re.search(r"\.dynstr\s+PROGBITS\s+[0-9a-f]+\s+([0-9a-f]+)", line)
        if m:
            return int(m.group(1), 16)
    return None


def needed_strings(path):
    """Yield (dynstr_offset, string) for each DT_NEEDED value."""
    out = subprocess.run(["readelf", "-d", path], capture_output=True,
                         text=True).stdout
    names = []
    for line in out.splitlines():
        m = re.search(r"\(NEEDED\).*\[([^\]]+)\]", line)
        if m:
            names.append(m.group(1))
    if not names:
        return
    listing = subprocess.run(["readelf", "-p", ".dynstr", path],
                             capture_output=True, text=True).stdout
    offsets = {}
    for line in listing.splitlines():
        m = re.match(r"\s*\[\s*([0-9a-f]+)\]\s+(.*)$", line)
        if m:
            offsets[m.group(2).strip()] = int(m.group(1), 16)
    for name in names:
        if name in offsets:
            yield offsets[name], name


def main():
    import os
    patched = 0
    for dirpath, _dirs, files in os.walk(ROOT):
        for fn in files:
            path = os.path.join(dirpath, fn)
            try:
                with open(path, "rb") as f:
                    if f.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue
            targets = [(off, s) for off, s in (needed_strings(path) or [])
                       if "/" in s]
            if not targets:
                continue
            base = dynstr_offset(path)
            if base is None:
                print("SKIP (no .dynstr):", path)
                continue
            with open(path, "r+b") as f:
                for off, s in targets:
                    new = s.rsplit("/", 1)[-1]
                    if STAGE_MARK not in s and not s.startswith("/"):
                        continue
                    raw = s.encode()
                    f.seek(base + off)
                    f.write(new.encode() + b"\x00" * (len(raw) - len(new)))
                    print("patched %s: %s -> %s" % (path, s, new))
                    patched += 1
    print("total patched strings:", patched)


if __name__ == "__main__":
    main()
