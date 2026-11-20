#!/bin/bash
# Compila Mosaico y arma build/Mosaico.app.
#
# Firma con un certificado local fijo (no ad-hoc). Así macOS reconoce que es la misma app
# en cada compilación y no vuelve a pedir los permisos (Documentos, Calendario, etc.).
# El certificado vive en un llavero propio, fuera del llavero de inicio de sesión.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_DIR="$HOME/Library/Application Support/Mosaico/signing"
KEYCHAIN="$SIGN_DIR/mosaico.keychain-db"
KEYCHAIN_PASS="mosaico-local-build"
IDENTITY="Mosaico Local Signing"

if [ ! -f "$KEYCHAIN" ]; then
    echo "Creando certificado de firma local (una sola vez)…"
    mkdir -p "$SIGN_DIR"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$IDENTITY" -out "$TMP/id.p12" -passout pass:mosaico
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$TMP/id.p12" -k "$KEYCHAIN" -P mosaico -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
fi

swift build -c release

APP="build/Mosaico.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Mosaico "$APP/Contents/MacOS/Mosaico"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
echo "Listo: $APP"
