#!/bin/bash
# Creates a self-signed code-signing identity named "Flit Dev" in the login
# keychain. A stable identity keeps the Accessibility / Screen Recording
# grants across rebuilds (ad-hoc signatures change on every build).
set -euo pipefail

NAME="Flit Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:flit -out "$TMP/flit.p12" >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:flit -out "$TMP/flit.p12"

security import "$TMP/flit.p12" -k "$KEYCHAIN" -P flit -T /usr/bin/codesign -T /usr/bin/security
# Trust the cert for code signing. This may show a GUI prompt once.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || {
  echo "Could not mark the certificate trusted automatically."
  echo "Open Keychain Access, find \"$NAME\", and set Code Signing to Always Trust."
}

security find-identity -v -p codesigning | grep "$NAME" || {
  echo "Identity not visible yet; you may need to trust it in Keychain Access."; exit 1; }
echo "Created identity \"$NAME\"."
