"""Reuse the strict Gowin runner in this experiment's isolated output tree."""
import argparse
from pathlib import Path
import resource_timing_runner as runner
from resource_timing_snapshot import ROOT


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--stage", choices=["syn", "pnr", "all"], default="all")
    parser.add_argument("--place", type=int, choices=range(5), default=0)
    parser.add_argument("--route", type=int, choices=range(3), default=1)
    parser.add_argument("--replicate", type=int, choices=[0, 1], default=0)
    parser.add_argument("--clock-order", type=int, choices=[0, 1], default=0)
    args = parser.parse_args()
    runner.TASK = ROOT / "build/physical_20261025/full_candidates"
    runner.build(args.label, args.source, args.stage, args.place, args.route, args.replicate, args.clock_order)
