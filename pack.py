#!/usr/bin/env python3
"""打包 Feature：layout（单文件设置页 + 图标）+ dylib + 可选 metallib + Sileo 图标
用法：python3 pack.py <编译产物目录>
"""
import os, shutil, subprocess, hashlib, sys

BASE = "/var/minis/shared/sbx-split/desktop"
ART  = sys.argv[1] if len(sys.argv) > 1 else "/tmp/build_local"
OUT  = "/var/minis/attachments/Feature-1.0.6_iphoneos-arm64e.deb"
W    = "/tmp/feature-pack"

shutil.rmtree(W, ignore_errors=True)
tree = os.path.join(W, "tree")
shutil.copytree(os.path.join(BASE, "layout"), tree)


# --- 设置 bundle ---
PB = os.path.join(tree, "Library/PreferenceBundles/SBXDesktopPrefs.bundle")
os.makedirs(PB, exist_ok=True)
for f in ("Info.plist", "Root.plist", "Whitelist.plist"):
    shutil.copyfile(os.path.join(BASE, "prefs", f), os.path.join(PB, f))
    os.chmod(os.path.join(PB, f), 0o644)
_pe = os.path.join(ART, "SBXDesktopPrefs")
if not os.path.exists(_pe):
    _pe = os.path.join(ART, "bin", "SBXDesktopPrefs")
if os.path.exists(_pe):
    shutil.copyfile(_pe, os.path.join(PB, "SBXDesktopPrefs"))
    os.chmod(os.path.join(PB, "SBXDesktopPrefs"), 0o755)
for f in ("icon.png", "icon@2x.png", "icon@3x.png"):
    shutil.copyfile(os.path.join(BASE, "prefs", f), os.path.join(PB, f))
    os.chmod(os.path.join(PB, f), 0o644)
for f in os.listdir(os.path.join(BASE, "prefs/icons_solid")):
    if f.endswith(".png"):
        shutil.copyfile(os.path.join(BASE, "prefs/icons_solid", f), os.path.join(PB, f))
        os.chmod(os.path.join(PB, f), 0o644)
print("设置 bundle 文件数:", len(os.listdir(PB)))

# --- 主库 ---
DL = os.path.join(tree, "Library/MobileSubstrate/DynamicLibraries")
os.makedirs(DL, exist_ok=True)
shutil.copyfile(os.path.join(ART, "SBXDesktop.dylib"), os.path.join(DL, "SBXDesktop.dylib"))
os.chmod(os.path.join(DL, "SBXDesktop.dylib"), 0o755)
# 注入配置（必须！否则 substrate 不知道要注入主库）
shutil.copyfile(os.path.join(BASE, "SBXDesktop.plist"), os.path.join(DL, "SBXDesktop.plist"))
os.chmod(os.path.join(DL, "SBXDesktop.plist"), 0o644)

# --- 液态玻璃着色器（有就带） ---
md = os.path.join(tree, "usr/share/glassclear")
os.makedirs(md, exist_ok=True)
_ml = os.path.join(ART, "default.metallib")
if os.path.exists(_ml):
    shutil.copyfile(_ml, os.path.join(md, "default.metallib"))
    os.chmod(os.path.join(md, "default.metallib"), 0o644)
    print("已包含 default.metallib（液态玻璃可用）")
else:
    print("⚠️ 无 default.metallib：按钮回退系统材质")

# --- Sileo 包图标 ---
ic = os.path.join(tree, "usr/share/icons")
os.makedirs(ic, exist_ok=True)
for src, dst in (("feature.png", "com.ning.feature.png"),
                 ("feature-256.png", "com.ning.feature-256.png")):
    p = os.path.join(BASE, "plugins_icons", src)
    if os.path.exists(p):
        shutil.copyfile(p, os.path.join(ic, dst))
        os.chmod(os.path.join(ic, dst), 0o644)

# --- control ---
os.makedirs(os.path.join(tree, "DEBIAN"), exist_ok=True)
control = """Package: com.ning.feature
Section: Tweaks
Installed-Size: 600
Maintainer: Ning
Architecture: iphoneos-arm64e
Version: 1.0.6
Depends: mobilesubstrate, preferenceloader, firmware (>= 16.0), firmware (<< 18.0)
Description: 桌面功能（从 SystemX 拆出：后台一键清除按钮 / iPad 卡片后台 / iPad 悬浮 Dock）
Name: Feature
Author: Ning
Icon: file:///usr/share/icons/com.ning.feature.png
"""
open(os.path.join(tree, "DEBIAN/control"), "w").write(control)

if os.path.exists(OUT):
    os.remove(OUT)
subprocess.run(["dpkg-deb", "-Zgzip", "-b", tree, OUT], check=True)
data = open(OUT, "rb").read()
print("PACKED:", OUT, len(data), "bytes")
print("SHA256:", hashlib.sha256(data).hexdigest())