# Changelog

## 2.0.0 (first public release)

- TajweedFormer V4: `TajweedModel` loads a signed `sdk/v4.0` folder; `TajweedRecognizer` streams
  audio through the Neural Engine or the exact engine and keeps every head of the network;
  `score(surah:ayah:)` returns per-site tajweed verdicts with their evidence.
- Tajweed settings in three layers (app code, the portal's block, `calibration.json`), identical in
  every TajweedFormer SDK.
- Exact backend: the 35 conformance clips give the engine's expected outputs, every output of every
  chunk, through this SDK's own API. Neural Engine backend: token-identical to the reference on the
  35 conformance clips in every shipped context (greedy tokens of log_probs, checked on Apple silicon Macs).
- SwiftPM package, product and module `TajweedFormer`; iOS 15+, macOS 12+.
