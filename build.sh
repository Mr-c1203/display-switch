#!/bin/bash
# 构建 显示器切换.app v2（Swift + 内嵌 DDC 传输层，无外部依赖）
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
macapp="$root/mac-app"
release="$root/release"
app="$release/显示器切换.app"
version="$(tr -d '[:space:]' < "$root/VERSION")"

mkdir -p "$release" "$app/Contents/MacOS" "$app/Contents/Resources"

# 图标：沿用上一版资源；没有则从旧版拷贝
if [[ ! -f "$app/Contents/Resources/DisplaySwitch.icns" ]]; then
    old="$HOME/AI/Amazon/3号店-运营控制台/工程维护/显示器切换/20261010/source/display-switch-1.1.0/release/显示器切换.app/Contents/Resources/DisplaySwitch.icns"
    if [[ -f "$old" ]]; then
        cp "$old" "$app/Contents/Resources/DisplaySwitch.icns"
    else
        iconset="$release/DisplaySwitch.iconset"; master="$release/icon-master.png"
        mkdir -p "$iconset"
        /usr/bin/xcrun swift "$macapp/draw-icon.swift" "$master"
        for size in 16 32 128 256 512; do
            /usr/bin/sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
            /usr/bin/sips -z $((size*2)) $((size*2)) "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
        done
        /usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/DisplaySwitch.icns"
    fi
fi

# Objective-C 部分（m1ddc 传输层 + DDC 封装）
xcrun clang -O2 -fmodules -c "$macapp/avservice.m" "$macapp/ioregistry.m" "$macapp/i2c.m" -o /dev/null 2>/dev/null || true
mkdir -p "$release/.obj"
xcrun clang -O2 -fmodules -c "$macapp/avservice.m"      -o "$release/.obj/avservice.o"
xcrun clang -O2 -fmodules -c "$macapp/ioregistry.m"     -o "$release/.obj/ioregistry.o"
xcrun clang -O2 -fmodules -c "$macapp/i2c.m"            -o "$release/.obj/i2c.o"
xcrun clang -O2 -fobjc-arc -fmodules -c "$macapp/DDC.m" -o "$release/.obj/DDC.o"

# Swift 部分 + 链接
xcrun swiftc -O \
    -import-objc-header "$macapp/BridgingHeader.h" \
    -framework AppKit -framework Carbon -framework ServiceManagement -framework IOKit -framework CoreGraphics \
    -F /System/Library/PrivateFrameworks -framework CoreDisplay \
    "$macapp/main.swift" "$macapp/Models.swift" "$macapp/DDCController.swift" \
    "$release/.obj/"*.o \
    -o "$app/Contents/MacOS/MonitorSwitch"

# 公开包不带任何设备专用输入编号；首次启动自动识别接口
rm -f "$app/Contents/Resources/config.txt"
cp "$macapp/M1DDC-LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses-m1ddc.txt" 2>/dev/null || true

/usr/bin/python3 - "$app/Contents/Info.plist" "$version" <<'PY'
import plistlib, sys
info = {
    'CFBundleName': '显示器切换',
    'CFBundleDisplayName': '显示器切换',
    'CFBundleIdentifier': 'com.zcodex.monitorswitch',
    'CFBundleExecutable': 'MonitorSwitch',
    'CFBundleIconFile': 'DisplaySwitch.icns',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': sys.argv[2],
    'CFBundleVersion': sys.argv[2],
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
}
open(sys.argv[1], 'wb').write(plistlib.dumps(info))
PY

/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app" 2>&1 | tail -2
# 发布用压缩包（关于→检查更新 会下载这个文件名里带 macOS 的包）
(cd "$release" && rm -f DisplaySwitch-macOS-*.zip && /usr/bin/ditto -c -k --keepParent "显示器切换.app" "DisplaySwitch-macOS-$version.zip")
echo "Built: $app ($version)"
