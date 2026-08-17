#!/bin/bash
#
# Creates a self-signed code-signing identity, once, so rebuilds stop losing
# their macOS permissions.
#
# Why this is needed: an ad-hoc signature has no stable identity. macOS records
# the exact code hash when you grant Screen Recording or Accessibility, so the
# moment a rebuild changes the binary the grant no longer matches and the app
# is treated as an unknown one — the switches stay on in System Settings while
# the app is quietly denied. Signing with a real certificate gives the app a
# fixed identity, and the grant then survives every rebuild.
#
# The certificate is self-signed and lives only in your login keychain. It
# isn't trusted by anyone else and isn't good for distribution — a Developer ID
# certificate replaces it for release builds. Remove it any time with:
#
#   security delete-certificate -c "Better Mission Control Dev" ~/Library/Keychains/login.keychain-db
#
set -euo pipefail

IDENTITY="Better Mission Control Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Deliberately not `-v`: a self-signed certificate reports as untrusted, so it
# never appears in the "valid identities" list, but codesign will happily sign
# with it — which is all that's needed here.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> '$IDENTITY' already exists — nothing to do"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# macOS's PKCS#12 reader predates OpenSSL 3's defaults (SHA-256 MAC, AES) and
# rejects them as "MAC verification failed", so the bundle is written with the
# older SHA-1/3DES algorithms it understands. A throwaway password is used
# because an empty one trips up some OpenSSL builds.
PASSWORD="bmc-$RANDOM"
openssl pkcs12 -export -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY" -passout "pass:$PASSWORD" \
  -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null \
  || openssl pkcs12 -export -legacy -out "$WORK/identity.p12" \
       -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -name "$IDENTITY" -passout "pass:$PASSWORD" >/dev/null 2>&1

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign plus -A let codesign use the key without prompting for
# the keychain password on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign -A >/dev/null

echo "==> Done."
security find-identity -p codesigning | grep "$IDENTITY" || {
  echo "error: the identity was imported but codesign can't see it." >&2
  echo "Signing will fall back to ad-hoc, and permissions will keep resetting." >&2
  exit 1
}
# "CSSMERR_TP_NOT_TRUSTED" alongside it is expected and harmless: nothing has
# vouched for a certificate you made yourself. Signing doesn't require trust.

cat <<'NOTE'

Next build will be signed with it. One last thing: because the app's identity
has changed, macOS treats it as new, so you'll need to grant Screen Recording
and Accessibility once more. After that they stick across rebuilds.
NOTE
