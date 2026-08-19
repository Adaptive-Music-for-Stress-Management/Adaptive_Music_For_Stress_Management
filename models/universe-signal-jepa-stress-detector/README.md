---
library_name: braindecode
license: bsd-3-clause
tags:
- eeg
- signal-jepa
- stress-classification
- universe-dataset
---

# Signal-JEPA UNIVERSE stress classifier

This is a two-class Braindecode `SignalJEPA_PreLocal` checkpoint trained from
`braindecode/signal-jepa_without-chans` on the Wild portion of UNIVERSE
participants UN_101--UN_112.

- Input: TP9, AF7, AF8, TP10 at 128 Hz, 256 samples (2 seconds)
- Class 0: very-low or low self-reported stress
- Class 1: high or very-high self-reported stress
- Excluded: neutral stress, calibration, Lab1, and Lab2

The classification head was trained for five warm-up epochs and the pretrained
feature encoder was then unfrozen. Validation checkpoint selection chose epoch
1, so this exported checkpoint contains the pretrained feature encoder plus the
trained four-channel spatial/classification head.

On 12 recordings from the two participant-held-out test subjects (UN_107 and
UN_111), recording-level balanced accuracy was 0.5625 and ROC AUC was 0.3125.
The decision threshold (0.493298) was selected on separate validation subjects.
See `../../create_JEPA/universe_signal_jepa_test_report.md` and
`../../create_JEPA/universe_signal_jepa_test_metrics.json` for the protocol and full metrics.

This is an experimental research model, not a medical diagnostic.
