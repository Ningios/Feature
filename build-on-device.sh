#!/bin/sh
# Feature —— 在 iPhone 本机用 theos 编译（真 arm64e），产出一个可安装的 deb
# 用法：sh build-on-device.sh
set -e

echo "== 1/5 找 theos =="
if [ -n "$THEOS" ] && [ -d "$THEOS" ]; then
    : 
elif [ -d "$HOME/theos" ]; then
    THEOS="$HOME/theos"
elif [ -d /var/mobile/theos ]; then
    THEOS=/var/mobile/theos
else
    echo "没找到 theos，请先设置：export THEOS=/path/to/theos"
    exit 1
fi
export THEOS
echo "   THEOS=$THEOS"
[ -x "$THEOS/bin/theos" ] || echo "   注意：$THEOS/bin/theos 不存在（有些安装是 makefiles-only）"

echo "== 2/5 取源码（公开仓库，直接下载 tar.gz）=="
cd /var/mobile
rm -rf feature-build
mkdir -p feature-build
cd feature-build
curl -L -sS -o src.tgz "https://codeload.github.com/Ningios/Feature/tar.gz/refs/heads/main"
tar xzf src.tgz --strip-components=1
rm -f src.tgz
ls Makefile control src/SBXDesktop.mm >/dev/null && echo "   源码 OK"

echo "== 3/5 编译 =="
make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

echo "== 4/5 找产物 =="
DEB=$(find packages -maxdepth 1 -name "*.deb" 2>/dev/null | head -1)
if [ -z "$DEB" ]; then
    echo "没生成 deb，看看上面的报错"
    exit 1
fi
cp -f "$DEB" /var/mobile/Feature-1.0.0.deb || cp -f "$DEB" /var/mobile/Feature.deb
echo "   产物：/var/mobile/Feature-1.0.0.deb"

echo "== 5/5 完成 =="
ls -l /var/mobile/Feature-1.0.0.deb
echo
echo "装它：Filza 打开 /var/mobile/Feature-1.0.0.deb，或 dpkg -i 那个路径"
echo "装完 注销（killall SpringBoard），然后看设置里的 Feature，以及 /var/mobile/Library/Accessibility/feature.log"
