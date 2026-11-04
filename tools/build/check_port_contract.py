#!/usr/bin/env python3
"""比较两个 Verilog 模块的端口集合，输出断链风险。只读，不改文件。

背景：把显示模块换掉时，新模块少几个端口不会报错（隐式线网），
功能静默消失。本脚本把这类差异变成可判定的输出。

用法:
    python check_port_contract.py <baseline.v> <candidate.v>

退出码 0 = 端口完全一致；1 = 存在差异。
"""
import re
import sys

PORT_RE = re.compile(
    r"\b(input|output|inout)\b\s*(?:wire|reg)?\s*(signed)?\s*(\[[^\]]+\])?\s*([A-Za-z_]\w*)")


def ports(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    # 截取 module 到端口表结束的 ');'
    m = re.search(r"\bmodule\s+(\w+)\s*\((.*?)\)\s*;", src, re.S)
    if not m:
        sys.exit("找不到 module 端口表: %s" % path)
    table = {}
    for _dir, signed, rng, name in PORT_RE.findall(m.group(2)):
        table[name] = ((rng or "[0:0]").replace(" ", ""), signed == "signed")
    return m.group(1), table


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    na, pa = ports(sys.argv[1])
    nb, pb = ports(sys.argv[2])

    missing = ["%s%s" % (n, pa[n][0]) for n in pa if n not in pb]
    extra = ["%s%s" % (n, pb[n][0]) for n in pb if n not in pa]
    width = ["%s: %s vs %s" % (n, pa[n][0], pb[n][0])
             for n in pa if n in pb and pa[n][0] != pb[n][0]]
    sign = [n for n in pa if n in pb and pa[n][1] != pb[n][1]]

    print("A = %s (%d ports)" % (na, len(pa)))
    print("B = %s (%d ports)" % (nb, len(pb)))
    print("MISSING in B: %s" % (" ".join(missing) or "(none)"))
    print("EXTRA in B:   %s" % (" ".join(extra) or "(none)"))
    print("WIDTH MISMATCH: %s" % ("; ".join(width) or "(none)"))
    print("SIGN MISMATCH:  %s" % (" ".join(sign) or "(none)"))
    print("---")
    if missing or extra or width or sign:
        print("结论：端口集合不一致，直接替换会断链。")
        return 1
    print("结论：端口集合一致。仍需检查语义（位宽相同不代表含义相同）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
