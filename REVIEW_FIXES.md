# Deep Review Fixes

## GPS
- 20 m remains the preferred quality target.
- 20–30 m is accepted immediately by the native single-update GPS path.
- Last-known location is limited to 20 seconds and 30 m accuracy.
- Passive provider is not used.
- No Kalman, rolling window, or multi-sample GPS lock was added.

## Capture / Preview
- Camera timestamp is captured immediately after the native camera returns the image file (the earliest reliable point available with ImagePicker).
- GPS acquisition starts after capture, avoiding a fix that predates the photo.
- A temporary watermarked preview is generated before GUNAKAN/ULANGI.
- GPS is validated before any persisted photo is created.

## Persistence / Recovery
- Orphan persisted files are cleaned up when save/add-task fails before a recovery task exists.
- Normal successful captures do one final persisted watermark burn; recovery is reserved for incomplete tasks.
- If reverse geocoding is unavailable, the coordinate-watermarked photo remains valid and the pending task can retry address enrichment later.
- Recovery tasks stop after 3 failed recovery attempts and one broken task no longer blocks later pending tasks.
- Missing public/raw files consume a recovery attempt and are marked retry-exhausted after 3 attempts.
- Flutter ImageCache eviction remains in recovery after the public file is rewritten.

## CI
- Removed `flutter create` and repository mutation from GitHub Actions so checked-in native Android files are not regenerated or overwritten during builds.
- CI now verifies the checked-in Gradle wrapper before building.

## Validation
- ZIP archive passes `zipfile.testzip()`.
- Static source sanity checks passed for brace/parenthesis/bracket balance in the modified Dart files.
- Flutter/Dart SDK is not installed in this execution environment, so `flutter analyze` and `flutter build apk` could not be executed locally.

## Final recheck hardening — 28 Aug 2026

- Prevented successful photo captures from being watermark-processed twice: the capture path now marks its persisted recovery task complete immediately after a successful watermark.
- Recovery remains pending only when watermark processing fails or task-state persistence cannot be completed.
- Removed the now-unused direct recovery trigger from `PhotoScanScreen`; recovery is handled at app startup from persisted pending tasks.


## Final hardening — address pipeline (28 Aug 2026)

Restored reverse-geocoding to the normal capture path. Photo tasks now persist independent `watermarkCompleted` and `addressResolved` states, allowing address retry without watermark stacking. Address retry is triggered at cold start, app resume, and every 2 minutes, with a 3-attempt ceiling. Recovery always uses the immutable RAW photo as its watermark source.
