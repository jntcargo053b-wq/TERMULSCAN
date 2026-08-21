# Address enrichment retry

Recovery has two independent completion states:
- watermarkCompleted: coordinate/timestamp watermark exists.
- addressResolved: reverse-geocoded address has been resolved and burned.

When network/geocoding is unavailable, the coordinate-only watermark remains
valid and the recovery task stays pending for address enrichment. Recovery does
not repeatedly burn the same coordinate-only image.

Retry is lightweight:
- cold start
- app resume
- every 2 minutes while app is active

When an address becomes available, the image is burned once with the address,
Flutter ImageCache is evicted, the entry is updated, and the recovery task is
removed.
