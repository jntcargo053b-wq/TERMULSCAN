# GPS policy — lightweight POD

- Preserve the original single-update GPS flow; no Kalman, rolling window, or multi-sample lock.
- 20 m is the preferred quality target, not a hard failure threshold.
- Up to 30 m is accepted so capture remains fast and usable.
- Accuracy above 30 m should not be treated as a good final POD fix.
- GPS remains preferred; network/last-known are fallback only.
- Keep capture path lightweight.
