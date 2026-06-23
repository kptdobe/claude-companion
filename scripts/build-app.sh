#!/bin/sh
# build-app.sh [-x]
#
# Builds a release binary and assembles ClaudeCompanion.app — a proper menu bar
# (LSUIElement) bundle. A real bundle gives the app a stable identity so the
# Accessibility / Automation permissions used for window-jumping stick.
#
# Defaults to a DRY RUN (prints what it would do). Pass -x to actually build.

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ClaudeCompanion.app"
EXECUTE=0
[ "$1" = "-x" ] && EXECUTE=1

echo "Project   : $ROOT"
echo "App bundle: $APP"

if [ "$EXECUTE" -ne 1 ]; then
    echo
    echo "DRY RUN — would run: swift build -c release"
    echo "          then assemble $APP (LSUIElement menu bar app)."
    echo "Re-run with -x to build."
    exit 0
fi

echo "Building release binary…"
( cd "$ROOT" && swift build -c release )
BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/ClaudeCompanion"

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeCompanion"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Companion</string>
    <key>CFBundleDisplayName</key>     <string>Claude Companion</string>
    <key>CFBundleIdentifier</key>      <string>com.acapt.claude-companion</string>
    <key>CFBundleVersion</key>         <string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key>      <string>ClaudeCompanion</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSAppleEventsUsageDescription</key>
        <string>Claude Companion focuses the window of the session you click.</string>
</dict>
</plist>
PLIST

# Sign with a stable self-signed identity when available, so the Accessibility
# permission (needed to switch windows) persists across rebuilds. Falls back to
# ad-hoc, whose identity changes every build and forces macOS to re-prompt.
SIGN_IDENTITY="Claude Companion Local"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "Signing with stable identity '$SIGN_IDENTITY'…"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --identifier "com.acapt.claude-companion" "$APP"
else
    echo "No stable signing identity found — using ad-hoc signing."
    echo "  Run scripts/setup-signing.sh once so the Accessibility grant persists."
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
        echo "  (codesign skipped — not fatal for local use)"
fi

echo "Built $APP"
echo "Launch with: open \"$APP\"   (or add it to Login Items)"
