# Fixes applied

1. Added Flutter ImageCache eviction after the recovery watermark burn rewrites the same publicPath.
2. Removed redundant `lib/models/watermark_settings.dart` when no imports referenced it.
3. Marked the raw-image preview flow for follow-up; the preview currently occurs before final watermark burn.

4. Reworked Android GPS acquisition for POD: fresh multi-sample lock, 5-sample rolling window, 3-sample stability cluster within 15 m, weighted centroid, GPS provider priority, 20 s last-known limit, and 7 s acquisition timeout.
5. Photo capture now requires GPS accuracy <=20 m before committing/burning the watermark; stale/poor GPS is rejected instead of writing misleading coordinates.
6. Capture coordinate requests bypass the Dart location cache; UI/address cache remains short-lived.
