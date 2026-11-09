#!/usr/bin/env python3
"""Build a rootless-compatible Debian package without macOS dpkg/ar quirks."""
import argparse, gzip, hashlib, os, shutil, struct, tarfile, tempfile, time
from pathlib import Path


def copy_file(src: Path, dst: Path, mode=None):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    if mode is not None:
        os.chmod(dst, mode)


def make_tar_gz(root: Path, out: Path):
    with gzip.GzipFile(filename="", mode="wb", fileobj=out.open("wb"), mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tf:
            items = sorted(root.rglob("*"), key=lambda p: str(p.relative_to(root)))
            for p in items:
                arc = str(p.relative_to(root))
                ti = tf.gettarinfo(str(p), arcname=arc)
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = "root"
                ti.mtime = 0
                if p.is_file() and not p.is_symlink():
                    with p.open("rb") as f:
                        tf.addfile(ti, f)
                else:
                    tf.addfile(ti)


def make_ar(out: Path, members):
    with out.open("wb") as f:
        f.write(b"!<arch>\n")
        for name, path in members:
            data = Path(path).read_bytes()
            header = "{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n".format(
                name, 0, 0, 0, "100644", len(data)
            ).encode("ascii")
            if len(header) != 60:
                raise RuntimeError("invalid ar header")
            f.write(header)
            f.write(data)
            if len(data) & 1:
                f.write(b"\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args()
    base = Path(__file__).resolve().parents[1]
    art = args.artifacts.resolve()
    with tempfile.TemporaryDirectory(prefix="feature-deb-") as td:
        work = Path(td)
        tree = work / "data"
        shutil.copytree(base / "layout", tree)
        dl = tree / "Library/MobileSubstrate/DynamicLibraries"
        copy_file(art / "SBXDesktop.dylib", dl / "SBXDesktop.dylib", 0o755)
        copy_file(base / "SBXDesktop.plist", dl / "SBXDesktop.plist", 0o644)

        pb = tree / "Library/PreferenceBundles/SBXDesktopPrefs.bundle"
        for name in ("Info.plist", "Root.plist", "Whitelist.plist"):
            copy_file(base / "prefs" / name, pb / name, 0o644)
        pref_exec = art / "bin/SBXDesktopPrefs"
        if not pref_exec.exists():
            pref_exec = art / "SBXDesktopPrefs"
        copy_file(pref_exec, pb / "SBXDesktopPrefs", 0o755)
        for name in ("icon.png", "icon@2x.png", "icon@3x.png"):
            copy_file(base / "prefs" / name, pb / name, 0o644)
        for p in sorted((base / "prefs/icons_solid").glob("*.png")):
            copy_file(p, pb / p.name, 0o644)

        metallib = art / "default.metallib"
        if metallib.exists():
            copy_file(metallib, tree / "usr/share/glassclear/default.metallib", 0o644)
        for src, name in (("feature.png", "com.ning.feature.png"),
                          ("feature-256.png", "com.ning.feature-256.png"),
                          ("feature-128.png", "com.ning.feature-128.png")):
            p = base / "plugins_icons" / src
            if p.exists():
                copy_file(p, tree / "usr/share/icons" / name, 0o644)

        control = work / "control"
        control.mkdir()
        (control / "control").write_text(
            "Package: com.ning.feature\n"
            "Name: Feature\n"
            "Version: 1.0.1\n"
            "Architecture: iphoneos-arm64e\n"
            "Description: Desktop features\n"
            "Maintainer: Ning\n"
            "Author: Ning\n"
            "Section: Tweaks\n"
            "Depends: mobilesubstrate, preferenceloader, firmware (>= 16.0), firmware (<< 18.0)\n"
            "Icon: file:///usr/share/icons/com.ning.feature.png\n"
        )
        debian_binary = work / "debian-binary"
        debian_binary.write_bytes(b"2.0\n")
        control_gz = work / "control.tar.gz"
        data_gz = work / "data.tar.gz"
        make_tar_gz(control, control_gz)
        make_tar_gz(tree, data_gz)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        make_ar(args.output, [("debian-binary", debian_binary),
                              ("control.tar.gz", control_gz),
                              ("data.tar.gz", data_gz)])
    print(f"PACKED {args.output} {args.output.stat().st_size} bytes")
    print("SHA256", hashlib.sha256(args.output.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
