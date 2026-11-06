#!/bin/bash
# Prepares a GitHub runner to sign: a throwaway keychain with both identities, and the API key.
# Expects DEVELOPMENT_P12, DEVELOPMENT_P12_PASSWORD, DISTRIBUTION_P12, DISTRIBUTION_P12_PASSWORD, ASC_KEY.
set -euo pipefail

for name in DEVELOPMENT_P12 DEVELOPMENT_P12_PASSWORD DISTRIBUTION_P12 DISTRIBUTION_P12_PASSWORD ASC_KEY; do
  [ -n "${!name:-}" ] || { echo "::error::$name is empty. Check the APPLE_DEVELOPER_ACCOUNT_* org secrets."; exit 1; }
done

keychain="$RUNNER_TEMP/signing.keychain-db"
password=$(uuidgen)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"

curl -fsSL --retry 3 https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$RUNNER_TEMP/AppleWWDRCAG3.cer"
security import "$RUNNER_TEMP/AppleWWDRCAG3.cer" -k "$keychain"

printf '%s' "$DEVELOPMENT_P12" | base64 --decode > "$RUNNER_TEMP/development.p12"
printf '%s' "$DISTRIBUTION_P12" | base64 --decode > "$RUNNER_TEMP/distribution.p12"
security import "$RUNNER_TEMP/development.p12" -k "$keychain" -P "$DEVELOPMENT_P12_PASSWORD" -T /usr/bin/codesign
security import "$RUNNER_TEMP/distribution.p12" -k "$keychain" -P "$DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign
rm -f "$RUNNER_TEMP/development.p12" "$RUNNER_TEMP/distribution.p12"

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# shellcheck disable=SC2046 # the existing keychains are one path per word
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

identities=$(security find-identity -v -p codesigning "$keychain")
for kind in "Apple Development" "Apple Distribution"; do
  grep -q "$kind" <<< "$identities" || { echo "::error::No $kind identity in the imported .p12 files."; exit 1; }
done

key="$RUNNER_TEMP/AuthKey.p8"
case "$ASC_KEY" in
  *"BEGIN PRIVATE KEY"*) printf '%s\n' "$ASC_KEY" > "$key" ;;
  *) printf '%s' "$ASC_KEY" | base64 --decode > "$key" ;;
esac
chmod 600 "$key"
echo "ASC_KEY_PATH=$key" >> "$GITHUB_ENV"
