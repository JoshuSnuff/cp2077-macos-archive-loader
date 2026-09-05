#!/usr/bin/env bash
set -euo pipefail

GAME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$GAME_DIR/Cyberpunk2077.app"
BINARY="$APP/Contents/MacOS/Cyberpunk2077"
ENT="$GAME_DIR/red4ext_entitlements.plist"

echo "=== RED4ext Re-signing ==="
echo "Game: $APP"
echo ""

# 1) Nested dylibs (no entitlements)
echo "Signing nested dylibs..."
while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib"
done < <(find "$APP/Contents" -name "*.dylib" -print0)
echo "  done"

# 2) Frameworks (no entitlements)
echo "Signing frameworks..."
while IFS= read -r -d '' framework; do
    codesign --force --sign - "$framework"
done < <(find "$APP/Contents/Frameworks" -type d -name "*.framework" -print0)
echo "  done"

# 3) Main executable WITH entitlements
echo "Signing main executable with entitlements..."
codesign --force --sign - --entitlements "$ENT" "$BINARY"
echo "  done"

# 4) App bundle WITH entitlements
echo "Signing app bundle..."
codesign --force --sign - --entitlements "$ENT" "$APP"
echo "  done"

# 5) Remove quarantine
echo "Removing quarantine attributes..."
xattr -cr "$APP" 2>/dev/null || true
find "$GAME_DIR/red4ext" -type f -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true
echo "  done"

# Verify
echo ""
echo "=== Verification ==="
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "flags="
codesign -d --entitlements - "$APP" 2>&1 | grep -E "allow-unsigned|allow-jit|allow-dyld|disable-library" || true
echo ""
echo "Re-signing complete."
