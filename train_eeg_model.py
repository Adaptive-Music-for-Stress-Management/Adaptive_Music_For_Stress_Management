#!/usr/bin/env python3
"""Train the per-channel Muse stress classifier from the bundled EDF archive.

Only the three requested experiment folders are read:
  relaxing music -> Calm
  complex mathematical problem solving -> Mild-stress
  horror video -> Stressed

The EDF data was recorded at 128 Hz with AF3/T7/Pz/T8/AF4.  Pz and every
non-EEG signal are discarded.  The remaining electrodes train four small,
location-specific Braindecode models for the corresponding Muse 2 channels.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import random
import re
import tempfile
import zipfile

import numpy as np

from eeg_pipeline import (
    CLASS_LABELS,
    MODEL_SAMPLE_RATE,
    MODEL_WINDOW_SAMPLES,
    build_braindecode_model,
    prepare_model_window,
)


ROOT = Path(__file__).resolve().parent
DEFAULT_ARCHIVE = ROOT / "An EEG Recordings Dataset for Mental Stress Detection.zip"
DEFAULT_MODEL = ROOT / "models" / "eeg_stress_eegminer.pt"
DEFAULT_METRICS = ROOT / "models" / "eeg_stress_metrics.json"

SOURCE_CHANNEL_MAP = {
    "left_ear": "T7",
    "left_brain": "AF3",
    "right_brain": "AF4",
    "right_ear": "T8",
}
SOURCE_CHANNELS = tuple(SOURCE_CHANNEL_MAP.values())
CLASS_FOLDERS = {
    "Participants Listening to Relaxing Music": 0,
    "Complex Mathematical Problem solving (CMPS)": 1,
    "Horrer Video Stimulation": 2,  # spelling in the published archive
}


def _subject_id(path: Path) -> int:
    match = re.search(r"\((\d+)\)", path.stem)
    if not match:
        raise ValueError(f"could not read participant number from {path.name}")
    return int(match.group(1))


def _safe_extract_selected(archive: Path, destination: Path) -> list[tuple[Path, int]]:
    selected = []
    with zipfile.ZipFile(archive) as source:
        for info in source.infolist():
            if not info.filename.lower().endswith(".edf"):
                continue
            folder = Path(info.filename).parent.name
            if folder not in CLASS_FOLDERS:
                continue
            target = (destination / info.filename).resolve()
            if destination.resolve() not in target.parents:
                raise ValueError(f"unsafe path in dataset archive: {info.filename}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(info) as input_file, target.open("wb") as output_file:
                while block := input_file.read(1024 * 1024):
                    output_file.write(block)
            selected.append((target, CLASS_FOLDERS[folder]))
    if not selected:
        raise RuntimeError("the three requested EDF folders were not found in the dataset archive")
    return selected


def _recording_windows(path: Path, max_windows: int) -> dict[str, np.ndarray]:
    import mne

    raw = mne.io.read_raw_edf(
        path,
        preload=True,
        include=list(SOURCE_CHANNELS),
        infer_types=False,
        verbose="ERROR",
    )
    missing = [name for name in SOURCE_CHANNELS if name not in raw.ch_names]
    if missing:
        raise ValueError(f"{path.name} is missing EEG channels: {', '.join(missing)}")
    raw.pick(list(SOURCE_CHANNELS))
    sample_rate = float(raw.info["sfreq"])
    if not np.isclose(sample_rate, MODEL_SAMPLE_RATE, atol=0.01):
        raise ValueError(f"{path.name} is {sample_rate:g} Hz; expected 128 Hz")
    # MNE returns volts for EEG channels; the live Muse stream is microvolts.
    data_uv = raw.get_data() * 1_000_000.0
    stride = MODEL_WINDOW_SAMPLES // 2
    starts = list(range(0, data_uv.shape[1] - MODEL_WINDOW_SAMPLES + 1, stride))
    if len(starts) > max_windows:
        indices = np.linspace(0, len(starts) - 1, max_windows, dtype=int)
        starts = [starts[index] for index in indices]
    windows = {}
    for name in SOURCE_CHANNELS:
        channel = data_uv[raw.ch_names.index(name)]
        channel_windows = []
        for start in starts:
            channel_windows.append(prepare_model_window(
                channel[start:start + MODEL_WINDOW_SAMPLES],
                MODEL_SAMPLE_RATE,
            ))
        windows[name] = np.asarray(channel_windows, dtype=np.float32)
    return windows


def _balanced(records, seed: int):
    rng = np.random.default_rng(seed)
    by_class = defaultdict(list)
    for windows, label in records:
        by_class[label].append(windows)
    missing = [index for index in range(len(CLASS_LABELS)) if index not in by_class]
    if missing:
        raise RuntimeError(f"training split is missing classes: {missing}")
    joined = {label: np.concatenate(parts, axis=0) for label, parts in by_class.items()}
    count = min(values.shape[0] for values in joined.values())
    x_parts, y_parts = [], []
    for label in range(len(CLASS_LABELS)):
        values = joined[label]
        choice = rng.choice(values.shape[0], size=count, replace=False)
        x_parts.append(values[choice])
        y_parts.append(np.full(count, label, dtype=np.int64))
    x = np.concatenate(x_parts, axis=0)[:, np.newaxis, :]
    y = np.concatenate(y_parts, axis=0)
    order = rng.permutation(y.size)
    return x[order], y[order]


def build_dataset(archive: Path, max_windows: int, seed: int):
    train_records = {channel: [] for channel in SOURCE_CHANNEL_MAP}
    validation_records = {channel: [] for channel in SOURCE_CHANNEL_MAP}
    with tempfile.TemporaryDirectory(prefix="adaptive-eeg-") as directory:
        files = _safe_extract_selected(archive, Path(directory))
        for index, (path, label) in enumerate(sorted(files)):
            windows = _recording_windows(path, max_windows=max_windows)
            if not windows or any(values.size == 0 for values in windows.values()):
                continue
            # Split by participant, never by overlapping windows from one file.
            destination = validation_records if _subject_id(path) % 5 == 0 else train_records
            for muse_channel, source_channel in SOURCE_CHANNEL_MAP.items():
                destination[muse_channel].append((windows[source_channel], label))
            print(f"[{index + 1:02d}/{len(files)}] {CLASS_LABELS[label]:11s} "
                  f"{path.name:12s} {len(next(iter(windows.values()))):4d} windows/channel")
    return {
        channel: (
            _balanced(train_records[channel], seed + index * 2),
            _balanced(validation_records[channel], seed + index * 2 + 1),
        )
        for index, channel in enumerate(SOURCE_CHANNEL_MAP)
    }


def _train_channel(channel, dataset, args, torch):
    from torch import nn
    from torch.utils.data import DataLoader, TensorDataset

    (x_train, y_train), (x_validation, y_validation) = dataset
    print(f"\n{channel} ({SOURCE_CHANNEL_MAP[channel]}): "
          f"{len(y_train)} training; {len(y_validation)} validation windows")

    device_name = "mps" if torch.backends.mps.is_available() and not args.cpu else "cpu"
    device = torch.device(device_name)
    model = build_braindecode_model(n_outputs=len(CLASS_LABELS)).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-4)
    criterion = nn.CrossEntropyLoss()
    training = DataLoader(
        TensorDataset(torch.from_numpy(x_train), torch.from_numpy(y_train)),
        batch_size=args.batch_size,
        shuffle=True,
    )
    validation = DataLoader(
        TensorDataset(torch.from_numpy(x_validation), torch.from_numpy(y_validation)),
        batch_size=args.batch_size,
        shuffle=False,
    )

    best_accuracy = -1.0
    best_state = None
    history = []
    patience_left = args.patience
    for epoch in range(1, args.epochs + 1):
        model.train()
        loss_total = 0.0
        seen = 0
        for features, targets in training:
            features, targets = features.to(device), targets.to(device)
            optimizer.zero_grad(set_to_none=True)
            loss = criterion(model(features), targets)
            loss.backward()
            optimizer.step()
            loss_total += float(loss.item()) * targets.size(0)
            seen += targets.size(0)

        model.eval()
        correct = 0
        validation_seen = 0
        confusion = np.zeros((len(CLASS_LABELS), len(CLASS_LABELS)), dtype=int)
        with torch.no_grad():
            for features, targets in validation:
                predictions = model(features.to(device)).argmax(dim=1).cpu()
                correct += int((predictions == targets).sum())
                validation_seen += targets.size(0)
                for expected, actual in zip(targets.numpy(), predictions.numpy()):
                    confusion[expected, actual] += 1
        accuracy = correct / max(validation_seen, 1)
        epoch_metrics = {
            "epoch": epoch,
            "training_loss": loss_total / max(seen, 1),
            "validation_accuracy": accuracy,
        }
        history.append(epoch_metrics)
        print(f"{channel:11s} epoch {epoch:02d}  loss={epoch_metrics['training_loss']:.4f}  "
              f"validation_accuracy={accuracy:.3f}")
        if accuracy > best_accuracy:
            best_accuracy = accuracy
            best_state = {name: value.detach().cpu().clone() for name, value in model.state_dict().items()}
            best_confusion = confusion.copy()
            patience_left = args.patience
        else:
            patience_left -= 1
            if patience_left <= 0:
                break

    return best_state, {
        "source_channel": SOURCE_CHANNEL_MAP[channel],
        "training_windows": int(len(y_train)),
        "validation_windows": int(len(y_validation)),
        "validation_accuracy": best_accuracy,
        "confusion_matrix_rows_expected_columns_predicted": best_confusion.tolist(),
        "history": history,
    }


def train(args):
    import torch

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    datasets = build_dataset(
        args.archive,
        max_windows=args.max_windows_per_recording,
        seed=args.seed,
    )
    state_dicts = {}
    channel_metrics = {}
    for channel, dataset in datasets.items():
        state_dicts[channel], channel_metrics[channel] = _train_channel(
            channel, dataset, args, torch
        )

    mean_accuracy = float(np.mean([
        metrics["validation_accuracy"] for metrics in channel_metrics.values()
    ]))
    metadata = {
        "architecture": "Braindecode EEGMiner (five-band magnitude)",
        "n_chans": 1,
        "n_outputs": len(CLASS_LABELS),
        "n_times": MODEL_WINDOW_SAMPLES,
        "sample_rate": MODEL_SAMPLE_RATE,
        "window_seconds": MODEL_WINDOW_SAMPLES / MODEL_SAMPLE_RATE,
        "class_labels": list(CLASS_LABELS),
        "source_channel_map": SOURCE_CHANNEL_MAP,
        "ignored_dataset_folders": ["Stroop Colour Word Test(SCWT)", "Trier Mental Challenge Test (TMCT)"],
        "mean_validation_accuracy": mean_accuracy,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"state_dicts": state_dicts, "metadata": metadata}, args.output)
    metrics = {
        **metadata,
        "channels": channel_metrics,
        "seed": args.seed,
    }
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    print(f"saved model to {args.output}")
    print(f"saved metrics to {args.metrics}")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--metrics", type=Path, default=DEFAULT_METRICS)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--patience", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--learning-rate", type=float, default=1e-2)
    parser.add_argument("--max-windows-per-recording", type=int, default=36)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--cpu", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    train(parse_args())
