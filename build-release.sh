#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
release="$root/release"
app="$release/显示器切换.app"
iconset="$release/DisplaySwitch.iconset"
master="$release/显示器切换-图标.png"

mkdir -p "$release" "$iconset" "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/xcrun swift "$root/mac-app/draw-icon.swift" "$master"

for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/DisplaySwitch.icns"

/usr/bin/xcrun swiftc -O -framework AppKit -framework ServiceManagement \
    "$root/mac-app/main.swift" -o "$app/Contents/MacOS/MonitorSwitch"
m1ddc_bin="${M1DDC_BIN:-/Applications/MonitorSwitch.app/Contents/MacOS/m1ddc}"
if [[ ! -x "$m1ddc_bin" ]]; then
    echo "Set M1DDC_BIN to an installed m1ddc executable" >&2
    exit 1
fi
/bin/cp "$m1ddc_bin" "$app/Contents/MacOS/m1ddc"
/bin/cp "${DISPLAY_SWITCH_CONFIG:-$root/mac-app/config.example.txt}" "$app/Contents/Resources/config.txt"
/bin/cp "$root/THIRD_PARTY_LICENSES.txt" "$app/Contents/Resources/ThirdPartyLicenses.txt"

/usr/bin/python3 - "$app/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib, sys
info = {
    'CFBundleName': '显示器切换',
    'CFBundleDisplayName': '显示器切换',
    'CFBundleIdentifier': 'com.zcodex.monitorswitch',
    'CFBundleExecutable': 'MonitorSwitch',
    'CFBundleIconFile': 'DisplaySwitch.icns',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.1.0',
    'CFBundleVersion': '1.1.0',
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
}
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"

/usr/bin/python3 - "$master" "$root/windows/DisplaySwitch.ico" <<'PY'
from PIL import Image
import sys
with Image.open(sys.argv[1]) as image:
    image.save(sys.argv[2], format='ICO', sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
PY

echo "Built $app"
echo "Built $root/windows/DisplaySwitch.ico"
