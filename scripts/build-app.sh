#!/bin/bash
# Compila Mosaico y arma build/Mosaico.app (firmada ad-hoc para uso local).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Mosaico.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Mosaico "$APP/Contents/MacOS/Mosaico"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Listo: $APP"
