# -*- coding: utf-8 -*-
"""同一份网表、不同 place_option 的 hold 扫描。

为什么需要它：本工程 CLS 84~85%，`-correct_hold_violation 1` 一直开着，
但 hold 仍在 43~180 ps 之间大幅波动（R41 180 / R49 144 / R51 45 / R52b 43）。
工具已经尽力，剩下的是布局随机性 —— 只能实测挑。

用法（**必须在综合完成之后、且不要改 src/ 任何字节**）：
    python scripts/pnr_place_sweep.py --tag R53 --places 2,3

每次会：
  1) 用 build/r24_bow/pnr_only.tcl 生成 place=N 的副本
  2) 只跑 `run pnr`（复用 impl/gwsynthesis 的网表）
  3) 把 .fs/.tr/.rpt.txt 拷成 build/r24_bow/<tag>_p<N>.*
  4) 解析 hold / setup / Fmax / CLS 打到屏幕
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "r24_bow"
PNR_SRC = OUT / "pnr_only.tcl"
GW = pathlib.Path(r"D:\applicationstudy\Fpga\Gowin_vip\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe")


def parse(tr: pathlib.Path, rpt: pathlib.Path):
    res = {}
    t = tr.read_text(encoding="utf-8", errors="ignore")
    for key, pat in (("setup", r"^3\.1\.1 Setup Paths Table"),
                     ("hold", r"^3\.1\.2 Hold Paths Table")):
        m = re.search(pat, t, re.M)
        if not m:
            continue
        tail = t[m.end():].splitlines()
        # 表头 3 行之后是数据行
        rows = [ln for ln in tail if re.match(r"\s+\d+\s+-?\d", ln)]
        if not rows:
            continue
        cols = rows[0].split()
        res[key + "_slack"] = float(cols[1])
        res[key + "_from"] = cols[2] if len(cols) > 2 else ""
        res[key + "_to"] = cols[3] if len(cols) > 3 else ""
    if rpt.exists():
        r = rpt.read_text(encoding="utf-8", errors="ignore")
        for key, pat in (("CLS", r"CLS:\s*(\d+/\d+)"),
                         ("BSRAM", r"BSRAM:\s*(\d+/\d+)"),
                         ("DSP", r"DSP:\s*([\d.]+/\d+)")):
            m = re.search(pat, r)
            if m:
                res[key] = m.group(1)
        m = re.search(r"(?:Max Frequency|Fmax)\D*([\d.]+)", r)
        if m:
            res["fmax"] = m.group(1)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="产物前缀，例如 R53")
    ap.add_argument("--places", default="2,3")
    ap.add_argument("--combos", default=None,
                    help="place:route 组合，逗号分隔，如 0:2,3:1。"
                         "place_option 只有 0~3 四档，光换 place 最多 4 次；"
                         "route_option 换一套布线还能再摇几次（hold 主要由布局+布线共同决定）")
    a = ap.parse_args()

    if a.combos:
        pairs = [(int(x.split(":")[0]), int(x.split(":")[1])) for x in a.combos.split(",")]
    else:
        pairs = [(int(x), 2) for x in a.places.split(",")]

    src = PNR_SRC.read_text(encoding="utf-8")
    results = []
    for p, r in pairs:
        suffix = f"p{p}" if (not a.combos and r == 2) else f"p{p}r{r}"
        tcl = OUT / f"pnr_place{suffix}.tcl"
        s2 = re.sub(r"set_option -place_option \d+",
                    f"set_option -place_option {p}", src)
        s2 = re.sub(r"set_option -route_option \d+",
                    f"set_option -route_option {r}", s2)
        tcl.write_text(s2, encoding="utf-8")
        log = OUT / f"pnr_{a.tag}_{suffix}.log"
        print(f"\n=== place {p} / route {r} -> {log.name}", flush=True)
        with open(log, "w", encoding="utf-8", errors="ignore") as fh:
            subprocess.run([str(GW), str(tcl)], stdout=fh,
                           stderr=subprocess.STDOUT, cwd=str(ROOT))
        txt = log.read_text(encoding="utf-8", errors="ignore")
        ok = "Bitstream generation completed" in txt
        print(f"    bitstream={ok}", flush=True)
        if not ok:
            print(txt[-1200:])
            continue
        for ext in ("fs", "tr", "rpt.txt"):
            s = ROOT / "impl/pnr" / f"tang_mega_60k.{ext}"
            d = OUT / f"{a.tag}_{suffix}.{ext}"
            if d.exists():
                d.unlink()
            if s.exists():
                shutil.copy2(s, d)
        info = parse(OUT / f"{a.tag}_{suffix}.tr", OUT / f"{a.tag}_{suffix}.rpt.txt")
        info["place"] = p
        info["route"] = r
        info["suffix"] = suffix
        results.append(info)
        print(f"    hold={info.get('hold_slack')} ns  setup={info.get('setup_slack')} ns"
              f"  fmax={info.get('fmax')}  CLS={info.get('CLS')}", flush=True)
        print(f"    hold path: {info.get('hold_from')} -> {info.get('hold_to')}", flush=True)

    print("\n===== 汇总（按 hold 降序）=====")
    for x in sorted(results, key=lambda x: -(x.get("hold_slack") or -99)):
        print(f"  place {x['place']} route {x['route']}: hold {x.get('hold_slack')}"
              f"  setup {x.get('setup_slack')}  fmax {x.get('fmax')}  CLS {x.get('CLS')}")
    if results:
        best = max(results, key=lambda x: (x.get("hold_slack") or -99))
        print(f"\n最佳 place={best['place']} route={best['route']}"
              f" (hold {best.get('hold_slack')} ns)")
        print(f"位流：build/r24_bow/{a.tag}_{best['suffix']}.fs")


if __name__ == "__main__":
    sys.exit(main())
