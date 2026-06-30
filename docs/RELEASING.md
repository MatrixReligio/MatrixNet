# Releasing MatrixNet

MatrixNet ships as a Developer ID–signed, notarized `.dmg` and updates itself
in place via [Sparkle](https://sparkle-project.org). This document describes how
a maintainer cuts a release and the secrets the automation needs.

## Overview

A release is produced by [`scripts/release.sh`](../scripts/release.sh), which:

1. builds the app (Release, unsigned),
2. signs it inside-out with Developer ID + Hardened Runtime
   ([`scripts/sign.sh`](../scripts/sign.sh) — including Sparkle's nested XPC
   services, `Updater.app`, `Autoupdate`, and the framework),
3. packages a `.dmg`, notarizes it, and staples the ticket,
4. generates an **EdDSA-signed Sparkle appcast** (`dist/appcast.xml`) whose
   enclosure points at the GitHub release asset.

You can run it locally (`./scripts/release.sh 0.1.0`) with the signing identity
and notary profile in your login keychain, or via the **Release** GitHub Actions
workflow (`workflow_dispatch`).

## Versioning

Bump `MARKETING_VERSION` / `CFBundleShortVersionString` and the integer
`CURRENT_PROJECT_VERSION` / `CFBundleVersion` in [`project.yml`](../project.yml).
Sparkle compares `CFBundleVersion`, so it **must increase every release**.

## Required GitHub secrets (Release workflow)

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_CERT_P12` / `DEVELOPER_ID_CERT_PASSWORD` | Developer ID Application certificate (base64 `.p12`) for code signing |
| `KEYCHAIN_PASSWORD` | Password for the ephemeral CI keychain |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8` | App Store Connect API key (base64 `.p8`) for `notarytool`. Must be a **Team** key — an Individual key cannot notarize |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (the base64 string printed by `generate_keys -x`) used to sign the appcast |

The matching Sparkle **public** key is embedded in the app's `Info.plist` as
`SUPublicEDKey`. Keep the private key safe and **out of the repository** — losing
it means existing installs can no longer verify updates.

### Generating the Sparkle key pair (one time)

```sh
# From the Sparkle distribution's bin/ tools:
./generate_keys                 # creates the key in your login keychain, prints SUPublicEDKey
./generate_keys -x sparkle_private_key.pem   # export the private key for the CI secret
```

Put `SUPublicEDKey` in `project.yml` and the exported private key in the
`SPARKLE_PRIVATE_KEY` secret.

## The appcast feed

`SUFeedURL` points at `https://github.com/MatrixReligio/MatrixNet/releases/latest/download/appcast.xml`
— GitHub serves the latest release's `appcast.xml` asset at that stable URL, so
each release simply uploads a fresh `appcast.xml` alongside the `.dmg`.

## GeoIP rolling release

The [`geoip-update`](../.github/workflows/geoip-update.yml) workflow runs monthly
(and on demand). It rebuilds `geoip.dat` from the latest DB-IP Country Lite
dataset and republishes it as the rolling **`geoip-latest`** release asset, which
the app downloads in the background. No secrets are required beyond the default
`GITHUB_TOKEN`.

> Attribution (CC-BY-4.0): IP Geolocation by DB-IP (https://db-ip.com).

## Verifying a release

```sh
xcrun stapler validate dist/MatrixNet-<version>.dmg

# Assess the app *inside* the DMG, not the DMG file: a DMG is notarized + stapled,
# not code-signed, so a direct `spctl` of the .dmg reports "no usable signature"
# even for a perfectly valid release.
MOUNT="$(mktemp -d)"
hdiutil attach dist/MatrixNet-<version>.dmg -nobrowse -quiet -mountpoint "$MOUNT"
spctl -a -t exec -vvv "$MOUNT/MatrixNet.app"
hdiutil detach "$MOUNT" -quiet
```

`stapler validate` must succeed and the app assessment must report
`accepted` / `source=Notarized Developer ID` for Gatekeeper to open the app
without warnings. (`scripts/release.sh` runs both checks and now fails the
release if the app is rejected.)
