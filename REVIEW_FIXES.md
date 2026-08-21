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
- Recovery tasks stop after 3 failed attempts and one broken task no longer blocks later pending tasks.
- Missing public/raw files are removed from the pending queue to avoid infinite retries.
- Flutter ImageCache eviction remains in recovery after the public file is rewritten.

## CI
- Removed `flutter create` from GitHub Actions so checked-in native Android files are not regenerated or overwritten during builds.
- CI now verifies the checked-in Gradle wrapper before building.

## Validation
- ZIP archive passes `zipfile.testzip()`.
- Static source sanity checks passed for brace/parenthesis/bracket balance in the modified Dart files.
- Flutter/Dart SDK is not installed in this execution environment, so `flutter analyze` and `flutter build apk` could not be executed locally.
