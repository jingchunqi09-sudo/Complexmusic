"""Audit late residual AC/DC from actual 30-second natural-tail RTL output."""
from pathlib import Path
import csv
import hashlib
import json
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "sim/results/revision5_ukulele"
rows = list(csv.DictReader((OUT / "natural_decay_blocks.csv").open(encoding="utf-8")))
measured = []
for note in [60, 69, 84]:
    values = np.loadtxt(OUT / f"natural_tail{note}.txt", dtype=float)
    assert values.shape == (8192,)
    dc = float(np.mean(values))
    ac = float(np.sqrt(np.mean((values-dc)**2)))
    peak = float(np.max(np.abs(values)))
    assert abs(dc) <= 2 and ac <= 2 and peak <= 8, (note, dc, ac, peak)
    blocks = [row for row in rows if int(row["midi"]) == note]
    assert len(blocks) == 375 and int(blocks[-1]["end_sample"]) == 1440000
    nonquiet = [row for row in blocks if int(row["peak"]) > 8]
    quiet_from = float(int(nonquiet[-1]["end_sample"]) / 48000) if nonquiet else 0
    measured.append({"midi": note, "velocity": 255, "duration_seconds": 30,
                     "final8192_dc_pcm": dc, "final8192_ac_rms_pcm": ac,
                     "final8192_absolute_peak_pcm": peak, "all_later_80ms_blocks_peak_at_most8_from_s": quiet_from})
result = {"sample_rate_hz": 48000, "notes": measured,
          "source_sha256": hashlib.sha256((ROOT / "src/ukulele_waveguide_voice.v").read_bytes()).hexdigest(),
          "interpretation": "No envelope cutoff and no STOP. Final residual is checked separately for AC and DC. A 1 PCM constant DC floor is -90.3 dBFS; it is not a sustained tonal oscillation. Physical DAC silence and board recordings have not been verified."}
(OUT / "natural_decay_measurements.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print("PASS 30s natural-tail AC/DC audit:", json.dumps(measured))
