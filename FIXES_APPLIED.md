# Fixes applied

1. Added Flutter ImageCache eviction after the recovery watermark burn rewrites the same publicPath.
2. Removed redundant `lib/models/watermark_settings.dart` when no imports referenced it.
3. Marked the raw-image preview flow for follow-up; the preview currently occurs before final watermark burn.
