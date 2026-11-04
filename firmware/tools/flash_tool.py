#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ESP32 烧录工具（自选串口 + 自选文件）

用法:
    python tools/flash_tool.py              交互式：选串口 -> 选文件 -> 烧录
    python tools/flash_tool.py --list       只列出串口和可烧文件，不烧
    python tools/flash_tool.py --all        全选四个必需文件 + 自动认口（快速模式）
    python tools/flash_tool.py --port COM7  跳过选串口
    python tools/flash_tool.py --log        只看串口日志（115200），不烧
    python tools/flash_tool.py --diag       链路诊断：复位后抓日志，判读"为什么收不到字节"
    python tools/flash_tool.py --bin 3.3.1  只烧指定版本的固件到 0x10000（切版本/回退）
    python tools/flash_tool.py --bin "D:\\x\\firmware.bin"   指定任意 .bin
    python tools/flash_tool.py --baud 460800  改烧录波特率
    python tools/flash_tool.py --check      不烧，只回读板上版本与 build 对比
    python tools/flash_tool.py --watch-enc  面板联调：实时打印 [enc] 日志（短按/长按/换弦）
    python tools/flash_tool.py --encprobe   面板接线自检：转最左旋钮，判定排线 1-1 还是 1<->14
                              （走 WiFi 读 /encprobe，需电脑连在 Tang60K-Music 热点上）
    python tools/flash_tool.py --no-verify  烧完不回读板上版本（默认会回读 6 秒确认）

设计原则：任何一步都显式告诉你它在动什么，不猜、不静默。
"""

import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

# ---------- 工程路径 ----------
HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
BUILD = os.path.join(PROJECT, ".pio", "build", "esp32dev")
HOME = os.path.expanduser("~")
FRAMEWORK_PART = os.path.join(
    HOME, ".platformio", "packages", "framework-arduinoespressif32",
    "tools", "partitions", "boot_app0.bin"
)
ESPTOOL = os.path.join(HOME, ".platformio", "packages", "tool-esptoolpy", "esptool.py")

# 本机实测分区表（解析 .pio/build/esp32dev/partitions.bin 得出）
# nvs 0x9000/20K, otadata 0xE000/8K, app0 0x10000/1280K,
# app1 0x150000/1280K, spiffs 0x290000/1408K, coredump 0x3F0000/64K
FILES = [
    dict(key="1", name="bootloader.bin", addr=0x1000, path=os.path.join(BUILD, "bootloader.bin"),
         desc="二级引导（开机第一段代码）", when="首次烧录 / 换了板型", must=True),
    dict(key="2", name="partitions.bin", addr=0x8000, path=os.path.join(BUILD, "partitions.bin"),
         desc="分区表（决定 app0 / spiffs 落在哪）", when="首次烧录 / 改了分区表", must=True),
    dict(key="3", name="boot_app0.bin", addr=0xE000, path=FRAMEWORK_PART,
         desc="OTA 选择标记（在 framework 包里，不在 build 目录）", when="首次烧录", must=True),
    dict(key="4", name="firmware.bin", addr=0x10000, path=os.path.join(BUILD, "firmware.bin"),
         desc="应用本体 = 你的代码（app0 分区）", when="每次改代码", must=True),
    dict(key="5", name="littlefs.bin", addr=0x290000, path=os.path.join(BUILD, "littlefs.bin"),
         desc="曲谱文件系统（spiffs 分区，LittleFS 格式）", when="要预置/更新曲谱时", must=False),
    dict(key="6", name="firmware_merged.bin", addr=0x0, path=os.path.join(BUILD, "firmware_merged.bin"),
         desc="1~4 合成一个整包（和上面 1~4 互斥）", when="存档 / 发给别人 / 救砖", must=False),
]

# 已知 ESP32 板载 USB-UART 桥
BRIDGE = {
    "10C4:EA60": "CP210x",
    "10C4:EA70": "CP2105",
    "1A86:7523": "CH340",
    "1A86:55D3": "CH343",
    "1A86:55D4": "CH9102",
    "0403:6001": "FT232R",
    "303A:1001": "ESP32 原生USB",
    "303A:0002": "ESP32-S3/C3 原生USB",
}
NEVER = {"0403:6010": "FT2232H = Tang 板载调试器，不是 ESP32"}


# ---------- 小工具 ----------
def die(msg, code=1):
    print()
    print("  [中止] " + msg)
    sys.exit(code)


def human(n):
    return "{:,}".format(n)


def find_pio():
    p = shutil.which("pio.exe") or shutil.which("pio")
    if p:
        return p
    p = os.path.join(HOME, ".platformio", "penv", "Scripts", "pio.exe")
    return p if os.path.exists(p) else None


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=PROJECT, **kw)


def clear_line():
    print()


# ---------- 串口 ----------
def get_ports():
    pio = find_pio()
    if not pio:
        die("找不到 pio.exe，请确认 PlatformIO Core 已安装。")
    r = run([pio, "device", "list", "--json-output"],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0 or not r.stdout.strip():
        return []
    try:
        raw = json.loads(r.stdout)
    except json.JSONDecodeError:
        return []

    ports = []
    for d in raw:
        hwid = str(d.get("hwid", ""))
        if "USB" not in hwid:
            continue  # 蓝牙虚拟串口
        vidpid = None
        if "VID:PID=" in hwid:
            seg = hwid.split("VID:PID=")[1][:9]
            vidpid = seg.upper()
        note = ""
        kind = "unknown"
        if vidpid in NEVER:
            note = NEVER[vidpid]
            kind = "never"
        elif vidpid in BRIDGE:
            note = BRIDGE[vidpid]
            kind = "esp32"
        ports.append(dict(port=str(d.get("port", "")),
                          desc=str(d.get("description", "")),
                          vidpid=vidpid, note=note, kind=kind))
    # 推荐的口排前面
    order = {"esp32": 0, "unknown": 1, "never": 2}
    ports.sort(key=lambda x: order.get(x["kind"], 3))
    return ports


def all_com_ports():
    """系统里所有 COM 口（含蓝牙虚拟口），只用来判断"这个口号还在不在"。
    走注册表，不依赖 pyserial；读失败就返回空表示"不知道"。"""
    try:
        import winreg
    except ImportError:
        return []
    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DEVICEMAP\SERIALCOMM")
    except OSError:
        return []
    out = []
    i = 0
    while True:
        try:
            _, val, _ = winreg.EnumValue(key, i)
        except OSError:
            break
        out.append(str(val).upper())
        i += 1
    return out


def pick_port(ports, forced=None, non_interactive=False):
    if forced:
        print("  使用指定串口: " + forced)
        return forced
    if not ports:
        die("没有找到任何 USB 串口。检查：1) Type-C 线插在 ESP32 上；2) 线能传数据（不是纯充电线）。")

    esp = [p for p in ports if p["kind"] == "esp32"]
    if len(esp) == 1:
        p = esp[0]
        print("  自动选中唯一可识别的 ESP32 串口: {0}  ({1})".format(p["port"], p["note"]))
        return p["port"]

    print("  当前 USB 串口：")
    for i, p in enumerate(ports, 1):
        tag = ""
        if p["kind"] == "esp32":
            tag = "  <- " + p["note"]
        elif p["kind"] == "never":
            tag = "  <- " + p["note"] + "【别选】"
        else:
            tag = "  <- 未识别的桥（可能是你的板子）"
        print("    [{0}] {1:<7} {2:<32} {3}{4}".format(i, p["port"], p["desc"][:32], p["vidpid"] or "", tag))

    if non_interactive:
        print()
        if not esp:
            print("  [中止] 没有识别到 ESP32，无法全自动选口。")
            print("        插上板子后重试，或用: python tools\\flash_tool.py --port COMx")
        else:
            print("  [中止] 识别到多个 ESP32 串口，不能替你猜。用: python tools\\flash_tool.py --port COMx")
        sys.exit(2)

    clear_line()
    while True:
        s = input("  输入编号选择串口（q 退出）: ").strip()
        if s.lower() == "q":
            die("已取消。", 0)
        if s.isdigit() and 1 <= int(s) <= len(ports):
            p = ports[int(s) - 1]
            if p["kind"] == "never":
                print("  注意：{0} 是 {1}。确定要往里烧吗？".format(p["port"], p["note"]))
                if input("  输入 yes 继续: ").strip().lower() != "yes":
                    continue
            return p["port"]
        print("  无效输入。")


# ---------- 文件 ----------
def file_info(f):
    exists = os.path.exists(f["path"])
    size = os.path.getsize(f["path"]) if exists else 0
    return exists, size


def fw_version(path):
    """从 firmware.bin 里抓编译进去的固件版本串（kFwVer，形如 3.2.0）

    注意必须按**数字**排序再取最大：字符串排序会把 3.5.9 排到 3.5.10 后面
    （'9' > '1'），于是 3.5.10 的固件被读成 3.5.9 —— 这个坑真的踩过。
    """
    try:
        with open(path, "rb") as fp:
            data = fp.read()
    except OSError:
        return None
    vers = {m.decode() for m in re.findall(rb"\b\d+\.\d+\.\d+\b", data)}
    parsed = [(ver_tuple(v), v) for v in vers]
    parsed = [(t, v) for t, v in parsed if t]
    if not parsed:
        return None
    return max(parsed)[1]


def ver_tuple(s):
    """'3.3.6' -> (3, 3, 6)。解析失败返回 None，调用方必须判空。"""
    try:
        return tuple(int(x) for x in str(s).split("."))
    except (TypeError, ValueError):
        return None


def sources_newer_than_bin():
    """返回比 firmware.bin 更新的源码文件名（说明固件没包含这些改动）"""
    binp = os.path.join(BUILD, "firmware.bin")
    if not os.path.exists(binp):
        return []
    bin_t = os.path.getmtime(binp)
    srcdir = os.path.join(PROJECT, "src")
    if not os.path.isdir(srcdir):
        return []
    newer = []
    for name in sorted(os.listdir(srcdir)):
        if not name.endswith((".h", ".hpp", ".c", ".cpp")):
            continue
        if os.path.getmtime(os.path.join(srcdir, name)) > bin_t + 1:
            newer.append(name)
    return newer


def _sha256(path):
    """算文件 sha256；读不了就返回空串（调用方据此降级，不抛异常）。"""
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def paired_bitstream(fw_ver):
    """在交付目录里找与这个固件版本配对的那份 .fs 位流。

    判据：某个 R* 目录里同时存在 firmware_<ver>.bin 和 *.fs。
    返回 (目录名, .fs 路径, 模式)，模式含义：
      paired  —— 该 .fs 就是为这个固件出的，两者要对齐烧
      fw_only —— 该版只改 ESP32（manifest 里 firmware 与 firmware_latest 不同），
                 位流没重建，**不需要重烧**
    这两者必须分开：3.5.2/3.5.3 纯 ESP32 改动，误报"必须成对"会让人白烧 20 MB、
    多一次擦写风险。判据全部来自 manifest.json，不硬编码版本号。
    """
    if not fw_ver or fw_ver == "未知":
        return None
    root = os.path.join(os.path.dirname(PROJECT), "releases")
    if not os.path.isdir(root):
        return None
    for d in sorted(glob.glob(os.path.join(root, "R*")), reverse=True):
        fwbin = os.path.join(d, "firmware_{0}.bin".format(fw_ver))
        if not os.path.isfile(fwbin):
            continue
        fs = sorted(glob.glob(os.path.join(d, "*.fs")))
        if not fs:
            continue

        mode = "paired"
        man = os.path.join(d, "manifest.json")
        if os.path.isfile(man):
            try:
                with open(man, encoding="utf-8") as f:
                    j = json.load(f)
            except (OSError, ValueError):
                j = {}
            orig = str(j.get("firmware_sha256") or "").lower()
            cur = _sha256(fwbin).lower()
            # 该目录的位流原本配的是别的固件 → 说明位流没跟着重建
            if orig and cur and orig != cur:
                mode = "fw_only"
        return os.path.basename(d), fs[0], mode
    return None


def print_bitstream_reminder(binp=None):
    """烧录成功后提醒配套位流。固件和位流必须成对，这是最容易漏掉的一步。"""
    binp = binp or os.path.join(BUILD, "firmware.bin")
    if not os.path.exists(binp):
        return
    got = paired_bitstream(fw_version(binp))
    if not got:
        return
    tag, fs, mode = got
    print()
    if mode == "fw_only":
        print("  ┌─ FPGA 位流这次不用重烧 ────────────────────────────")
        print("  │ 位流目录：{0}".format(tag))
        print("  │ 位流文件：{0}".format(os.path.basename(fs)))
        print("  │ 该版只改 ESP32（面板/网页/诊断），位流没重建。")
        print("  │ 板上已是这一版 .fs 的话，直接开网页就行。")
        print("  └────────────────────────────────────────────────────")
    else:
        print("  ┌─ 别忘了 FPGA 位流 ─────────────────────────────────")
        print("  │ 位流目录：{0}".format(tag))
        print("  │ 位流文件：{0}".format(os.path.basename(fs)))
        print("  │ 用 Gowin Programmer 烧这个 .fs；它和刚烧的固件必须成对。")
        print("  └────────────────────────────────────────────────────")


def print_fw_info(pairing=True):
    """打印当前 build 的固件版本与编译时间，并提示源码是否比固件新

    pairing=False 用于 `--bin X.Y.Z` 场景：那时要烧的不是 .pio build，
    再报 build 的配套位流会把人引到错的那份 .fs 上（回退版本时真的踩过）。
    """
    binp = os.path.join(BUILD, "firmware.bin")
    if not os.path.exists(binp):
        print("  固件：尚未编译（先跑 pio run）")
        return
    ver = fw_version(binp) or "未知"
    t = datetime.datetime.fromtimestamp(os.path.getmtime(binp)).strftime("%Y-%m-%d %H:%M")
    print("  固件版本：{0}   编译于 {1}   {2} B".format(ver, t, human(os.path.getsize(binp))))
    if not pairing:
        print("          （下面用的是 --bin 指定的固件，与这个 build 无关）")
    got = paired_bitstream(ver) if pairing else None
    if got:
        tag, fs, mode = got
        print("  配套位流：{0}  {1}".format(tag, os.path.basename(fs)))
        if mode == "fw_only":
            print("            该版只改 ESP32，位流没重建 —— 板上已是这一版就不用重烧。")
        else:
            print("            这一对必须一起烧；单独换固件会导致网页显示与实际不符（量程/参数对不上）")
        # build 与交付目录里同名包是不是同一份：不同就说明"改了代码但没同步交付目录"，
        # 这种时候按交付包回退会悄悄换掉一版代码。
        shipped = None
        for d in sorted(glob.glob(os.path.join(os.path.dirname(PROJECT),
                                               "releases", "R*")), reverse=True):
            cand = os.path.join(d, "firmware_{0}.bin".format(ver))
            if os.path.isfile(cand):
                shipped = cand
                break
        if shipped:
            same = _sha256(shipped) == _sha256(binp)
            if same:
                print("            与交付包 firmware_{0}.bin 逐字节相同。".format(ver))
            else:
                print("            [注意] 与交付包 firmware_{0}.bin 不同：交付目录里那份是旧的，".format(ver))
                print("                   按交付包回退会换掉当前代码。要不要同步由你决定。")
    newer = sources_newer_than_bin()
    if newer:
        print("  [注意] 以下源码比固件新，当前 firmware.bin 没包含它们：")
        print("         " + ", ".join(newer))
        print("         本工具烧之前会自动编译；但 --list 里看到的是旧版本。")
    else:
        print("  源码与固件一致（src 里没有更新的文件），可以直接烧。")


def show_files(selected):
    print("  可烧录文件（build 目录 + framework 包）：")
    print("    {0:<4}{1:<22}{2:<11}{3:<13}{4}".format("", "文件", "地址", "大小", "说明"))
    for f in FILES:
        exists, size = file_info(f)
        mark = "[x]" if f["key"] in selected else "[ ]"
        if not exists:
            mark = "[!]"
        size_s = human(size) + " B" if exists else "未生成"
        need = "必需" if f["must"] else "可选"
        print("    {0} {1}. {2:<20}{3:<11}{4:<13}{5:<8}{6}".format(
            mark, f["key"], f["name"], "0x{0:06X}".format(f["addr"]), size_s, need, f["desc"]))
        if not exists:
            hint = "先跑 pio run" if f["name"] != "littlefs.bin" else "先跑 pio run -t buildfs"
            if f["name"] == "firmware_merged.bin":
                hint = "先跑 pio run -t mergebin"
            if f["name"] == "boot_app0.bin":
                hint = "framework 包缺失，重装平台"
            print("            ^ 文件不存在（{0}）".format(hint))
    print_fw_info()
    clear_line()


def pick_files(selected):
    while True:
        show_files(selected)
        print("  命令：输入编号切换勾选（如 1,4） | a=全选 | n=清空 | app=只烧应用 | full=烧四个必需 | 回车=开烧")
        s = input("  > ").strip().lower()
        if s == "":
            break
        if s == "a":
            selected.update(f["key"] for f in FILES if os.path.exists(f["path"]))
            continue
        if s == "n":
            selected.clear()
            continue
        if s == "app":
            selected.clear()
            selected.add("4")
            continue
        if s == "full":
            selected.clear()
            selected.update(f["key"] for f in FILES if f["must"])
            continue
        keys = [x.strip() for x in s.replace("，", ",").split(",") if x.strip()]
        if keys and all(k in [f["key"] for f in FILES] for k in keys):
            for k in keys:
                if k in selected:
                    selected.discard(k)
                else:
                    selected.add(k)
            continue
        print("  无效输入。")

    # 互斥检查
    if "6" in selected and any(k in selected for k in ("1", "2", "3", "4")):
        print()
        print("  firmware_merged.bin（0x0）内部已经包含 bootloader/分区表/boot_app0/app，")
        print("  和 1~4 一起烧会互相覆盖。已自动改为只烧合并包。")
        selected = {"6"}
    # 存在性检查
    missing = [k for k in selected if not os.path.exists(next(f["path"] for f in FILES if f["key"] == k))]
    if missing:
        names = ", ".join(next(f["name"] for f in FILES if f["key"] == k) for k in missing)
        die("这些文件还不存在：" + names + "。先生成再烧。")
    if not selected:
        die("没有选中任何文件。", 0)
    return selected


# ---------- 烧录 ----------
def resolve_bin(spec):
    """--bin 的取值：一个 .bin 路径，或 3.3.1 这样的版本号（自动去交付目录找）。

    版本号用法是为"切回某个历史固件"准备的：交付目录里每个版本都留了
    firmware_X.Y.Z.bin，写版本号比背完整路径省事，也不用担心拼错。
    """
    if os.path.isfile(spec):
        return os.path.abspath(spec)

    ver = spec.strip()
    if not re.match(r"^\d+\.\d+\.\d+$", ver):
        die("--bin 只接受 .bin 路径或版本号（如 3.3.1）。收到：" + spec)

    root = os.path.join(os.path.dirname(PROJECT), "releases")
    hits = glob.glob(os.path.join(root, "*", "firmware_{0}.bin".format(ver)))
    if not hits:
        hits = glob.glob(os.path.join(root, "**", "firmware_{0}.bin".format(ver)), recursive=True)
    if not hits:
        die("没找到固件 {0}。\n"
            "        在 {1} 下没有 firmware_{0}.bin。\n"
            "        直接给路径：--bin \"D:\\...\\firmware.bin\"".format(ver, root))
    # 同一版本可能留了多份，取最新的
    hits.sort(key=os.path.getmtime, reverse=True)
    return hits[0]


def verify_board(port, expect_ver, seconds=6):
    """烧完立刻回读：复位板子，抓启动日志里的 `[fw] X.Y.Z`，与刚烧的版本对比。

    "esptool 说 Hash verified" 只证明写进去了，不证明它能跑起来（分区/启动链
    有问题时照样烧得进）。这一步是唯一能自动确认"板上真的在跑新版本"的手段。
    返回 True / False；环境不支持时返回 None（不当作失败）。
    """
    try:
        import serial
    except ImportError:
        print("  [跳过] 没有 pyserial，无法自动回读版本，请用 --diag 手工确认。")
        return None
    if not expect_ver or expect_ver == "未知":
        return None
    try:
        s = serial.Serial(port, 115200, timeout=0.4)
    except Exception as e:
        print("  [跳过] 打不开 {0}：{1}".format(port, e))
        return None

    buf = b""
    try:
        s.setDTR(False)
        s.setRTS(True)
        time.sleep(0.15)
        s.setRTS(False)                 # 释放复位，让板子重新启动
        t0 = time.time()
        while time.time() - t0 < seconds:
            d = s.read(512)
            if d:
                buf += d
    finally:
        try:
            s.close()
        except Exception:
            pass

    txt = buf.decode("utf-8", "replace")
    m = re.search(r"\[fw\]\s*([0-9]+\.[0-9]+\.[0-9]+)", txt)
    print()
    print("  ┌─ 板上实读确认（复位后 {0} 秒）──────────────".format(seconds))
    print("  │ 期望版本：{0}".format(expect_ver))
    if not m:
        print("  │ 实际版本：（没抓到 [fw] 行）")
        print("  │ 判读：板子没启动 / 串口被占 / 启动链不完整。")
        print("  │       先跑 --diag 看有没有启动日志。")
        print("  └────────────────────────────────────────────")
        return False
    got = m.group(1)
    ok = (got == expect_ver)
    print("  │ 实际版本：{0}   {1}".format(got, "✓ 一致" if ok else "✗ 不一致"))
    if not ok:
        print("  │ 说明烧进去的不是这份，或分区表指向另一个 app 分区。")
    print("  └────────────────────────────────────────────")
    return ok


def do_flash_bin(spec, port_forced, baud, assume_yes=False, verify=True):
    """烧任意一个 .bin 到 app 分区（0x10000），不编译、不动其它三个文件。"""
    path = resolve_bin(spec)
    if not os.path.exists(ESPTOOL):
        die("找不到 esptool.py：" + ESPTOOL)

    size  = os.path.getsize(path)
    ver   = fw_version(path) or "未知"
    mtime = datetime.datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M")

    print()
    print("  === 烧指定固件（只写应用本体）===")
    print("  文件    : " + path)
    print("  版本    : " + ver)
    print("  大小    : {0:,} B".format(size))
    print("  编译于  : " + mtime)
    print("  地址    : 0x010000")
    print()
    print("  只覆盖 app 分区。bootloader / partitions / boot_app0 不重写，")
    print("  所以纯切版本不需要烧那三个文件。")
    print()

    pair = paired_bitstream(ver)
    if pair:
        ptag, pfs, pmode = pair
        if pmode == "fw_only":
            print("  配套位流：{0}（该版只改 ESP32，位流不用重烧）".format(ptag))
            print("            文件仍是 " + os.path.basename(pfs))
        else:
            print("  配套位流：{0}  {1}".format(ptag, os.path.basename(pfs)))
            print("            固件和位流必须成对；板上若不是这一版 .fs，先用 Gowin Programmer 烧它。")
        print()

    ports = get_ports()
    port = pick_port(ports, port_forced, non_interactive=bool(assume_yes))

    sys_ports = all_com_ports()
    if sys_ports and port.upper() not in sys_ports:
        die("串口 {0} 现在不存在。现有：{1}".format(port, ", ".join(sorted(sys_ports))))

    print("  串口    : " + port)
    print()
    if not assume_yes:
        s = input("  确认烧录到 {0}？(y/N) ".format(port)).strip().lower()
        if s != "y":
            die("已取消。", 0)

    cmd = [sys.executable, ESPTOOL, "--chip", "esp32", "--port", port,
           "--baud", str(baud), "write_flash",
           "--flash_mode", "dio", "--flash_freq", "40m", "--flash_size", "4MB",
           "--compress", "--verify",
           "0x010000", path]

    print()
    print("  " + "=" * 62)
    r = run(cmd)
    print("  " + "=" * 62)
    if r.returncode == 0:
        print("  [成功] 已写入 {0}，版本 {1}".format(port, ver))
        print_bitstream_reminder(path)
        if verify:
            verify_board(port, ver)
        print()
        print("  确认板上实际版本：python tools\\flash_tool.py --diag")
        return 0
    print("  [失败] esptool 返回 {0}".format(r.returncode))
    print("  常见原因：串口被占用 / 没进下载模式（按住 BOOT，点一下 EN，松开） / 波特率太高")
    return 1


def do_flash(port, keys, baud, assume_yes=False, verify=True):
    picked = [f for f in FILES if f["key"] in keys]
    picked.sort(key=lambda f: f["addr"])

    if not os.path.exists(ESPTOOL):
        die("找不到 esptool.py：" + ESPTOOL)

    # 先编译，保证 build 目录里的是最新代码（只烧 build 产物时才需要）
    has_build_target = any(f["key"] in ("1", "2", "4", "5") for f in picked)
    if has_build_target and not keys == {"6"}:
        pio = find_pio()
        print()
        print("  [1/2] 先编译一遍（保证烧的是当前代码）...")
        r = run([pio, "run"])
        if r.returncode != 0:
            die("编译失败，未烧录。")

    cmd = [sys.executable, ESPTOOL, "--chip", "esp32", "--port", port,
           "--baud", str(baud), "write_flash",
           "--flash_mode", "dio", "--flash_freq", "40m", "--flash_size", "4MB",
           "--compress", "--verify"]
    for f in picked:
        cmd += ["0x{0:06X}".format(f["addr"]), f["path"]]

    print()
    print("  [2/2] 即将执行：")
    print_fw_info()
    print()
    for f in picked:
        print("        0x{0:06X}  {1}".format(f["addr"], f["name"]))
    print()
    print("  " + " ".join(cmd[:8]) + " ...")
    print()
    if not assume_yes:
        s = input("  确认烧录到 {0}？(y/N) ".format(port)).strip().lower()
        if s != "y":
            die("已取消。", 0)

    print()
    print("  " + "=" * 62)
    r = run(cmd)
    print("  " + "=" * 62)
    print()
    if r.returncode == 0:
        print("  [成功] 已写入 {0}，共 {1} 个文件。".format(port, len(picked)))
        print_bitstream_reminder()
        if verify and any(f["key"] == "4" for f in picked):
            verify_board(port, fw_version(os.path.join(BUILD, "firmware.bin")))
        print()
        print("  看启动日志：python tools/flash_tool.py --log --port " + port)
        return 0
    print("  [失败] esptool 返回 {0}".format(r.returncode))
    print("  常见原因：串口被占用 / 没进下载模式（按住 BOOT，点一下 EN/RST，松开） / 波特率太高")
    print("  降速重试：python tools/flash_tool.py --baud 115200")
    return 1


def do_log(port_forced):
    pio = find_pio()
    if not pio:
        die("找不到 pio.exe。")
    ports = get_ports()
    port = pick_port(ports, port_forced)
    print("  打开 {0} 日志（115200），退出按 Ctrl+C".format(port))
    return run([pio, "device", "monitor", "--port", port, "-b", "115200"]).returncode


def do_diag(port_forced, seconds=10):
    """链路诊断：复位 ESP32，抓启动日志，判读"收不到字节"卡在哪一层。

    依据（3.3.2 起固件自带）：
      - 主循环每 200 ms 发一次 STATUS 查询，线路通就一定有回包；
      - 收到前 96 字节时会打印一行 [sniff]，所以"[sniff] 没出现"就等于"零字节"。
    """
    try:
        import serial
    except ImportError:
        die("需要 pyserial。执行: python -m pip install pyserial")

    ports = get_ports()
    port = pick_port(ports, port_forced, non_interactive=True)

    print("  打开 {0}（115200），复位 ESP32，采集 {1} 秒（期间别碰板子）...".format(port, seconds))
    print()
    try:
        s = serial.Serial(port, 115200, timeout=0.4)
    except Exception as e:
        die("打不开 {0}：{1}".format(port, e))

    # 复位时序：EN 拉低再放开（DevKit 的自动复位电路把 DTR/RTS 接到 EN/IO0）
    s.setDTR(False)
    s.setRTS(True)
    time.sleep(0.2)
    s.setRTS(False)

    buf = b""
    t_end = time.time() + seconds
    while time.time() < t_end:
        d = s.read(512)
        if d:
            buf += d
    s.close()

    txt = buf.decode("utf-8", "replace")
    m_fw    = re.search(r"\[fw\]\s*(\d+\.\d+\.\d+)", txt)
    m_uart  = re.search(r"\[uart\]\s*(\d+)\s*bps\s*RX=(\w+)\s*TX=(\w+)", txt)
    m_sniff = re.search(r"\[sniff\] first (\d+) bytes from FPGA:[^\n]*\n(.*?)(?:\n\s*\n|\Z)", txt, re.S)

    print("  ---- 启动实况 ----")
    print("  固件版本 : " + (m_fw.group(1) if m_fw else "没抓到"))
    if m_uart:
        print("  链路串口 : {0} bps  RX={1}  TX={2}".format(m_uart.group(1), m_uart.group(2), m_uart.group(3)))
    print("  日志字节 : {0}".format(len(buf)))
    print()

    print("  ---- 判读 ----")
    if not m_fw:
        print("  [结论] 没有启动日志：固件没跑起来，或串口/波特率不对。")
        print("         先确认能烧录成功、网页能打开，再回来跑本命令。")
        return 2

    if not m_sniff:
        # [sniff] 是 3.3.2 才引入的。更老的固件不打印它，
        # 这时"没有 sniff"只说明工具不支持，不能当成"零字节"。
        vt = ver_tuple(m_fw.group(1))
        if vt is not None and vt < (3, 3, 2):
            print("  [结论] 固件 {0} 不带 [sniff] 抓包（3.3.2 才引入），".format(m_fw.group(1)))
            print("         所以本命令无法判断它到底有没有收到字节 —— 这不是故障结论。")
            print()
            print("  改用网页判断：打开 http://192.168.4.1/ →「链路状态」卡。")
            print("    · 3.1.x/3.2.x：只能看「好帧 / 坏帧」是否在涨")
            print("    · 3.3.x：额外有 收字节 / 帧头命中 / 前 8 字节，能一层层定位")
            print()
            print("  想用本命令做判读，先烧 3.3.2 或更新的固件。")
            return 4
        print("  [结论] {0} 秒内 FPGA 一个字节都没发。".format(seconds))
        print("         ESP32 每 200 ms 发一次 STATUS 查询，线路通的话这段时间")
        print("         至少该收到几百字节。零字节 = 物理层断开，不是协议问题。")
        print()
        print("  按这个顺序查：")
        print("   1) 共地 —— ESP32 的 GND 必须和 Tang 板的 GND 用一根线连上。")
        print("      只接 TX/RX 不接地，就是这个现象。")
        print("   2) 线序 —— ESP32 GPIO17(TX) -> FPGA E14；ESP32 GPIO16(RX) <- FPGA E13。")
        print("      两根接反也会完全收不到。")
        print("   3) 位流 —— FPGA 侧要跑带链路的位流（R25 及以后；当前是 R40）。")
        print("      没烧位流时 E13 不驱动，同样零字节。")
        print("   4) 引脚 —— 若模组是 WROVER（带 PSRAM），GPIO16/17 被 PSRAM 占用，")
        print("      需换引脚并同步改 kPinRx / kPinTx。")
        print()
        print("  10 秒定性：把 GPIO16 那端从 E13 拔下来、改接到 GPIO17，再跑一次本命令。")
        print("      出现 [sniff]  -> ESP32 侧正常，问题在外接线或 FPGA 位流。")
        print("      仍然零字节    -> ESP32 的 UART2 / GPIO16 本身有问题。")
        print("      注意：只换 GPIO16 这一根，别把两根直接短在一起（会与 E13 对撞）。")
        return 3

    n = int(m_sniff.group(1))
    hexs = []
    for line in m_sniff.group(2).splitlines():
        line = re.sub(r"^\s*[0-9A-Fa-f]{1,3}:", "", line)   # 去掉行首偏移 "  00:"
        hexs.extend(re.findall(r"\b[0-9A-Fa-f]{2}\b", line))
    print("  [结论] 收到了 {0} 字节，物理层是通的，问题在协议层。".format(n))
    if hexs:
        print("  前 16 字节: " + " ".join(h.upper() for h in hexs[:16]))
    sof = sum(1 for i in range(len(hexs) - 1)
              if hexs[i].upper() == "A5" and hexs[i + 1].upper() == "5A")
    print("  A5 5A 帧头: {0} 处".format(sof))
    if sof == 0:
        print("  -> 有字节但找不到帧头：波特率不对（应为 230400），")
        print("     或线太长/受干扰导致位错。先确认 FPGA 侧 LINK_UART_DIV=217。")
    else:
        print("  -> 帧头存在，说明波特率基本正确。接着看网页上的「LEN错 / CRC错」：")
        print("     CRC错在涨 = 丢字节（多半是接收缓冲或干扰），两者都 0 而好帧不涨 = FPGA 不认该命令。")
    return 0



def do_watch_enc(port_forced, seconds=25):
    """面板联调：复位后实时打印串口里的 `[enc]` 行，逐路确认按键/长按是否通。

    只读，不烧。**转动本身不在串口打印**（走网页的 `state.enc`），所以这里验证的是
    会打日志的动作：短按换弦 / 短按旁路 / 长按复位 / 静音态转音量。
    """
    try:
        import serial
    except ImportError:
        die("需要 pyserial：python -m pip install pyserial")

    ports = get_ports()
    port = pick_port(ports, port_forced, non_interactive=True)
    try:
        s = serial.Serial(port, 115200, timeout=0.3)
    except Exception as e:
        die("打不开 {0}：{1}".format(port, e))

    print()
    print("  打开 {0}（115200），接下来 {1} 秒请依次做：".format(port, seconds))
    print("    1) 短按 ENC3（最左第 3 个）  -> 应出现 `tune sel`")
    print("    2) 短按 ENC4（最右）          -> 应出现 `reverb`")
    print("    3) 长按任意一个 1.5 秒        -> 应出现 `PARAM RESET`")
    print("    4) 按 ENC1 静音后转它         -> 应出现 `vol resume`")
    print("  转动本身不打印，看网页「面板累计格数」。Ctrl+C 提前结束。")
    print()

    hits = {"tune sel": 0, "reverb": 0, "PARAM RESET": 0, "vol resume": 0}
    boot = []
    buf = ""
    t0 = None
    try:
        s.setDTR(False)
        s.setRTS(True)
        time.sleep(0.15)
        s.setRTS(False)
        t0 = time.time()
        while time.time() - t0 < seconds:
            chunk = s.read(256)
            if not chunk:
                continue
            buf += chunk.decode("utf-8", "replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.rstrip("\r")
                if "[enc]" not in line:
                    continue
                print("    " + line.strip())
                for k in hits:
                    if k in line:
                        hits[k] += 1
                if any(k in line for k in ("kPins", "A/B/SW", "镜像", "直连", "真值表", "引脚")):
                    boot.append(line.strip())
    except KeyboardInterrupt:
        print("\n  （已手动结束）")
    finally:
        try:
            s.close()
        except Exception:
            pass

    print()
    print("  ┌─ 判读 ───────────────────────────────────────")
    if boot:
        for b in boot:
            print("  │ " + b)
    else:
        print("  │ （没抓到启动行，可能复位不成功或串口被占）")
    print("  │")
    for k, label in (("tune sel", "ENC3 短按换弦"),
                     ("reverb", "ENC4 短按旁路"),
                     ("PARAM RESET", "长按复位"),
                     ("vol resume", "静音态转 ENC1")):
        n = hits[k]
        print("  │ {0:<16} {1}".format(label, "✓ 收到 {0} 次".format(n) if n else "— 没收到"))
    print("  │")
    if hits["PARAM RESET"] and not (hits["tune sel"] or hits["reverb"]):
        print("  │ 只有长按有反应、短按没有 → 短按被当成长按了？调小 kHoldMs 或检查 SW 抖动")
    print("  │ 全都没反应 -> 先看网页「按键电平」，四位不是 1/1/1/1 就是 SW 接线问题")
    print("  │ 3.5.10 起四路 SW 在 GPIO34/35/36/39：这四个脚**没有内部上拉**，")
    print("  │ 靠转接板 R1..R4 拉到 3V3；A/B 八根走内部上拉。电平乱跳先查那四颗电阻。")
    print("  │ 想确认「转的是哪个旋钮」（排线 1-1 还是 1<->14）：跑 --encprobe，")
    print("  │ 它会让你只转最左那颗，再按边沿计数直接给出结论。")
    print("  └──────────────────────────────────────────────")
    return 0


# ---------- 面板接线自检（固件 3.5.10 起） ----------
#
# 为什么需要单独一个命令：
#   排线是 "1-1 压接" 还是 "1<->14 反序压接"，两个 HC-2510 座的文件里都查不到。
#   两种接法下四个旋钮**都能动**，只是物理位置整体倒转，所以光看"能不能用"分不出来。
#   固件 3.5.10 把 12 个编码器 GPIO 的边沿各自计数并通过 /encprobe 暴露，
#   于是可以只转【最左】那颗，看哪两个数在涨 —— 涨的引脚就说明它接的是哪一路。
ESP32_AP = "http://192.168.4.1"

# 当前固件 kPins 的分组（3.5.10：ENC1 18/19/34 … ENC4 33/32/39）
PIN_LABEL = {
    18: "ENC1_A", 19: "ENC1_B", 34: "ENC1_SW",
    23: "ENC2_A", 25: "ENC2_B", 35: "ENC2_SW",
    26: "ENC3_A", 27: "ENC3_B", 36: "ENC3_SW",
    33: "ENC4_A", 32: "ENC4_B", 39: "ENC4_SW",
}


def _http_json(path, timeout=4.0):
    """读 ESP32 上的 JSON。192.168.4.1 是本地热点，必须绕开系统代理。"""
    import urllib.request
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(ESP32_AP + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def do_encprobe(wait_seconds=8):
    """面板接线自检：读 /encprobe 的 12 个 GPIO 边沿计数，判排线方向。

    只用 WiFi，不占串口；需要电脑连在 ESP32 热点（SSID Tang60K-Music）上。
    """
    print()
    print("  === 面板接线自检（走 WiFi，不碰串口）===")
    print("  前提：电脑连在 ESP32 的热点 Tang60K-Music 上（密码 tang60k2026）")
    print()
    try:
        first = _http_json("/encprobe?clr=1")
    except Exception as e:
        print("  [中止] 读不到 {0}/encprobe ：{1}".format(ESP32_AP, e))
        print("         1) 电脑是否连在 Tang60K-Music 热点上（不是家里的 WiFi）")
        print("         2) 固件是否 ≥ 3.5.10 —— 这个端点是 3.5.10 才加的")
        print("         3) 也可以直接用手机浏览器开 http://192.168.4.1/ 看「面板接线自检」卡片")
        print("         4) 只想看串口的话用 --watch-enc（验证按/长按，不验证转动）")
        return 2

    fw = first.get("fw", "?")
    print("  固件 {0}；计数已清零。接下来 {1} 秒请只做一件事：".format(fw, wait_seconds))
    print("    ▸ 转【最左】那颗旋钮约 5 格，慢一点；不要按，也不要转其它三个")
    print()
    t0 = time.time()
    while True:
        left = wait_seconds - int(time.time() - t0)
        if left <= 0:
            break
        sys.stdout.write("\r  采样中… 还剩 {0:2d} 秒  ".format(left))
        sys.stdout.flush()
        time.sleep(0.4)
    print("\r  采样结束。                ")

    try:
        second = _http_json("/encprobe")
    except Exception as e:
        die("第二次读取失败：{0}".format(e))

    pins = [int(x) for x in second.get("pins", [])]
    e1 = first.get("edges", [])
    e2 = second.get("edges", [])
    if not pins or len(e1) != len(pins) or len(e2) != len(pins):
        die("返回格式不对：{0}".format(second))

    delta = {}
    print()
    print("  {0:<6}{1:<10}{2:>8}".format("GPIO", "当前分组", "边沿增量"))
    print("  " + "-" * 28)
    for i, p in enumerate(pins):
        d = int(e2[i]) - int(e1[i])
        delta[p] = d
        print("  {0:<6}{1:<10}{2:>8}{3}".format(
            p, PIN_LABEL.get(p, "?"), d, "   <- 在动" if d else ""))

    total = sum(delta.values())
    enc1 = delta.get(18, 0) + delta.get(19, 0)
    enc4 = delta.get(33, 0) + delta.get(32, 0)
    sw1 = delta.get(34, 0)

    print()
    print("  ┌─ 判读 ───────────────────────────────────────")
    if total == 0:
        print("  │ 12 个脚一个边沿都没有 → 面板没通。按顺序查：")
        print("  │   1) 面板 GND 与 ESP32 GND 是否直连（最常见）")
        print("  │   2) 排线两头是否插到底（HC-2510 容易差一格）")
        print("  │   3) 转的是不是最左那颗")
    elif enc1 and not enc4:
        print("  │ ✓ 动的是 18/19（ENC1_A/B）→ 排线是【1↔14 反序】，")
        print("  │   当前固件的 kPins 表就是按这个接法写的，旋钮功能应该已经对位。")
        print("  │   如果这时功能仍错乱，看网页「按键电平」是不是 1/1/1/1。")
    elif enc4 and not enc1:
        print("  │ 动的是 32/33（当前表里属于 ENC4）→ 排线是【1-1 同向】，")
        print("  │   整组倒转了。两种修法二选一：")
        print("  │   a) 重新压一条反序排线（1↔14），不用改代码")
        print("  │   b) 改 encoder_panel.cpp 的 kPins 整组：")
        print("  │      ENC1 {39,33,32}  ENC2 {36,27,26}  ENC3 {35,25,23}  ENC4 {34,19,18}")
    elif enc1 and enc4:
        print("  │ 两组都在动 → 不只转了一个旋钮，或排线相邻两路串了。重测一次，只转最左。")
    elif sw1 and not (enc1 or enc4):
        print("  │ 动的是 34（ENC1_SW）而不是 A/B → A 与 SW 接反了：")
        print("  │   转被当成按压（会莫名换弦/切旁路）。查面板 1SW 与 1A 两根线是否互换。")
    else:
        print("  │ 动的不是 ENC1 的脚，但也只有一个旋钮在动 → 可能是 ENC2/ENC3 那一组，")
        print("  │ 说明排线整体偏移了一路以上，接线需要重新核对。")
    print("  │")
    print("  │ 边沿数就是电平跳变次数：转 5 格大约各涨 20~40，按一下只涨 2。")
    print("  └──────────────────────────────────────────────")
    return 0


# ---------- 主流程 ----------
def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--list", action="store_true", help="只列出串口与文件")
    ap.add_argument("--all", action="store_true", help="全选必需文件（快速模式）")
    ap.add_argument("--port", default=None, help="直接指定串口，如 COM7")
    ap.add_argument("--baud", type=int, default=921600, help="烧录波特率，默认 921600")
    ap.add_argument("--log", action="store_true", help="只看日志")
    ap.add_argument("--bin", default=None, metavar="路径|版本",
                    help="只烧指定固件到 0x10000，如 --bin 3.3.1 或 --bin D:\\x\\firmware.bin")
    ap.add_argument("--diag", action="store_true", help="链路诊断：复位后抓日志并判读")
    ap.add_argument("--check", action="store_true",
                    help="不烧，只回读板上版本并与 build 对比（判断要不要重烧）")
    ap.add_argument("--watch-enc", action="store_true",
                    help="面板联调：复位后实时打印 [enc] 日志，逐路确认按键/长按是否通")
    ap.add_argument("--encprobe", action="store_true",
                    help="面板接线自检：转最左旋钮，读 /encprobe 判排线方向（走 WiFi）")
    ap.add_argument("--encwait", type=int, default=8, metavar="秒",
                    help="--encprobe 的采样时长，默认 8 秒")
    ap.add_argument("--no-verify", action="store_true",
                    help="烧完不回读板上版本（默认会复位并抓 [fw] 行确认）")
    ap.add_argument("--yes", action="store_true", help="跳过确认")
    args = ap.parse_args()

    print()
    print("  === ESP32 烧录工具 ===")
    print("  工程: " + PROJECT)
    print_fw_info(pairing=not args.bin)

    ports = get_ports()

    if args.list:
        print()
        print("  【串口】")
        if not ports:
            print("    没有 USB 串口")
        for p in ports:
            tag = p["note"] or "未识别"
            print("    {0:<7} {1:<32} {2:<11} {3}".format(p["port"], p["desc"][:32], p["vidpid"] or "", tag))
        print()
        print("  【可烧录文件】")
        for f in FILES:
            exists, size = file_info(f)
            print("    {0}. {1:<20} 0x{2:06X}  {3:<12} {4}{5}".format(
                f["key"], f["name"], f["addr"],
                (human(size) + " B") if exists else "未生成",
                "必需" if f["must"] else "可选",
                "" if exists else "   (不存在)"))
        print()
        return 0

    if args.check:
        port = pick_port(ports, args.port, non_interactive=True)
        build_ver = fw_version(os.path.join(BUILD, "firmware.bin")) or "未知"
        ok = verify_board(port, build_ver, seconds=8)
        if ok is True:
            print("  板上就是 build 这一版，不用重烧。")
        elif ok is False:
            print("  板上与 build 不一致 —— 要同步就跑：python tools\\flash_tool.py --all --yes")
        return 0 if ok is not False else 1

    if args.bin:
        return do_flash_bin(args.bin, args.port, args.baud,
                            assume_yes=bool(args.yes), verify=not args.no_verify)

    if args.encprobe:
        return do_encprobe(max(3, args.encwait))

    if args.watch_enc:
        return do_watch_enc(args.port)

    if args.diag:
        return do_diag(args.port)

    if args.log:
        return do_log(args.port)

    print()
    print("  [1/3] 选择串口")
    port = pick_port(ports, args.port, non_interactive=bool(args.yes))

    # 端口存在性校验：口号不存在（板子没插/线松/换了口号）就当场说清楚，
    # 不要等到 esptool 抛 "could not open port" 再让你猜是驱动还是占用。
    sys_ports = all_com_ports()
    if sys_ports and port.upper() not in sys_ports:
        die("串口 {0} 现在不存在。板子可能没插上、USB 线松了、或换了个口号。\n"
            "        系统里现有的串口：{1}\n"
            "        重新插好后跑 `python tools\\flash_tool.py --list` 看新口号。".format(
                port, ", ".join(sys_ports)))

    print()
    print("  [2/3] 选择要烧录的文件")
    if args.all:
        selected = set(f["key"] for f in FILES if f["must"])
        show_files(selected)
        print("  --all 已选中四个必需文件。")
    else:
        selected = set(f["key"] for f in FILES if f["must"] and os.path.exists(f["path"]))
        selected = pick_files(selected)

    print()
    print("  [3/3] 烧录")
    return do_flash(port, selected, args.baud, args.yes, verify=not args.no_verify)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        print("  已中断。")
        sys.exit(130)
