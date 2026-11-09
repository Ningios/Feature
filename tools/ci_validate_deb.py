#!/usr/bin/env python3
"""Validate a .deb without dpkg-deb (works on macOS runners)."""
import gzip
import hashlib
import io
import struct
import sys
import tarfile
from pathlib import Path


def read_ar(path: Path):
    data = path.read_bytes()
    if data[:8] != b"!<arch>\n":
        raise SystemExit("invalid ar magic")
    pos = 8
    members = {}
    while pos < len(data):
        if pos + 60 > len(data):
            raise SystemExit("truncated ar header")
        hdr = data[pos:pos + 60]
        name = hdr[:16].decode("ascii", "replace").strip()
        raw_size = hdr[48:58].decode("ascii", "replace").strip()
        try:
            size = int(raw_size)
        except ValueError:
            raise SystemExit(f"invalid ar size for {name!r}")
        start = pos + 60
        end = start + size
        if end > len(data):
            raise SystemExit(f"truncated ar member {name}")
        members[name.rstrip("/")] = data[start:end]
        pos = end + (size & 1)
    return members


def validate_tar_gz(name, payload, required):
    try:
        raw = gzip.decompress(payload)
    except Exception as exc:
        raise SystemExit(f"{name}: gzip error: {exc}")
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tf:
        infos = tf.getmembers()
        if not infos:
            raise SystemExit(f"{name}: empty tar")
        for info in infos:
            if info.pax_headers:
                raise SystemExit(f"{name}: PAX header found: {info.name}")
            if info.type not in (tarfile.REGTYPE, tarfile.DIRTYPE):
                raise SystemExit(f"{name}: non-USTAR member type {info.type!r}: {info.name}")
        names = {info.name for info in infos}
        for item in required:
            if item not in names:
                raise SystemExit(f"{name}: missing {item}")
        return tf, infos


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: ci_validate_deb.py package.deb")
    path = Path(sys.argv[1])
    members = read_ar(path)
    expected = {"debian-binary", "control.tar.gz", "data.tar.gz"}
    if set(members) != expected:
        raise SystemExit(f"unexpected ar members: {sorted(members)}")
    if members["debian-binary"] != b"2.0\n":
        raise SystemExit("bad debian-binary")
    validate_tar_gz("control.tar.gz", members["control.tar.gz"], ["control"])
    validate_tar_gz("data.tar.gz", members["data.tar.gz"], ["Library"])
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"DEB_OK {path} {path.stat().st_size} bytes sha256={digest}")


if __name__ == "__main__":
    main()
