#!/bin/bash
# Archives Rapid Wallet once, then exports it for each target.
# Usage: scripts/ci/archive-and-export.sh <testflight-internal|development|both>
#
# On a runner, ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID authenticate with App Store Connect.
# On a Mac without them, the account in Xcode is used, and NO_UPLOAD=1 exports without uploading.
# Automatic signing regenerates profiles, so development builds cover every registered device.
set -euo pipefail
cd "$(dirname "$0")/../.."

target=${1:?Usage: archive-and-export.sh <testflight-internal|development|both>}
case "$target" in testflight-internal|development|both) ;; *) echo "Unknown target: $target" >&2; exit 2 ;; esac

TEAM_ID=${TEAM_ID:-B2AA43A5CZ}
BUILD_NUMBER=${BUILD_NUMBER:-1}
OUT=${OUT:-build}
archive="$OUT/RapidWallet.xcarchive"

auth=(-allowProvisioningUpdates)
if [ -n "${ASC_KEY_PATH:-}" ]; then
  auth+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodegen generate
rm -rf "$archive"
xcodebuild archive -project RapidWallet.xcodeproj -scheme RapidWallet -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -skipPackagePluginValidation -skipMacroValidation "${auth[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

export_app() { # name, method, destination, internal-only
  local plist="$OUT/ExportOptions-$1.plist"
  rm -f "$plist"
  buddy() { /usr/libexec/PlistBuddy -c "$1" "$plist" >/dev/null; }
  buddy "Add :method string $2"
  buddy "Add :destination string $3"
  buddy "Add :teamID string $TEAM_ID"
  buddy "Add :signingStyle string automatic"
  buddy "Add :manageAppVersionAndBuildNumber bool false"
  [ "$4" = "internal" ] && buddy "Add :testFlightInternalTestingOnly bool true"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$plist" \
    -exportPath "$OUT/export/$1" "${auth[@]}"
}

if [ "$target" != "testflight-internal" ]; then
  export_app development debugging export -
fi
if [ "$target" != "development" ]; then
  if [ -n "${NO_UPLOAD:-}" ]; then
    export_app testflight-internal app-store-connect export internal
  else
    export_app testflight-internal app-store-connect upload internal
  fi
fi
