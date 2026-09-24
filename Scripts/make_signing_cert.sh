#!/bin/bash
# One-time: create a self-signed code-signing cert named "StemDrop Local Signing"
# in the login keychain and trust it for code signing. bundle.sh picks it up
# automatically. Run this yourself: it touches your keychain.
set -euo pipefail
TMP="$(mktemp -d)"
cd "$TMP"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=StemDrop Local Signing/O=Resolute Canvas" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -out sd.p12 -inkey key.pem -in cert.pem -passout pass:stemdrop
security import sd.p12 -k ~/Library/Keychains/login.keychain-db -P stemdrop -T /usr/bin/codesign
# Trust it for code signing (this will ask for your Mac password).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
rm -rf "$TMP"
echo "Done. Verify with: security find-identity -v -p codesigning"
