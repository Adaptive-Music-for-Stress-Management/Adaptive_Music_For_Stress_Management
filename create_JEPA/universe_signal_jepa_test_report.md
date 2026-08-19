# Signal-JEPA on UNIVERSE: held-out test report

## Test result

Participant-held-out recording-level balanced accuracy was **0.562** (participant-cluster bootstrap 95% CI 0.400–1.000); ROC AUC was **0.312**.

| Evaluation unit | Accuracy | Balanced accuracy | ROC AUC | AUPRC | F1 | Sensitivity | Specificity | MCC |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Recording (12) | 0.667 | 0.562 | 0.312 | 0.464 | 0.333 | 0.250 | 0.875 | 0.158 |
| 2-second window (1440) | 0.513 | 0.494 | 0.490 | 0.335 | 0.375 | 0.438 | 0.551 | -0.011 |

Decision threshold: `0.493298`, selected using validation recordings only.

Recording confusion matrix (true rows, predicted columns; low then high stress):

`[[7, 1], [3, 1]]`

## Protocol

`braindecode/signal-jepa_without-chans` was loaded as Braindecode `SignalJEPA_PreLocal`. A new four-channel spatial/classification head was trained. The feature encoder was subsequently unfrozen, but validation selection chose epoch 1, so the exported checkpoint retains the original pretrained feature encoder. PreLocal is the checkpoint's downstream classifier variant and does not include the contextual transformer in its forward path.
The source was the supplied UNIVERSE UN_101--UN_112 ZIP. Only Wild-session folders labeled `vlw`/`low` (low stress) or `hig`/`vhg` (high stress) were included; `nor`, calibration, and controlled-lab task-difficulty recordings were excluded.
The archive's preprocessed TP9, AF7, AF8, and TP10 EEG was resampled from 256 to 128 Hz. Non-overlapping 2-second windows were standardized independently per channel/window. At most 120 evenly spaced windows were retained per recording.

- Train: ['UN_101', 'UN_104', 'UN_105', 'UN_106', 'UN_108', 'UN_109', 'UN_112']
- Validation: ['UN_102', 'UN_110']
- Test: ['UN_107', 'UN_111']

## Limitations

This is a small extreme-group evaluation: 62 recordings from 11 participants were eligible, and the held-out test set contains only two participants. Neutral stress was excluded, the archive is only the UN_101--UN_112 half of UNIVERSE, and windows from one recording are correlated. Recording-level metrics are therefore primary; window-level metrics are secondary.

This experimental classifier is not a medical diagnostic.
