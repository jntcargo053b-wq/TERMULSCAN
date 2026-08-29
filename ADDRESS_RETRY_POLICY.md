# Address enrichment retry

Recovery has two independent completion states:
- `watermarkCompleted`: the photo has a valid timestamp/coordinate-or-address watermark.
- `addressResolved`: the capture coordinates have been reverse-geocoded successfully and the address has been burned into the visible watermark.

## Normal capture
- Reverse-geocoding is attempted immediately after capture.
- The active capture waits up to 3 seconds for the address so normal field use does not stall for 10 seconds on a weak network.
- If the lookup fails or times out, the first watermark uses coordinates and the persisted task remains pending for address enrichment.

## Retry lifecycle
- cold start
- app resume
- every 2 minutes while the app is active
- maximum 3 processing attempts per pending task

When an address becomes available after a coordinate-only watermark, recovery always reads the immutable RAW capture and burns the complete watermark to the public image. It never burns on top of an already watermarked public image.

After successful address enrichment, the entry is updated and the pending task is removed. If the task reaches the retry limit or its RAW source is permanently unavailable, the pending task is also removed so failed tasks cannot accumulate forever. The photo/history entry is retained.
