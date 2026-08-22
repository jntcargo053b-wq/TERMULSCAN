# GPS Capture Policy — Legacy Light (final)

1. Do not hard-block capture by GPS accuracy.
2. A valid latitude/longitude is sufficient to capture.
3. Use recent OS last-known GPS/network location first for speed.
4. If no recent last-known position exists, request a single fresh update.
5. Accept the first valid fresh coordinate; accuracy is metadata only.
6. Reverse-geocode immediately from the available coordinate.
7. Use a small address grid cache to make repeated Kecamatan/Kota lookups fast.
8. Fresh GPS can update the coordinate/address later; no Kalman, rolling lock,
   multi-sample gate, or accuracy threshold is introduced.
