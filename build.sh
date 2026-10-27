#!/bin/zsh
# 构建 TNT go Touchpad.app(需要 Xcode Command Line Tools 的 swiftc)
set -euo pipefail
cd "$(dirname "$0")"

APP="TNTgo Touchpad.app"

rm -rf build "$APP"
mkdir -p build
swiftc -O main.swift -o build/tntgo-touchpad

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/tntgo-touchpad "$APP/Contents/MacOS/tntgo-touchpad"

# 图标:assets/icon.icns 缺失时,从 make-icon.swift 的产物 icon_1024.png 重新生成
if [ ! -f assets/icon.icns ] && [ -f icon_1024.png ]; then
    rm -rf icon.iconset
    mkdir -p icon.iconset assets
    for size in 16 32 128 256 512; do
        sips -z $size $size icon_1024.png --out "icon.iconset/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) icon_1024.png --out "icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns icon.iconset -o assets/icon.icns
    echo "✓ 已从 icon_1024.png 重新生成 assets/icon.icns"
fi

if [ -f assets/icon.icns ]; then
    cp assets/icon.icns "$APP/Contents/Resources/icon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TNT go Touchpad</string>
    <key>CFBundleDisplayName</key><string>TNT go Touchpad</string>
    <key>CFBundleIdentifier</key><string>com.tntgo.touchpad</string>
    <key>CFBundleExecutable</key><string>tntgo-touchpad</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>icon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 用固定的开发证书签名:TCC(辅助功能/输入监控)按证书匹配,
# 重新编译后权限不再失效。证书不存在时退回 ad-hoc 签名。
IDENTITY="TNTgo Touchpad Dev"
if ! codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "⚠ 开发证书不可用,已退回 ad-hoc 签名(TCC 权限将随重编译失效)"
fi

echo "✓ 已构建 $APP"
echo "  调试运行: TNTGO_DEBUG=1 ./build/tntgo-touchpad"
echo "  正式使用: 把「$APP」拷到 /Applications 后打开"
