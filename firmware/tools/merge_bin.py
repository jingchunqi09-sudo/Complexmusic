#!/usr/bin/env python3
# ============================================================
# merge_bin.py —— 把四个分区镜像合并成一个可直接烧到 0x0 的文件
#
# 输入（全部由 pio run 生成）：
#   .pio/build/esp32dev/bootloader.bin            烧到 0x1000
#   .pio/build/esp32dev/partitions.bin            烧到 0x8000
#   framework .../tools/partitions/boot_app0.bin  烧到 0xe000
#   .pio/build/esp32dev/firmware.bin              烧到 0x10000
#
# 输出：.pio/build/esp32dev/firmware_merged.bin
# 用法：python tools/merge_bin.py
#      或 pio run -t mergebin
# ============================================================
import hashlib
import os
import subprocess
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(PROJ, ".pio", "build", "esp32dev")
OUT = os.path.join(BUILD, "firmware_merged.bin")

# ESP32 4MB flash 的标准偏移
ADDR_BOOTLOADER = 0x1000
ADDR_PARTITIONS = 0x8000
ADDR_BOOT_APP0 = 0xE000
ADDR_APP = 0x10000

PIO_HOME = os.environ.get("PLATFORMIO_CORE_DIR") or os.path.join(
    os.path.expanduser("~"), ".platformio")


def need(path, what):
    if not os.path.isfile(path):
        sys.exit("[ERR] 找不到%s：%s\n      请先执行 pio run" % (what, path))
    return path


def find_esptool():
    p = os.path.join(PIO_HOME, "packages", "tool-esptoolpy", "esptool.py")
    return need(p, " esptool.py")


def find_boot_app0():
    p = os.path.join(PIO_HOME, "packages", "framework-arduinoespressif32",
                     "tools", "partitions", "boot_app0.bin")
    return need(p, " boot_app0.bin")


def main():
    esptool = find_esptool()
    bootloader = need(os.path.join(BUILD, "bootloader.bin"), " bootloader.bin")
    partitions = need(os.path.join(BUILD, "partitions.bin"), " partitions.bin")
    app = need(os.path.join(BUILD, "firmware.bin"), " firmware.bin")
    boot_app0 = find_boot_app0()

    cmd = [
        sys.executable, esptool,
        "--chip", "esp32", "merge_bin",
        "-o", OUT,
        "--flash_mode", "dio",
        "--flash_freq", "40m",
        "--flash_size", "4MB",
        "0x%x" % ADDR_BOOTLOADER, bootloader,
        "0x%x" % ADDR_PARTITIONS, partitions,
        "0x%x" % ADDR_BOOT_APP0, boot_app0,
        "0x%x" % ADDR_APP, app,
    ]
    print("[1/2] 合并镜像 …")
    print("      " + " ".join('"%s"' % c if " " in c else c for c in cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        sys.exit("[ERR] merge_bin 失败（返回码 %d）" % r.returncode)

    size = os.path.getsize(OUT)
    with open(OUT, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    print("[2/2] 完成")
    print("      输出: %s" % OUT)
    print("      大小: %.1f KB" % (size / 1024.0))
    print("      SHA256: %s" % sha)
    print("      烧录地址: 0x0（整片烧写，Flash Download Tool 的起始地址填 0x0）")


if __name__ == "__main__":
    main()
