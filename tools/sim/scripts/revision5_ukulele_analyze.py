"""Measure actual ModelSim PCM; independent of the waveguide implementation.

This quantifies engineering behavior, not a listening score or acoustic model fit.
Both models run at 48000 Hz with identical gestures and independent frozen RTL.
"""
from __future__ import annotations

import csv
import hashlib
import json
import math
from pathlib import Path
import wave
import sys

import numpy as np
# Optional local plotting packages; the bundled/global Python is not modified.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "build/revision5_ukulele_plotdeps"))
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "sim/results/revision5_ukulele"
FS = 48000


def rms(x):
    return float(np.sqrt(np.mean(np.asarray(x, dtype=float) ** 2)))


def spectrum(x, start=960, end=9600):
    segment = x[start:end].astype(float)
    segment -= np.mean(segment)
    magnitudes = np.abs(np.fft.rfft(segment * np.hanning(len(segment)), 262144))
    return np.fft.rfftfreq(262144, 1 / FS), magnitudes


def describe(x, note):
    target = 440 * 2 ** ((note - 69) / 12)
    frequencies, magnitudes = spectrum(x)
    local = np.flatnonzero((frequencies > target * .975) & (frequencies < target * 1.025))
    peak = local[np.argmax(magnitudes[local])]
    y = np.log(magnitudes[peak - 1:peak + 2] + 1e-30)
    offset = float(.5 * (y[0] - y[2]) / (y[0] - 2 * y[1] + y[2]))
    fundamental = (peak + offset) * FS / 262144
    harmonics = [float(np.max(magnitudes[np.abs(frequencies - target * h) < 8]))
                 for h in range(1, 13)]
    harmonic_db = (20 * np.log10(np.maximum(harmonics, 1e-20) / harmonics[0])).tolist()
    band = (frequencies >= target * .75) & (frequencies <= 8000)
    centroid = float(np.sum(frequencies[band] * magnitudes[band] ** 2) /
                     np.sum(magnitudes[band] ** 2))
    frames = np.array([rms(x[a:a + 960]) for a in range(0, len(x) - 959, 960)])
    times = (np.arange(len(frames)) * 960 + 480) / FS
    # Relative total RMS level avoids mistaking a gain increase for extra sustain.
    reference = float(np.max(frames[(times >= .02) & (times <= .2)]))
    levels = 20 * np.log10(np.maximum(frames, 1e-12) / reference)
    candidates = np.flatnonzero((times > .08) & (levels <= -20))
    t20 = None
    for index in candidates:
        if index + 3 <= len(levels) and np.all(levels[index:index + 3] <= -20):
            t20 = float(times[index])
            break
    fit = (times >= .08) & (levels <= -5) & (levels >= -25) & (frames >= 5)
    fitted_t60 = None
    r_squared = None
    if np.sum(fit) >= 8:
        slope, intercept = np.polyfit(times[fit], levels[fit], 1)
        residual = levels[fit] - (slope * times[fit] + intercept)
        r_squared = float(1 - np.sum(residual ** 2) / np.sum((levels[fit] - np.mean(levels[fit])) ** 2))
        if slope < 0:
            fitted_t60 = float(-60 / slope)
    return {
        "fundamental_hz": fundamental,
        "cents_error": 1200 * math.log2(fundamental / target),
        "peak_pcm": int(np.max(np.abs(x))),
        "rail_samples": int(np.count_nonzero((x == 32767) | (x == -32768))),
        "onset_rms_20_200ms": rms(x[960:9600]),
        "tail_rms_1_2_1_5s": rms(x[57600:72000]) if len(x) >= 72000 else None,
        "late_rms_2_7_3s": rms(x[129600:144000]) if len(x) >= 144000 else None,
        "mean_last_200ms": float(np.mean(x[-9600:])),
        "spectral_centroid_20_200ms_hz": centroid,
        "harmonic_relative_db_1_to_12": harmonic_db,
        "harmonics_above_minus40db": int(sum(v >= -40 for v in harmonic_db)),
        "relative_rms_minus20db_time_s": t20,
        "fitted_total_rms_t60_s": fitted_t60,
        "decay_fit_r_squared": r_squared,
    }, times, levels


def wav(path, pcm):
    quantized = np.clip(np.rint(pcm), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1 if quantized.ndim == 1 else quantized.shape[1])
        output.setsampwidth(2)
        output.setframerate(FS)
        output.writeframes(quantized.tobytes())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    pitch = []
    for note in range(55, 85):
        source = OUT / f"n{note}.txt"
        x = np.loadtxt(source, dtype=np.int32)
        assert x.shape == (12000,), (source, x.shape)
        measured, _, _ = describe(x, note)
        assert abs(measured["cents_error"]) < 5, (note, measured["cents_error"])
        assert measured["rail_samples"] == 0
        pitch.append({"midi": note, **measured})
    with (OUT / "pitch.csv").open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=["midi", "fundamental_hz", "cents_error", "peak_pcm"])
        writer.writeheader()
        writer.writerows({key: row[key] for key in writer.fieldnames} for row in pitch)
    opens = []
    plt.rcParams.update({"font.size": 10, "figure.dpi": 160})
    fig, axes = plt.subplots(5, 1, figsize=(9, 10), sharex=True)
    sequence_new, sequence_old = [], []
    for axis, note in zip(axes, [55, 60, 64, 67, 69]):
        samples = np.loadtxt(OUT / f"open{note}.txt", dtype=np.int32)
        assert samples.shape == (144000, 4)
        record = {"midi": note}
        for column, name in enumerate(["revision5", "revision4", "revision5_dry", "revision4_dry"]):
            measured, times, levels = describe(samples[:, column], note)
            record[name] = measured
            assert measured["rail_samples"] == 0
            if column < 2:
                axis.plot(times, levels, label=name)
        new, old = record["revision5"], record["revision4"]
        record["tail_rms_ratio_new_over_old"] = new["tail_rms_1_2_1_5s"] / old["tail_rms_1_2_1_5s"]
        record["onset_centroid_ratio_new_over_old"] = new["spectral_centroid_20_200ms_hz"] / old["spectral_centroid_20_200ms_hz"]
        # Both are observations. Avoid asserting that a particular timbre metric proves realism.
        axis.axhline(-20, color="grey", linestyle=":", linewidth=.8)
        axis.set_ylim(-65, 2)
        axis.set_ylabel(f"MIDI {note}\ndB re onset")
        axis.grid(alpha=.25)
        opens.append(record)
        sequence_new += [samples[:, 0], np.zeros(9600)]
        sequence_old += [samples[:, 1], np.zeros(9600)]
    axes[0].legend(loc="upper right")
    axes[-1].set_xlabel("Time after pluck (s); each trace has its own onset reference")
    fig.suptitle("Ukulele actual RTL decay, 48 kHz, identical velocity 224")
    fig.tight_layout()
    fig.savefig(OUT / "decay_comparison.png")
    plt.close(fig)
    a4 = np.loadtxt(OUT / "a4.txt", dtype=np.int32)
    assert a4.shape == (144000, 7)
    assert np.all(a4[10000:, 6] == 30720), "gate=0 cut off the plucked envelope"
    strong = rms(a4[960:9600, 0])
    weak = rms(a4[960:9600, 4])
    assert strong > 2 * weak
    position_difference = rms(a4[960:9600, 0] - a4[960:9600, 5])
    assert position_difference > 100, "pluck-position control has no audible effect"
    wav(OUT / "ukulele_A4_revision5.wav", a4[:, 0])
    wav(OUT / "ukulele_A4_revision4.wav", a4[:, 1])
    matched = np.column_stack([a4[:, 1] * 3000 / rms(a4[960:9600, 1]),
                               a4[:, 0] * 3000 / strong])
    assert np.max(np.abs(matched)) < 32767
    wav(OUT / "ukulele_A4_level_matched_old_left_new_right.wav", matched)
    wav(OUT / "ukulele_open_strings_revision5.wav", np.concatenate(sequence_new))
    wav(OUT / "ukulele_open_strings_revision4.wav", np.concatenate(sequence_old))
    fig, ax = plt.subplots(figsize=(9, 4))
    for column, label in [(1, "revision4"), (0, "revision5")]:
        measured, _, _ = describe(a4[:, column], 69)
        ax.plot(range(1, 13), measured["harmonic_relative_db_1_to_12"], "o-", label=label)
    ax.set(xlabel="Harmonic number", ylabel="dB relative to fundamental", ylim=(-80, 10),
           title="A4 onset harmonics, actual RTL, 20-200 ms")
    ax.legend(); ax.grid(alpha=.25);fig.tight_layout()
    fig.savefig(OUT / "harmonic_comparison.png");plt.close(fig)
    result = {
        "sample_rate_hz": FS,
        "sweep_notes": 30,
        "max_abs_cents_error": max(abs(row["cents_error"]) for row in pitch),
        "source_sha256": {str(path.relative_to(ROOT)): sha(path) for path in [
            ROOT / "src/ukulele_waveguide_voice.v", ROOT / "src/voice_envelope.v",
            ROOT / "src/instrument_body_resonator.v", ROOT / "src/instrument_pitch.vh",
            ROOT / "sim/scripts/revision5_ukulele_tb.v"]},
        "baseline_source_hashes": json.loads((ROOT / "build/revision5_ukulele_baseline/source_hashes.json").read_text(encoding="utf-8-sig")),
        "velocity_rms_ratio_224_over_32": strong / weak,
        "pluck_position_rms_difference": position_difference,
        "open_strings": opens,
        "pitch": pitch,
        "interpretation": "Measured actual RTL, same 48k rate and gestures; brighter spectra and longer relative decay are engineering observations, not proof of perceptual realism. Fitted T60 extrapolates a changing total-RMS curve and is not an acoustic measurement. No FPGA programming, physical UART/DAC recording or listener scoring performed.",
    }
    (OUT / "measurements.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print("PASS revision5 ukulele measurements:", json.dumps({
        "max_abs_cents": result["max_abs_cents_error"],
        "velocity_rms_ratio": result["velocity_rms_ratio_224_over_32"],
        "tail_ratios": [row["tail_rms_ratio_new_over_old"] for row in opens],
        "centroid_ratios": [row["onset_centroid_ratio_new_over_old"] for row in opens],
    }))


if __name__ == "__main__":
    main()
