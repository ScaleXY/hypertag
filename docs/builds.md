# Builds

## On GitHub

Run **Distribute** from the Actions tab, or:

```sh
gh workflow run distribute.yml --repo ScaleXY/hypertag -f target=both
```

| Target | Result |
|---|---|
| `testflight-internal` | Uploads to App Store Connect, for internal TestFlight testers only |
| `development` | An `.ipa` artifact that runs on devices registered with the team |
| `both` | One archive, exported both ways |

Each run regenerates its profiles, so devices registered in the developer portal are included in the next build.

To install a development build on a connected iPhone:

```sh
gh run download <run-id> --repo ScaleXY/hypertag
xcrun devicectl device install app --device <udid> RapidWallet-development-<n>/RapidWallet.ipa
```

**This repo is public.** Anyone signed in to GitHub can download artifacts and read logs, and the `.ipa` lists registered device UDIDs in its embedded profile. Artifacts are kept for 7 days. Make the repo private if that's not acceptable.

## On a Mac

Sign in under Xcode > Settings > Accounts, then either:

```sh
scripts/run-on-device.sh                                       # build, install, and launch on a connected iPhone
OUT=/tmp/rw NO_UPLOAD=1 scripts/ci/archive-and-export.sh both  # the same exports as GitHub, without uploading
```

## What these builds can do

Release and TestFlight builds have no card emulation entitlement, so **Present** stays disabled and **Test Reader** is the way to exercise a tag. Apple also bars TestFlight testers outside the EEA from HCE, even with the entitlement. The `RapidWallet-HCE` scheme is for a development build, once Apple grants it.
