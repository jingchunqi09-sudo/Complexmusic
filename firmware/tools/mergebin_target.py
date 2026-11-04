# PlatformIO 自定义目标：pio run -t mergebin
# 调 tools/merge_bin.py 生成单文件烧录包，不改动正常编译流程。
Import("env")
import os

_proj = env.subst("$PROJECT_DIR")
_script = os.path.join(_proj, "tools", "merge_bin.py")
_py = env.subst("$PYTHONEXE")

env.AddCustomTarget(
    name="mergebin",
    dependencies=["$BUILD_DIR/${PROGNAME}.bin"],
    actions=['"%s" "%s"' % (_py, _script)],
    title="mergebin",
    description="合并 bootloader/partitions/boot_app0/app 为 firmware_merged.bin（烧到 0x0）",
)
