# Create and evaluate the UNIVERSE Signal-JEPA classifier

This folder contains the files produced to fine-tune and test
`braindecode/signal-jepa_without-chans` on the Wild-session stress labels from
UNIVERSE participants UN_101--UN_112.

## Contents

- `train_universe_signal_jepa.py`: preprocessing, participant splitting,
  training, validation-only checkpoint/threshold selection, and final testing
- `universe_signal_jepa_test_metrics.json`: complete machine-readable protocol,
  training history, predictions, and metrics
- `universe_signal_jepa_test_report.md`: concise held-out test report
- `model/`: selected checkpoint, Braindecode configuration, and model card
- `requirements.txt`: core package versions used for the run

The two weight files in `model/` contain the same selected checkpoint in
Safetensors and legacy PyTorch formats. Prefer `model.safetensors`.

## Dataset protocol

- Low stress: Wild folders beginning with `vlw_stress` or `low_stress`
- High stress: Wild folders beginning with `hig_stress` or `vhg_stress`
- Excluded: neutral stress, calibration/eye-closing, Lab1, and Lab2
- Train participants: UN_101, UN_104, UN_105, UN_106, UN_108, UN_109, UN_112
- Validation participants: UN_102, UN_110
- Held-out test participants: UN_107, UN_111

Inputs are the archive's preprocessed TP9, AF7, AF8, and TP10 channels,
resampled from 256 Hz to 128 Hz and divided into non-overlapping two-second
windows. The decision threshold is selected from validation recordings only.

## Reproduce the run

Use Python 3.12 and install the core dependencies:

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Download the MIT-licensed upstream checkpoint from
<https://huggingface.co/braindecode/signal-jepa_without-chans>, then run:

```bash
python train_universe_signal_jepa.py \
  --archive /path/to/UNIVERSE_UN_101_to_UN_112.zip \
  --pretrained /path/to/signal-jepa_without-chans \
  --output model \
  --metrics universe_signal_jepa_test_metrics.json \
  --report universe_signal_jepa_test_report.md
```

The preprocessing cache is generated locally and is intentionally not stored
in Git. The 9.5 GB UNIVERSE archive is also not included.

## Reported held-out result

- Recording balanced accuracy: 0.5625
- Recording ROC AUC: 0.3125
- Recording F1: 0.3333
- Window balanced accuracy: 0.4943
- Window ROC AUC: 0.4897

These results do not demonstrate reliable cross-participant stress detection.
The test set contains only two participants, so the estimates are highly
uncertain. This model is experimental and is not a medical diagnostic.

## Integrity

SHA-256 of `model/model.safetensors`:

`183c271248d7c73199d2631c2a82e8b6beee906976be24c0d8dc3478c11fc9ff`
