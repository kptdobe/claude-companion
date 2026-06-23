#!/bin/sh
# setup-signing.sh
#
# Creates a STABLE self-signed code-signing identity in your login keychain so
# ClaudeCompanion.app keeps a consistent identity across rebuilds. Without this
# the app is ad-hoc signed and its identity changes on every build, which makes
# macOS forget the Accessibility permission and re-prompt every time.
#
# Run once. Idempotent. build-app.sh picks the identity up automatically.

set -e
IDENTITY="Claude Companion Local"
KEYCHAIN="$(security default-keychain | tr -d ' "')"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing identity '$IDENTITY'…"
TMP="$(mktemp -d)"
cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" >/dev/null 2>&1
# A non-empty export password avoids a macOS PKCS12 MAC-verification quirk.
P12PASS="claude-companion-local"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$P12PASS" >/dev/null 2>&1

# Import the identity and allow codesign to use the private key.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
rm -rf "$TMP"

echo
echo "Created '$IDENTITY'."
echo "If codesign later asks to use the key, click \"Always Allow\" once."
echo "Next: scripts/build-app.sh -x   (it will sign with this identity)"
