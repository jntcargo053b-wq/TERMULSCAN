# TERMULScan Fixed Debug Signing

This repository contains `android/debug-fixed.keystore` for **testing and CI only**.

The release build type intentionally uses this fixed debug identity so every CI testing APK has the same signature and can update a previously installed testing APK without a GitHub Actions secret.

## Identity

- Keystore: `android/debug-fixed.keystore`
- Alias: `termulscan-debug`
- Store/key password: `termulscan-debug`
- Application ID: `com.termulscan.app`

## Important

This key is public/repository data and is **not a production secret**. Do not use it for public production releases. A separate private production keystore must be used for production distribution.

If the testing keystore is intentionally replaced, all existing testing APKs signed by the old key must be uninstalled before installing APKs signed by the new key.
