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
