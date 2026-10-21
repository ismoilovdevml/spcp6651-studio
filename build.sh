#!/usr/bin/env bash
# Build MG330 Studio. `./build.sh` builds to build/Release; `./build.sh install`
# also copies the app to /Applications and launches it.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=Release
APP="build/$CONFIG/MG330Studio.app"
# Input Monitoring is granted against the code signature, so a stable identity is what
# makes the grant survive a rebuild. Ad-hoc signatures change every time and lose it.
IDENTITY="${MG330_SIGN_IDENTITY:-N75Studio Local Signing}"

echo "==> Building $CONFIG"
xcodebuild -project MG330Studio.xcodeproj -target MG330Studio -configuration "$CONFIG" \
    CODE_SIGNING_ALLOWED=NO build | tail -1

if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "==> Signing with \"$IDENTITY\""
    codesign --force --deep --options runtime \
        --entitlements MG330Studio/MG330Studio.entitlements \
        --sign "$IDENTITY" "$APP"
else
    echo "==> \"$IDENTITY\" not found, signing ad hoc"
    echo "    (macOS will refuse the device until Input Monitoring is re-granted — see README)"
    codesign --force --deep --options runtime \
        --entitlements MG330Studio/MG330Studio.entitlements --sign - "$APP"
fi

codesign --verify --strict "$APP" && echo "==> Signature valid"

if [ "${1:-}" = "install" ]; then
    echo "==> Installing to /Applications"
    osascript -e 'quit app "MG330Studio"' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/MG330Studio.app
    cp -R "$APP" /Applications/
    open -a /Applications/MG330Studio.app
fi

echo "==> Done: $APP"
