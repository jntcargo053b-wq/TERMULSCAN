# TERMULScan build-ready notes

- `pubspec.yaml` restored as Flutter pubspec.
- Android launcher resources normalized to `mipmap-* / ic_launcher.png`.
- CI workflow does not run `flutter create`.
- Android namespace/application id use `com.termulscan.app`.
- Android compile/target SDK normalized to 34.
- Cached/stale GPS last-known locations are rejected when older than 120 seconds or accuracy exceeds 50m.
- Storage folder naming normalized to `TERMULScan`.
- Flutter/GitHub Actions should run `flutter pub get` before building.
