#!/bin/zsh
# Construit, signe, notarise et publie une version de Vocals.
#   ./release.sh 1.2          → build suivant, publié sur GitHub (mise à jour auto des Mac)
#   ./release.sh 1.2 --local  → construit seulement, sans publier
#   ./release.sh 1.2 --cle    → construit seulement, clé ElevenLabs intégrée (premier envoi privé)
# Signature : certificat « Anyone Vocals » du trousseau signature/vocals.keychain-db.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${1:?version, ex. 1.2}
LOCAL=${2:-}
REPO=anyone-dev/vocals
SIG=signature
KC=$SIG/vocals.keychain-db

BUILD=$(cat build-number 2>/dev/null || echo 1)
BUILD=$((BUILD + 1))

APP=build/Vocals.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
KEY=""
[ "$LOCAL" = "--cle" ] && KEY=$(grep '^ELEVENLABS_API_KEY' ~/.env | cut -d= -f2- | tr -d "\"'")
printf 'let embeddedApiKey = "%s"\n' "$KEY" > build/Key.swift
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos13.0 Vocals.swift Updater.swift build/Key.swift -o build/Vocals-$arch
done
rm -f build/Key.swift
lipo -create build/Vocals-arm64 build/Vocals-x86_64 -output "$APP/Contents/MacOS/Vocals"
rm -f build/Vocals-arm64 build/Vocals-x86_64

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Vocals</string>
  <key>CFBundleDisplayName</key><string>Vocals</string>
  <key>CFBundleIdentifier</key><string>fr.anyone.vocals</string>
  <key>CFBundleExecutable</key><string>Vocals</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

# Signature stable « Anyone Vocals » : même certificat à chaque version, donc macOS
# garde les autorisations (WhatsApp, notifications) d'une mise à jour à l'autre.
security unlock-keychain -p "$(cat $SIG/keychain-password)" "$PWD/$KC"
security list-keychains -d user | grep -q "$PWD/$KC" || \
  security list-keychains -d user -s "$PWD/$KC" $(security list-keychains -d user | tr -d '"')
CERT=$(security find-identity -p codesigning "$PWD/$KC" | grep '"Anyone Vocals"' | head -1 | awk '{print $2}')
[ -n "$CERT" ] || { echo "Certificat Anyone Vocals introuvable"; exit 1; }
codesign --force --timestamp=none --keychain "$PWD/$KC" -s "$CERT" -i fr.anyone.vocals "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

ZIP=Vocals-$BUILD.zip
(cd build && ditto -c -k --keepParent Vocals.app $ZIP && cp $ZIP Vocals.zip)
cat > build/latest.json <<JSON
{"version": "$VERSION", "build": $BUILD, "url": "https://github.com/$REPO/releases/download/v$VERSION-$BUILD/$ZIP"}
JSON

if [ -z "$LOCAL" ]; then
  gh release create "v$VERSION-$BUILD" -R $REPO --title "Vocals $VERSION" --notes "Build $BUILD" \
    build/$ZIP build/Vocals.zip build/latest.json
  echo $BUILD > build-number
  echo "Publié : https://github.com/$REPO/releases/latest/download/Vocals.zip"
fi
ls -la build
