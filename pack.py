#!/usr/bin/env python3
"""把编译产物 + 布局 + 设置页打成 deb（桌面功能 三合一独立包）
用法：python3 pack.py <编译产物目录>
"""
import os, shutil, subprocess, hashlib, sys

BASE = "/var/minis/shared/sbx-split/desktop"
ART  = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sbxdesk"
OUT  = "/var/minis/attachments/SBX-Desktop_1.0.0_iphoneos-arm64e.deb"
W    = "/tmp/sbxdesk-pack"

shutil.rmtree(W, ignore_errors=True)
tree = os.path.join(W, "tree")
shutil.copytree(os.path.join(BASE, "layout"), tree)

DL = os.path.join(tree, "Library/MobileSubstrate/DynamicLibraries")
PB = os.path.join(tree, "Library/PreferenceBundles/SBXDesktopPrefs.bundle")
os.makedirs(DL, exist_ok=True); os.makedirs(PB, exist_ok=True)

shutil.copyfile(os.path.join(ART, "SBXDesktop.dylib"), os.path.join(DL, "SBXDesktop.dylib"))
os.chmod(os.path.join(DL, "SBXDesktop.dylib"), 0o755)

for f in ("Info.plist", "Root.plist", "Whitelist.plist"):
    shutil.copyfile(os.path.join(BASE, "prefs", f), os.path.join(PB, f))
    os.chmod(os.path.join(PB, f), 0o644)

# 设置入口图标（29/58/87）
for f in ("icon.png", "icon@2x.png", "icon@3x.png"):
    if os.path.exists(os.path.join(BASE, "prefs", f)):
        shutil.copyfile(os.path.join(BASE, "prefs", f), os.path.join(PB, f))
        os.chmod(os.path.join(PB, f), 0o644)

# 自绘图标（29/58/87 三档）一起进 bundle
icodir = os.path.join(BASE, "prefs/icons_solid")   # 正式图标：实心（加粗）风格
n = 0
for f in os.listdir(icodir):
    if f.endswith(".png"):
        shutil.copyfile(os.path.join(icodir, f), os.path.join(PB, f))
        os.chmod(os.path.join(PB, f), 0o644); n += 1
print("图标:", n, "个")
shutil.copyfile(os.path.join(ART, "SBXDesktopPrefs"), os.path.join(PB, "SBXDesktopPrefs"))
os.chmod(os.path.join(PB, "SBXDesktopPrefs"), 0o755)

# 航的液态玻璃着色器（metallib）
md = os.path.join(tree, "usr/share/glassclear"); os.makedirs(md, exist_ok=True)
shutil.copyfile(os.path.join(ART, "default.metallib"), os.path.join(md, "default.metallib"))
os.chmod(os.path.join(md, "default.metallib"), 0o644)

# Sileo 包图标
ic = os.path.join(tree, "usr/share/icons"); os.makedirs(ic, exist_ok=True)
shutil.copyfile(os.path.join(BASE, "plugins_icons/feature.png"), os.path.join(ic, "com.ning.feature.png"))
shutil.copyfile(os.path.join(BASE, "plugins_icons/feature-256.png"), os.path.join(ic, "com.ning.feature-256.png"))
os.chmod(os.path.join(ic, "com.ning.feature.png"), 0o644)

os.makedirs(os.path.join(tree, "DEBIAN"), exist_ok=True)
control = """Package: com.ning.feature
Section: Tweaks
Installed-Size: 500
Maintainer: Ning
Architecture: iphoneos-arm64e
Version: 1.0.0
Depends: mobilesubstrate, preferenceloader, firmware (>= 16.0), firmware (<< 18.0)
Description: 桌面功能（从 SystemX 拆出：后台一键清除按钮 / iPad 卡片后台 / iPad 悬浮 Dock）
Name: Feature
Author: Ning
Icon: file:///usr/share/icons/com.ning.feature.png
"""
open(os.path.join(tree, "DEBIAN/control"), "w").write(control)

if os.path.exists(OUT): os.remove(OUT)
subprocess.run(["dpkg-deb", "-Zgzip", "-b", tree, OUT], check=True)
data = open(OUT, "rb").read()
print("PACKED:", OUT, len(data), "bytes")
print("SHA256:", hashlib.sha256(data).hexdigest())
