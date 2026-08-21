# GPS capture policy — lightweight final

- Preserve single-update GPS acquisition; no Kalman/rolling lock.
- 20 m is the preferred quality target, not a hard failure.
- 30 m is the maximum accepted accuracy.
- Cached locations up to 30 m may be used when fresh enough.
- Passive provider is not used for POD capture.
- Capture timestamp is taken at shutter where the camera callback supports it.
- GPS should be obtained before creating the final persisted photo so a failed GPS fix does not leave orphan output files.
