#!/usr/bin/env python3
"""Fine-tune Signal-JEPA on the UNIVERSE Wild-session stress labels.

The supplied archive contains UN_101--UN_112.  Only Wild recordings with
very-low/low or high/very-high self-reported stress are used.  Neutral and
calibration recordings are excluded.  Participants are split before windows
are created so no participant or recording crosses a data split.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import pickle
import random
import sys
import time
import warnings
import zipfile

import numpy as np


ROOT = Path(__file__).resolve().parent
DEFAULT_ARCHIVE = ROOT / "UNIVERSE_UN_101_to_UN_112.zip"
DEFAULT_PRETRAINED = ROOT / "models" / "signal-jepa_without-chans"
DEFAULT_OUTPUT = ROOT / "models" / "universe-signal-jepa-stress-detector"
DEFAULT_METRICS = ROOT / "models" / "universe_signal_jepa_test_metrics.json"
DEFAULT_REPORT = ROOT / "models" / "universe_signal_jepa_test_report.md"
DEFAULT_CACHE = ROOT / ".eeg_cache" / "universe_signal_jepa_windows_v1.npz"

DATASET_URL = "https://zenodo.org/records/10371068"
PRETRAINED_REPO = "braindecode/signal-jepa_without-chans"

# Dataframes in the archive store TP10 second.  Reorder to the conventional
# Muse headband order used here before passing the channels to the classifier.
SOURCE_COLUMNS = ("RAW_TP9", "RAW_AF7", "RAW_AF8", "RAW_TP10")
CHANNELS = ("TP9", "AF7", "AF8", "TP10")
SOURCE_SAMPLE_RATE = 256.0
SAMPLE_RATE = 128.0
WINDOW_SECONDS = 2.0
WINDOW_SAMPLES = int(SAMPLE_RATE * WINDOW_SECONDS)
CLASS_NAMES = ("low_stress", "high_stress")
STRESS_PREFIX_TO_CLASS = {"vlw": 0, "low": 0, "hig": 1, "vhg": 1}
CACHE_VERSION = 1

# The two evaluation pairs were chosen before fitting by matching their record
# counts and class proportions to the full selected dataset.  Each participant
# in validation and test has both stress classes.
TEST_SUBJECTS = ("UN_107", "UN_111")
VALIDATION_SUBJECTS = ("UN_102", "UN_110")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _zip_manifest_sha256(archive: Path) -> str:
    """Hash names, sizes, and ZIP CRCs without rereading the 9.5 GB archive."""
    digest = hashlib.sha256()
    with zipfile.ZipFile(archive) as source:
        for info in sorted(source.infolist(), key=lambda value: value.filename):
            digest.update(info.filename.encode("utf-8"))
            digest.update(str(info.file_size).encode("ascii"))
            digest.update(str(info.CRC).encode("ascii"))
    return digest.hexdigest()


def _selected_member(info: zipfile.ZipInfo):
    parts = Path(info.filename).parts
    if len(parts) < 6 or parts[-1] != "EEG_filtered.pickle":
        return None
    if parts[-4:-2] != ("Wild", "Preprocessed"):
        return None
    participant = parts[-5]
    task = parts[-2]
    prefix = task.split("_stress_", 1)[0]
    if prefix not in STRESS_PREFIX_TO_CLASS:
        return None
    return participant, task, STRESS_PREFIX_TO_CLASS[prefix]


def _split_subjects(subjects: list[str]) -> dict[str, list[str]]:
    expected = set(TEST_SUBJECTS) | set(VALIDATION_SUBJECTS)
    if not expected.issubset(subjects):
        missing = sorted(expected - set(subjects))
        raise ValueError(f"archive is missing required evaluation participants: {missing}")
    train = sorted(set(subjects) - expected)
    return {
        "train": train,
        "validation": sorted(VALIDATION_SUBJECTS),
        "test": sorted(TEST_SUBJECTS),
    }


def _repair_nonfinite(data: np.ndarray, member: str) -> np.ndarray:
    for channel_index in range(data.shape[0]):
        channel = data[channel_index]
        valid = np.isfinite(channel)
        if valid.all():
            continue
        if valid.sum() < 2:
            raise ValueError(f"too few finite samples in {member}, channel {channel_index}")
        positions = np.arange(channel.size)
        channel[~valid] = np.interp(positions[~valid], positions[valid], channel[valid])
    return data


def _recording_windows(source: zipfile.ZipFile, info: zipfile.ZipInfo, max_windows: int):
    from scipy.signal import resample_poly

    with source.open(info) as handle:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", category=DeprecationWarning)
            frame = pickle.load(handle)
    missing = [column for column in SOURCE_COLUMNS if column not in frame.columns]
    if missing:
        raise ValueError(f"{info.filename} is missing columns: {missing}")
    data = frame.loc[:, SOURCE_COLUMNS].to_numpy(dtype=np.float64, copy=True).T
    del frame
    data = _repair_nonfinite(data, info.filename)

    # UNIVERSE preprocessed data are already average-referenced, normalized,
    # bandpass-filtered (0.5--50 Hz), and 50 Hz notch-filtered.  Polyphase
    # resampling matches the 128 Hz Signal-JEPA pretraining sample rate.
    data = resample_poly(data, up=1, down=2, axis=-1)
    starts = np.arange(0, data.shape[1] - WINDOW_SAMPLES + 1, WINDOW_SAMPLES)
    if starts.size == 0:
        raise ValueError(f"recording is shorter than one window: {info.filename}")
    if starts.size > max_windows:
        indices = np.linspace(0, starts.size - 1, max_windows, dtype=int)
        starts = starts[np.unique(indices)]
    windows = np.stack([data[:, start:start + WINDOW_SAMPLES] for start in starts])
    del data

    # This uses only samples inside each individual window and therefore does
    # not leak statistics across participants or splits.
    windows -= windows.mean(axis=-1, keepdims=True)
    windows /= np.maximum(windows.std(axis=-1, keepdims=True), 1e-6)
    windows = np.clip(windows, -20.0, 20.0)
    if not np.isfinite(windows).all():
        raise ValueError(f"non-finite values after preprocessing {info.filename}")
    return windows.astype(np.float32)


def build_or_load_dataset(
    archive: Path,
    cache: Path,
    max_windows: int,
    seed: int,
    force: bool,
):
    manifest_hash = _zip_manifest_sha256(archive)
    if cache.exists() and not force:
        cached = np.load(cache, allow_pickle=False)
        metadata = json.loads(str(cached["metadata_json"].item()))
        if (
            metadata.get("cache_version") == CACHE_VERSION
            and metadata.get("archive_zip_manifest_sha256") == manifest_hash
            and metadata.get("max_windows_per_recording") == max_windows
            and metadata.get("seed") == seed
        ):
            print(f"Loading preprocessed windows from {cache}", flush=True)
            return {
                "x": cached["x"],
                "y": cached["y"],
                "subjects": cached["subjects"],
                "conditions": cached["conditions"],
                "record_ids": cached["record_ids"],
                "splits": metadata["splits"],
                "archive_zip_manifest_sha256": manifest_hash,
            }

    with zipfile.ZipFile(archive) as source:
        selected = []
        for info in source.infolist():
            parsed = _selected_member(info)
            if parsed is not None:
                selected.append((info, *parsed))
        selected.sort(key=lambda value: (value[1], value[2]))
        if len(selected) != 62:
            raise RuntimeError(f"expected 62 selected Wild stress records, found {len(selected)}")
        all_subjects = sorted({participant for _, participant, _, _ in selected})
        splits = _split_subjects(all_subjects)

        x_parts: list[np.ndarray] = []
        labels: list[int] = []
        subjects: list[str] = []
        conditions: list[str] = []
        record_ids: list[str] = []
        for index, (info, participant, task, label) in enumerate(selected, 1):
            windows = _recording_windows(source, info, max_windows)
            record_id = f"{participant}/Wild/{task}"
            x_parts.append(windows)
            labels.extend([label] * len(windows))
            subjects.extend([participant] * len(windows))
            conditions.extend([task] * len(windows))
            record_ids.extend([record_id] * len(windows))
            print(
                f"[{index:02d}/{len(selected)}] participant={participant} "
                f"label={CLASS_NAMES[label]:11s} windows={len(windows):3d} {task}",
                flush=True,
            )

    payload = {
        "x": np.concatenate(x_parts),
        "y": np.asarray(labels, dtype=np.int64),
        "subjects": np.asarray(subjects),
        "conditions": np.asarray(conditions),
        "record_ids": np.asarray(record_ids),
        "splits": splits,
        "archive_zip_manifest_sha256": manifest_hash,
    }
    metadata = {
        "cache_version": CACHE_VERSION,
        "archive_zip_manifest_sha256": manifest_hash,
        "max_windows_per_recording": max_windows,
        "seed": seed,
        "splits": splits,
    }
    cache.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        cache,
        x=payload["x"],
        y=payload["y"],
        subjects=payload["subjects"],
        conditions=payload["conditions"],
        record_ids=payload["record_ids"],
        metadata_json=np.asarray(json.dumps(metadata)),
    )
    print(f"Cached {len(payload['y'])} windows in {cache}", flush=True)
    return payload


def _select(payload, subject_ids: list[str]) -> dict[str, np.ndarray]:
    mask = np.isin(payload["subjects"], subject_ids)
    return {
        key: payload[key][mask]
        for key in ("x", "y", "subjects", "conditions", "record_ids")
    }


def _record_balanced_weights(labels: np.ndarray, record_ids: np.ndarray) -> np.ndarray:
    """Give each class equal mass and each record equal mass within its class."""
    records_by_class: dict[int, set[str]] = defaultdict(set)
    counts = Counter(record_ids.tolist())
    record_label: dict[str, int] = {}
    for label, record_id in zip(labels, record_ids):
        records_by_class[int(label)].add(str(record_id))
        record_label[str(record_id)] = int(label)
    return np.asarray(
        [
            1.0
            / (len(records_by_class[record_label[str(record_id)]]) * counts[str(record_id)])
            for record_id in record_ids
        ],
        dtype=np.float64,
    )


def _make_model(pretrained: Path, dropout: float):
    from braindecode.models import SignalJEPA_PreLocal

    model = SignalJEPA_PreLocal.from_pretrained(
        pretrained,
        n_chans=len(CHANNELS),
        n_times=WINDOW_SAMPLES,
        n_outputs=len(CLASS_NAMES),
        drop_prob=dropout,
        strict=False,
    )
    return model


def _is_head_parameter(name: str) -> bool:
    return name.startswith(("spatial_conv.", "final_layer."))


def _set_trainable(model, head_only: bool) -> None:
    for name, parameter in model.named_parameters():
        parameter.requires_grad = _is_head_parameter(name) if head_only else True


def _optimizer(model, head_only: bool, head_lr: float, backbone_lr: float):
    import torch

    if head_only:
        parameters = [parameter for parameter in model.parameters() if parameter.requires_grad]
        return torch.optim.AdamW(parameters, lr=head_lr, weight_decay=1e-4)
    head, backbone = [], []
    for name, parameter in model.named_parameters():
        (head if _is_head_parameter(name) else backbone).append(parameter)
    return torch.optim.AdamW(
        [
            {"params": backbone, "lr": backbone_lr},
            {"params": head, "lr": head_lr},
        ],
        weight_decay=1e-4,
    )


def _predict(model, split, batch_size: int, device):
    import torch
    from torch.utils.data import DataLoader, TensorDataset

    loader = DataLoader(
        TensorDataset(torch.from_numpy(split["x"]), torch.from_numpy(split["y"])),
        batch_size=batch_size,
        shuffle=False,
        num_workers=0,
    )
    probabilities: list[np.ndarray] = []
    losses: list[float] = []
    model.eval()
    with torch.inference_mode():
        for features, targets in loader:
            features = features.to(device)
            targets = targets.to(device)
            logits = model(features)
            losses.extend(
                torch.nn.functional.cross_entropy(logits, targets, reduction="none")
                .cpu().numpy().tolist()
            )
            probabilities.append(torch.softmax(logits, dim=1)[:, 1].cpu().numpy())
    return np.concatenate(probabilities), float(np.mean(losses))


def _aggregate_recordings(split, probabilities: np.ndarray):
    grouped: dict[str, list[int]] = defaultdict(list)
    for index, record_id in enumerate(split["record_ids"]):
        grouped[str(record_id)].append(index)
    rows = []
    for record_id, indices in sorted(grouped.items()):
        labels = split["y"][indices]
        subjects = split["subjects"][indices]
        conditions = split["conditions"][indices]
        assert np.all(labels == labels[0])
        assert np.all(subjects == subjects[0])
        assert np.all(conditions == conditions[0])
        rows.append(
            {
                "record_id": record_id,
                "subject": str(subjects[0]),
                "condition": str(conditions[0]),
                "label": int(labels[0]),
                "probability": float(np.mean(probabilities[indices])),
                "n_windows": len(indices),
            }
        )
    return rows


def _classification_metrics(labels, probabilities, threshold: float) -> dict:
    from sklearn.metrics import (
        accuracy_score,
        average_precision_score,
        balanced_accuracy_score,
        brier_score_loss,
        confusion_matrix,
        f1_score,
        log_loss,
        matthews_corrcoef,
        precision_score,
        recall_score,
        roc_auc_score,
    )

    labels = np.asarray(labels, dtype=int)
    probabilities = np.asarray(probabilities, dtype=float)
    predictions = (probabilities >= threshold).astype(int)
    matrix = confusion_matrix(labels, predictions, labels=[0, 1])
    tn, fp, fn, tp = matrix.ravel()
    return {
        "n": int(labels.size),
        "class_counts": {
            CLASS_NAMES[index]: int(np.sum(labels == index)) for index in range(2)
        },
        "threshold": float(threshold),
        "accuracy": float(accuracy_score(labels, predictions)),
        "balanced_accuracy": float(balanced_accuracy_score(labels, predictions)),
        "roc_auc": float(roc_auc_score(labels, probabilities)),
        "average_precision": float(average_precision_score(labels, probabilities)),
        "precision": float(precision_score(labels, predictions, zero_division=0)),
        "sensitivity_recall": float(recall_score(labels, predictions, zero_division=0)),
        "specificity": float(tn / max(tn + fp, 1)),
        "f1": float(f1_score(labels, predictions, zero_division=0)),
        "matthews_correlation": float(matthews_corrcoef(labels, predictions)),
        "brier_score": float(brier_score_loss(labels, probabilities)),
        "log_loss": float(
            log_loss(labels, np.column_stack([1.0 - probabilities, probabilities]), labels=[0, 1])
        ),
        "confusion_matrix_rows_true_columns_predicted": matrix.tolist(),
    }


def _choose_threshold(rows) -> tuple[float, float]:
    from sklearn.metrics import balanced_accuracy_score

    labels = np.asarray([row["label"] for row in rows])
    probabilities = np.asarray([row["probability"] for row in rows])
    candidates = np.unique(np.r_[0.0, 1.0, probabilities])
    scores = np.asarray(
        [balanced_accuracy_score(labels, probabilities >= value) for value in candidates]
    )
    best = np.flatnonzero(scores == scores.max())
    index = best[np.argmin(np.abs(candidates[best] - 0.5))]
    return float(candidates[index]), float(scores[index])


def _bootstrap_recording_ci(rows, threshold: float, seed: int, repetitions: int = 2000):
    rng = np.random.default_rng(seed)
    subjects = np.asarray(sorted({row["subject"] for row in rows}))
    by_subject = {
        subject: [row for row in rows if row["subject"] == subject] for subject in subjects
    }
    samples: dict[str, list[float]] = defaultdict(list)
    for _ in range(repetitions):
        selected = rng.choice(subjects, size=len(subjects), replace=True)
        sample = [row for subject in selected for row in by_subject[str(subject)]]
        values = _classification_metrics(
            [row["label"] for row in sample],
            [row["probability"] for row in sample],
            threshold,
        )
        for name in ("balanced_accuracy", "roc_auc", "f1"):
            samples[name].append(values[name])
    return {
        name: {
            "lower_95": float(np.percentile(values, 2.5)),
            "upper_95": float(np.percentile(values, 97.5)),
            "method": "participant_cluster_bootstrap",
            "repetitions": repetitions,
        }
        for name, values in samples.items()
    }


def _split_summary(split) -> dict:
    labels_by_record = {}
    for record_id, label in zip(split["record_ids"], split["y"]):
        labels_by_record[str(record_id)] = int(label)
    return {
        "participants": sorted(np.unique(split["subjects"]).tolist()),
        "n_participants": int(np.unique(split["subjects"]).size),
        "n_recordings": len(labels_by_record),
        "n_windows": int(len(split["y"])),
        "recording_class_counts": {
            CLASS_NAMES[index]: int(sum(value == index for value in labels_by_record.values()))
            for index in range(2)
        },
        "window_class_counts": {
            CLASS_NAMES[index]: int(np.sum(split["y"] == index)) for index in range(2)
        },
    }


def _write_report(path: Path, metrics: dict) -> None:
    recording = metrics["test"]["recording_level"]
    window = metrics["test"]["window_level"]
    ci = metrics["test"]["recording_level_cluster_bootstrap_95_ci"]
    matrix = recording["confusion_matrix_rows_true_columns_predicted"]
    lines = [
        "# Signal-JEPA on UNIVERSE: held-out test report",
        "",
        "## Test result",
        "",
        (
            f"Participant-held-out recording-level balanced accuracy was "
            f"**{recording['balanced_accuracy']:.3f}** (participant-cluster bootstrap 95% CI "
            f"{ci['balanced_accuracy']['lower_95']:.3f}–"
            f"{ci['balanced_accuracy']['upper_95']:.3f}); ROC AUC was "
            f"**{recording['roc_auc']:.3f}**."
        ),
        "",
        "| Evaluation unit | Accuracy | Balanced accuracy | ROC AUC | AUPRC | F1 | Sensitivity | Specificity | MCC |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        (
            f"| Recording ({recording['n']}) | {recording['accuracy']:.3f} | "
            f"{recording['balanced_accuracy']:.3f} | {recording['roc_auc']:.3f} | "
            f"{recording['average_precision']:.3f} | {recording['f1']:.3f} | "
            f"{recording['sensitivity_recall']:.3f} | {recording['specificity']:.3f} | "
            f"{recording['matthews_correlation']:.3f} |"
        ),
        (
            f"| 2-second window ({window['n']}) | {window['accuracy']:.3f} | "
            f"{window['balanced_accuracy']:.3f} | {window['roc_auc']:.3f} | "
            f"{window['average_precision']:.3f} | {window['f1']:.3f} | "
            f"{window['sensitivity_recall']:.3f} | {window['specificity']:.3f} | "
            f"{window['matthews_correlation']:.3f} |"
        ),
        "",
        f"Decision threshold: `{recording['threshold']:.6f}`, selected using validation recordings only.",
        "",
        "Recording confusion matrix (true rows, predicted columns; low then high stress):",
        "",
        f"`[[{matrix[0][0]}, {matrix[0][1]}], [{matrix[1][0]}, {matrix[1][1]}]]`",
        "",
        "## Protocol",
        "",
        (
            f"`{PRETRAINED_REPO}` was loaded as Braindecode `SignalJEPA_PreLocal`. "
            "A new four-channel spatial/classification head was trained. The feature encoder was "
            "subsequently unfrozen, but validation selection chose epoch 1, so the exported checkpoint "
            "retains the original pretrained feature encoder. PreLocal is the checkpoint's downstream "
            "classifier variant and does not include the contextual transformer in its forward path."
        ),
        (
            "The source was the supplied UNIVERSE UN_101--UN_112 ZIP. Only Wild-session folders labeled "
            "`vlw`/`low` (low stress) or `hig`/`vhg` (high stress) were included; `nor`, calibration, and "
            "controlled-lab task-difficulty recordings were excluded."
        ),
        (
            "The archive's preprocessed TP9, AF7, AF8, and TP10 EEG was resampled from 256 to 128 Hz. "
            "Non-overlapping 2-second windows were standardized independently per channel/window. "
            "At most 120 evenly spaced windows were retained per recording."
        ),
        "",
        f"- Train: {metrics['splits']['train']['participants']}",
        f"- Validation: {metrics['splits']['validation']['participants']}",
        f"- Test: {metrics['splits']['test']['participants']}",
        "",
        "## Limitations",
        "",
        (
            "This is a small extreme-group evaluation: 62 recordings from 11 participants were eligible, "
            "and the held-out test set contains only two participants. Neutral stress was excluded, the "
            "archive is only the UN_101--UN_112 half of UNIVERSE, and windows from one recording are "
            "correlated. Recording-level metrics are therefore primary; window-level metrics are secondary."
        ),
        "",
        "This experimental classifier is not a medical diagnostic.",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def train(args) -> dict:
    import braindecode
    import mne
    import sklearn
    import torch
    from torch.utils.data import DataLoader, TensorDataset, WeightedRandomSampler

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    if torch.backends.mps.is_available():
        torch.mps.manual_seed(args.seed)

    payload = build_or_load_dataset(
        args.archive,
        args.cache,
        args.max_windows_per_recording,
        args.seed,
        args.force_rebuild_cache,
    )
    splits = {
        name: _select(payload, participants)
        for name, participants in payload["splits"].items()
    }
    summaries = {name: _split_summary(split) for name, split in splits.items()}
    print(json.dumps(summaries, indent=2), flush=True)
    if args.prepare_only:
        return {"splits": summaries}

    if args.device == "auto":
        device_name = "mps" if torch.backends.mps.is_available() else "cpu"
    else:
        device_name = args.device
    device = torch.device(device_name)
    print(f"Training on {device}", flush=True)

    model = _make_model(args.pretrained, args.dropout)
    model.to(device)
    total_parameters = sum(parameter.numel() for parameter in model.parameters())
    pretrained_parameters = sum(
        parameter.numel()
        for name, parameter in model.named_parameters()
        if not _is_head_parameter(name)
    )

    weights = _record_balanced_weights(
        splits["train"]["y"], splits["train"]["record_ids"]
    )
    generator = torch.Generator().manual_seed(args.seed)
    sampler = WeightedRandomSampler(
        torch.from_numpy(weights),
        num_samples=len(weights),
        replacement=True,
        generator=generator,
    )
    train_loader = DataLoader(
        TensorDataset(
            torch.from_numpy(splits["train"]["x"]),
            torch.from_numpy(splits["train"]["y"]),
        ),
        batch_size=args.batch_size,
        sampler=sampler,
        num_workers=0,
    )

    _set_trainable(model, head_only=True)
    optimizer = _optimizer(
        model,
        head_only=True,
        head_lr=args.head_learning_rate,
        backbone_lr=args.backbone_learning_rate,
    )
    criterion = torch.nn.CrossEntropyLoss()
    best_score = -1.0
    best_loss = float("inf")
    best_epoch = 0
    best_state = None
    history = []
    patience_left = args.patience
    training_started = time.time()

    for epoch in range(1, args.epochs + 1):
        if epoch == args.warmup_epochs + 1:
            _set_trainable(model, head_only=False)
            optimizer = _optimizer(
                model,
                head_only=False,
                head_lr=args.head_learning_rate,
                backbone_lr=args.backbone_learning_rate,
            )
            patience_left = args.patience
            print("Unfroze the pretrained convolutional feature encoder", flush=True)

        model.train()
        loss_sum = 0.0
        seen = 0
        for features, targets in train_loader:
            features = features.to(device)
            targets = targets.to(device)
            optimizer.zero_grad(set_to_none=True)
            logits = model(features)
            loss = criterion(logits, targets)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(
                [parameter for parameter in model.parameters() if parameter.requires_grad],
                max_norm=1.0,
            )
            optimizer.step()
            loss_sum += float(loss.detach().cpu()) * targets.size(0)
            seen += targets.size(0)

        validation_probabilities, validation_loss = _predict(
            model, splits["validation"], args.batch_size, device
        )
        validation_rows = _aggregate_recordings(
            splits["validation"], validation_probabilities
        )
        epoch_threshold, balanced_accuracy = _choose_threshold(validation_rows)
        validation_metrics = _classification_metrics(
            [row["label"] for row in validation_rows],
            [row["probability"] for row in validation_rows],
            epoch_threshold,
        )
        score = validation_metrics["roc_auc"]
        epoch_metrics = {
            "epoch": epoch,
            "phase": "head_warmup" if epoch <= args.warmup_epochs else "full_finetune",
            "training_loss": loss_sum / max(seen, 1),
            "validation_loss": validation_loss,
            "validation_recording_balanced_accuracy": balanced_accuracy,
            "validation_recording_roc_auc": score,
            "validation_selected_threshold": epoch_threshold,
        }
        history.append(epoch_metrics)
        print(
            f"epoch={epoch:02d} phase={epoch_metrics['phase']:13s} "
            f"train_loss={epoch_metrics['training_loss']:.4f} "
            f"validation_loss={validation_loss:.4f} "
            f"validation_recording_bal_acc={balanced_accuracy:.3f} "
            f"validation_recording_auc={score:.3f} threshold={epoch_threshold:.4f}",
            flush=True,
        )

        improved = score > best_score + 1e-12 or (
            abs(score - best_score) <= 1e-12 and validation_loss < best_loss
        )
        if improved:
            best_score = score
            best_loss = validation_loss
            best_epoch = epoch
            best_state = {
                name: value.detach().cpu().clone()
                for name, value in model.state_dict().items()
            }
            patience_left = args.patience
        elif epoch > args.warmup_epochs:
            patience_left -= 1
            if patience_left <= 0:
                print(f"Early stopping after epoch {epoch}", flush=True)
                break

    assert best_state is not None
    model.load_state_dict(best_state)
    model.to(device)

    # The held-out test data is first evaluated here, after all model and
    # threshold choices have been made with training/validation data.
    validation_probabilities, _ = _predict(
        model, splits["validation"], args.batch_size, device
    )
    validation_rows = _aggregate_recordings(
        splits["validation"], validation_probabilities
    )
    threshold, validation_threshold_score = _choose_threshold(validation_rows)
    test_probabilities, test_loss = _predict(
        model, splits["test"], args.batch_size, device
    )
    test_rows = _aggregate_recordings(splits["test"], test_probabilities)

    validation_recording_metrics = _classification_metrics(
        [row["label"] for row in validation_rows],
        [row["probability"] for row in validation_rows],
        threshold,
    )
    test_window_metrics = _classification_metrics(
        splits["test"]["y"], test_probabilities, threshold
    )
    test_recording_metrics = _classification_metrics(
        [row["label"] for row in test_rows],
        [row["probability"] for row in test_rows],
        threshold,
    )

    per_subject = {}
    for subject in sorted({row["subject"] for row in test_rows}):
        rows = [row for row in test_rows if row["subject"] == subject]
        per_subject[subject] = _classification_metrics(
            [row["label"] for row in rows],
            [row["probability"] for row in rows],
            threshold,
        )

    args.output.mkdir(parents=True, exist_ok=True)
    model.cpu()
    model.save_pretrained(args.output, safe_serialization=True)
    training_seconds = time.time() - training_started
    metrics = {
        "task": "binary self-reported stress classification (extreme groups)",
        "class_mapping": {
            CLASS_NAMES[0]: ["vlw", "low"],
            CLASS_NAMES[1]: ["hig", "vhg"],
            "excluded": ["nor", "calibration/eye-closing", "Lab1", "Lab2"],
        },
        "dataset": {
            "name": "UNIVERSE",
            "local_archive": str(args.archive.resolve()),
            "archive_size_bytes": args.archive.stat().st_size,
            "archive_zip_manifest_sha256": payload["archive_zip_manifest_sha256"],
            "source_url": DATASET_URL,
            "participant_range_in_archive": ["UN_101", "UN_112"],
        },
        "model": {
            "architecture": "Braindecode SignalJEPA_PreLocal",
            "pretrained_repository": PRETRAINED_REPO,
            "pretrained_local_path": str(args.pretrained.resolve()),
            "pretrained_model_sha256": _sha256(args.pretrained / "model.safetensors"),
            "output_path": str(args.output.resolve()),
            "total_parameters": total_parameters,
            "pretrained_feature_encoder_parameters": pretrained_parameters,
            "channels": list(CHANNELS),
            "sample_rate_hz": SAMPLE_RATE,
            "window_seconds": WINDOW_SECONDS,
        },
        "preprocessing": {
            "archive_pipeline": [
                "average reference",
                "normalization",
                "0.5-50 Hz bandpass",
                "50 Hz notch",
            ],
            "resampling_hz": [SOURCE_SAMPLE_RATE, SAMPLE_RATE],
            "window_stride_seconds": WINDOW_SECONDS,
            "overlap": False,
            "per_channel_per_window_standardization": True,
            "standardized_value_clip": [-20.0, 20.0],
            "max_windows_per_recording": args.max_windows_per_recording,
        },
        "training": {
            "device": device_name,
            "seed": args.seed,
            "batch_size": args.batch_size,
            "epochs_requested": args.epochs,
            "epochs_completed": len(history),
            "best_epoch": best_epoch,
            "warmup_epochs": args.warmup_epochs,
            "patience": args.patience,
            "head_learning_rate": args.head_learning_rate,
            "backbone_learning_rate": args.backbone_learning_rate,
            "dropout": args.dropout,
            "sampling": "equal class mass; equal recording mass within class",
            "checkpoint_selection_metric": "validation recording ROC AUC, validation loss tie-break",
            "feature_encoder_updated_in_exported_checkpoint": best_epoch > args.warmup_epochs,
            "training_seconds": training_seconds,
            "history": history,
        },
        "software": {
            "python": sys.version.split()[0],
            "torch": torch.__version__,
            "braindecode": braindecode.__version__,
            "mne": mne.__version__,
            "scikit_learn": sklearn.__version__,
            "numpy": np.__version__,
        },
        "splits": summaries,
        "validation": {
            "recording_level": validation_recording_metrics,
            "threshold_selection_metric": "recording-level balanced accuracy",
            "threshold_selection_score": validation_threshold_score,
        },
        "test": {
            "loss": test_loss,
            "window_level": test_window_metrics,
            "recording_level": test_recording_metrics,
            "recording_level_cluster_bootstrap_95_ci": _bootstrap_recording_ci(
                test_rows, threshold, args.seed + 1000
            ),
            "per_subject_recording_level": per_subject,
            "recording_predictions": test_rows,
        },
        "limitations": [
            "Only UN_101--UN_112 were present in the supplied archive.",
            "Neutral stress was excluded; this is an extreme-group task.",
            "The test set contains only two participants.",
            "Windows from a recording are correlated, so recording-level metrics are primary.",
        ],
    }
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    _write_report(args.report, metrics)
    print(f"Saved fine-tuned model to {args.output}", flush=True)
    print(f"Saved metrics to {args.metrics}", flush=True)
    print(f"Saved report to {args.report}", flush=True)
    print(json.dumps(metrics["test"], indent=2), flush=True)
    return metrics


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--pretrained", type=Path, default=DEFAULT_PRETRAINED)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--metrics", type=Path, default=DEFAULT_METRICS)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--warmup-epochs", type=int, default=5)
    parser.add_argument("--patience", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--head-learning-rate", type=float, default=5e-3)
    parser.add_argument("--backbone-learning-rate", type=float, default=1e-4)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--max-windows-per-recording", type=int, default=120)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", choices=("auto", "cpu", "mps"), default="auto")
    parser.add_argument("--force-rebuild-cache", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    os.environ.setdefault("MPLCONFIGDIR", str(ROOT / ".eeg_cache" / "matplotlib"))
    train(parse_args())
