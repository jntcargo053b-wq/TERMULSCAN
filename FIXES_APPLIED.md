# Fixes applied

## Watermark/cache
- Added `FileImage(File(publicPath)).evict()` after the recovery watermark burn and before marking the photo task completed.
- Removed the redundant `lib/models/watermark_settings.dart` because no Dart source referenced it.

## GPS — lightweight POD tuning
- Kept the original fast one-shot GPS architecture; no rolling window, Kalman filter, or repeated polling.
- Reduced acceptable last-known age from 120 seconds to 20 seconds.
- A fast cached fix is accepted only when accuracy is <= 20 m.
- Fresh one-shot location is accepted immediately when accuracy is <= 20 m.
- After the original 5-second timeout, only a <= 30 m fix is returned as fallback; otherwise location is null.
- GPS is preferred over network when both recent cached fixes are good.
- Restored the Flutter location cache to 8 seconds because photo capture uses the native `getLocation` channel directly.

## Preview
- The preview flow remains the existing raw-photo preview; final watermark-preview redesign is intentionally not mixed into this lightweight GPS patch.

## GPS light final
- 20m changed from hard failure to quality target.
- 30m is the maximum accepted lightweight POD accuracy.
- Removed stale unused `com/gudang/scanner/MainActivity.kt` if present.
- Kept the original single-update GPS architecture; no heavy lock/filtering.

## GPS/performance fixes v14
- Cached GPS acceptance aligned to the 30m maximum.
- Removed passive provider from capture provider list.
- Preserved lightweight single-update GPS architecture.
- Updated capture quality wording to 30m maximum / 20m target.
- Added shutter timestamp field where the existing camera capture callback permits.

## GPS/light-flow correction v15
- Cached GPS acceptance aligned with the 30m maximum.
- Camera GPS acquisition now starts before the native camera UI opens.
- Camera capture timestamp is recorded immediately before opening the camera.
- Persisted photo/raw-copy files are created only after GPS validation.
- Updated GPS error text to 30m maximum / 20m target.

## Version 17 complete maintenance fixes
- Removed stale root `build.yml`.
- Photo/task recovery now retries on app resume and drains successful watermark tasks even when address lookup is unavailable.
- Burn failure UX distinguishes persisted photos from total capture failures.
- Barcode entry IDs use `StorageService.generateId()`.
- Gallery barcode state update is guarded by `mounted`.
- Search formats dates only after cheap field checks fail.
- `WatermarkSettings.hasLogo` is cached.
- Large history JSON snapshots are encoded off the UI isolate (threshold 300 entries).

## Version 18 correction
- Definitively declared `bool _hasLogo = false;` in `WatermarkSettings`.
- Normalized `hasLogo` getter to use the cached field.
- Removed any stale root `build.yml`.
- Preserved existing `.github/workflows/*` project build flow; legacy `flutter create` commands removed if present.
- Repacked with a clean project root name (`TERMULSCAN-main-18-clean`) to avoid carrying forward the v13 root name.
- Added BUILD_VERIFICATION.md for CI verification.

## Version 19 — address retry completion
- Added explicit watermarkCompleted/addressResolved task state.
- Coordinate-only watermark remains pending when reverse geocoding fails.
- Added automatic retry on cold start, app resume, and every 2 minutes while active.
- Prevented repeated coordinate-only burns while offline.
- Final address burn removes the task only after successful enrichment.

## Version 20 — recovery lifecycle consistency
- Gallery capture now uses `markPhotoWatermarkCompleted(addressResolved: ...)`, matching camera flow.
- Recovery retry timer is started only while the app is resumed/foreground.
- Timer is stopped on paused/inactive/detached and recreated on resume.

## Version 21 — compile fix
- Restored `_gpsMaxAcceptedMeters = 30.0` inside `_PhotoScanScreenState`.
- Kept 20m as quality target and 30m as accepted GPS ceiling.

## Version 22 — GPS constant scope compile fix
- Moved `_gpsQualityTargetMeters` and `_gpsMaxAcceptedMeters` into `_PhotoScanScreenState`.
- Removed the duplicate/incorrect widget-level declaration.
- This fixes the build error where `_gpsMaxAcceptedMeters` was undefined in state methods.

## Version 23 — 30m GPS boundary fix
- Android and Flutter acceptance limits aligned at 30.5m.
- The extra 0.5m is only a floating-point/display boundary tolerance so a fix shown as 30.0m is not rejected due to an internal value such as 30.04m.
- Added GPS capture diagnostic logging (lat/lng/accuracy) for troubleshooting.

## Version 24 — Legacy Light GPS
- Removed hard 20m/30m accuracy capture gating.
- Valid coordinates are sufficient for capture.
- Accuracy remains informational only.
- Kept existing lightweight GPS/address architecture.

## Version 25 — restored legacy-light GPS model
- Removed accuracy thresholds from Android cached/fresh location acceptance.
- Recent last-known GPS/network coordinates are accepted regardless of accuracy.
- Fresh one-shot location returns the first valid coordinate.
- Accuracy is metadata only.
- Added a lightweight 10m address grid cache to speed repeated reverse-geocoding.
- Preserved Nominatim request serialization/throttling.
