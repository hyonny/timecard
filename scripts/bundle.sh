#!/bin/zsh
# Timecard.app を組み立てる。--install を付けると /Applications に入れて起動し直す
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Timecard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Timecard" "$APP/Contents/MacOS/Timecard"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>jp.hyonny.timecard</string>
    <key>CFBundleName</key>
    <string>Timecard</string>
    <key>CFBundleExecutable</key>
    <string>Timecard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 開発用の証明書があればそれで署名する。ad-hoc 署名だとビルドのたびに別のアプリ扱いになり、
# キーチェーンの連携情報を読むときに毎回許可を求められる
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "作成: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Timecard || true
    rm -rf /Applications/Timecard.app
    cp -R "$APP" /Applications/Timecard.app
    open /Applications/Timecard.app
    echo "インストールして起動: /Applications/Timecard.app"
fi
