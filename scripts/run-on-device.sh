#!/bin/zsh
# Builds Rapid Wallet, installs it on the connected iPhone, and launches it.
# Needs: an Apple ID in Xcode > Settings > Accounts, and a paired iPhone in Developer Mode.
# Usage: scripts/run-on-device.sh            default build, no radio
#        TEAM=XXXXXXXXXX scripts/run-on-device.sh
#        SCHEME=RapidWallet-HCE CONFIG=Debug-HCE scripts/run-on-device.sh    only after Apple grants HCE
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=${TEAM:-B2AA43A5CZ}
SCHEME=${SCHEME:-RapidWallet}
CONFIG=${CONFIG:-Debug}
BUNDLE_ID=dev.scalexy.rapidwallet
DERIVED=/tmp/rw-device-signed

devices=$(mktemp)
xcrun devicectl list devices --quiet --json-output "$devices" >/dev/null
UDID=$(python3 -I -c '
import json, sys
found = [d for d in json.load(open(sys.argv[1]))["result"]["devices"]
         if d["hardwareProperties"].get("reality") == "physical"
         and d["hardwareProperties"].get("platform") == "iOS"]
print(found[0]["hardwareProperties"]["udid"] if found else "")
' "$devices")
rm -f "$devices"

if [[ -z "$UDID" ]]; then
  echo "No iPhone found. Connect it by USB, unlock it, tap Trust, and turn on Developer Mode." >&2
  exit 1
fi

xcodegen generate >/dev/null
xcodebuild -project RapidWallet.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" build | grep -E ' error:|BUILD (SUCCEEDED|FAILED)'

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/RapidWallet.app"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
