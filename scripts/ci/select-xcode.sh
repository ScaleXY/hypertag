#!/bin/bash
# Selects the newest Xcode 27 on the runner, so builds don't depend on the image's default.
set -euo pipefail
app=$(ls -d /Applications/Xcode_27*.app 2>/dev/null | grep -v -i beta | sort -V | tail -1 || true)
[ -n "$app" ] && sudo xcode-select -s "$app"
xcodebuild -version
