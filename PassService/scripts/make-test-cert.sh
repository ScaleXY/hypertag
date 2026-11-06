#!/bin/sh
# Creates throwaway signing credentials in a new temp directory, for tests only.
# Wallet rejects passes signed with these, because they don't chain to Apple. Never commit the output.
#
# Prints PASS_CERT_PEM, PASS_KEY_PEM and WWDR_CERT_PEM as shell assignments:
#   eval "$(scripts/make-test-cert.sh)"
# TEST_PASS_TYPE_ID and TEST_TEAM_ID override the identity baked into the certificate.
set -eu

pass_type_id="${TEST_PASS_TYPE_ID:-pass.dev.scalexy.rapidwallet.tag}"
team_id="${TEST_TEAM_ID:-B2AA43A5CZ}"

directory="$(mktemp -d "${TMPDIR:-/tmp}/rapid-pass-test-cert.XXXXXX")"
chmod 700 "$directory"
cd "$directory"

# The self-signed certificate stands in for WWDR, so the chain has the same shape as a real one.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout wwdr-key.pem -out wwdr.pem \
    -subj "/CN=Rapid Wallet TEST ONLY fake WWDR/O=ScaleXY test" 2>/dev/null

openssl req -newkey rsa:2048 -nodes \
    -keyout pass-key.pem -out pass.csr \
    -subj "/UID=$pass_type_id/CN=Pass Type ID: $pass_type_id/OU=$team_id/O=ScaleXY test/C=US" 2>/dev/null

cat > pass.ext <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
EXT

openssl x509 -req -days 2 -in pass.csr \
    -CA wwdr.pem -CAkey wwdr-key.pem -CAcreateserial \
    -extfile pass.ext -out pass-cert.pem 2>/dev/null

rm -f wwdr-key.pem pass.csr pass.ext wwdr.srl
chmod 600 pass-key.pem

echo "Test credentials only: Wallet will reject passes signed with these." >&2
echo "export PASS_CERT_PEM='$directory/pass-cert.pem'"
echo "export PASS_KEY_PEM='$directory/pass-key.pem'"
echo "export WWDR_CERT_PEM='$directory/wwdr.pem'"
