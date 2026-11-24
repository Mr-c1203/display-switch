#!/bin/bash
# 构建 显示器切换.app v2（Swift + 内嵌 DDC 传输层，无外部依赖）
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
macapp="$root/mac-app"
release="$root/release"
app="$release/显示器切换.app"

mkdir -p "$release" "$app/Contents/MacOS" "$app/Contents/Resources"

# 图标：沿用上一版资源；没有则从旧版拷贝
if [[ ! -f "$app/Contents/Resources/DisplaySwitch.icns" ]]; then
    old="$HOME/AI/Amazon/3号店-运营控制台/工程维护/显示器切换/20261010/source/display-switch-1.1.0/release/显示器切换.app/Contents/Resources/DisplaySwitch.icns"
    [[ -f "$old" ]] && cp "$old" "$app/Contents/Resources/DisplaySwitch.icns"
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

# 首版示例机器清单（沿用用户本机配置，发布版可替换为注释版）
if [[ -f "$root/config.txt" ]]; then
    cp "$root/config.txt" "$app/Contents/Resources/config.txt"
fi
cp "$macapp/M1DDC-LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses-m1ddc.txt" 2>/dev/null || true

/usr/bin/python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
info = {
    'CFBundleName': '显示器切换',
    'CFBundleDisplayName': '显示器切换',
    'CFBundleIdentifier': 'com.zcodex.monitorswitch',
    'CFBundleExecutable': 'MonitorSwitch',
    'CFBundleIconFile': 'DisplaySwitch.icns',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '2.0.0',
    'CFBundleVersion': '2.0.0',
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
}
open(sys.argv[1], 'wb').write(plistlib.dumps(info))
PY

/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app" 2>&1 | tail -2
echo "Built: $app"
