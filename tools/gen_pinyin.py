# -*- coding: utf-8 -*-
"""从 C# `DH.NCore/Common/PinYin.cs` 生成 Zig 侧的查表数据。

为什么不在 Zig 里现场做 GB2312 编码：Zig 标准库没有 GB2312 码表，而 C# 版本的
`Get(ch)` 完全建立在「GB2312 机内码 + 三张表」之上。这里用 Python 的 gb2312 编解码器
**按 C# 逐行同样的算法**预先算好每个汉字的拼音，生成一张
`Unicode(0x4E00..0x9FA5) -> 拼音名下标` 的定长表，Zig 侧只做一次 O(1) 查表。

输出：
- `src/pinyin_table.bin`：20902 × u16（小端）。`0xFFFF` = C# 返回空串；`0xFFFE` = 原样返回该字；
  其余为 `pinyin_table.zig` 里 `names` 的下标。
- `src/pinyin_table.zig`：拼音名数组（含二级/三级表里出现的全拼）。

用法：`python tools/gen_pinyin.py`（在仓库根运行）
"""

import io
import os
import re
import sys

SRC = r"G:\Code\Pek.FrameWork\DH.NCore\DH.NCore\Common\PinYin.cs"
FIRST = 0x4E00
LAST = 0x9FA5
EMPTY = 0xFFFF
SELF = 0xFFFE


def grab(text, name):
    """取 `private static readonly T[] name = [ ... ];` 的正文。"""
    m = re.search(re.escape(name) + r"\s*=\s*\[(.*?)\];", text, re.S)
    if not m:
        raise SystemExit("找不到数组 " + name)
    return m.group(1)


def ints(body):
    return [int(x) for x in re.findall(r"-?\d+", body)]


def strings(body):
    return re.findall(r'"([^"]*)"', body)


def chars(body):
    return re.findall(r"'([^']*)'", body)


def main():
    text = io.open(SRC, encoding="utf-8").read()

    py_value = ints(grab(text, "pyValue"))
    py_name = strings(grab(text, "pyName"))
    py2_chars = chars(grab(text, "_py2"))
    py2_values = strings(grab(text, "_pyValue2"))
    py3_chars = chars(grab(text, "_py3"))
    py3_values = strings(grab(text, "_pyValue3"))

    print("pyValue=%d pyName=%d _py2=%d/%d _py3=%d/%d"
          % (len(py_value), len(py_name), len(py2_chars), len(py2_values),
             len(py3_chars), len(py3_values)))

    if len(py2_chars) != len(py2_values):
        raise SystemExit("_py2 与 _pyValue2 长度不一致")
    if len(py3_chars) != len(py3_values):
        raise SystemExit("_py3 与 _pyValue3 长度不一致")
    if len(py_value) != len(py_name):
        raise SystemExit("pyValue 与 pyName 长度不一致")

    py2_index = {c: i for i, c in enumerate(py2_chars)}
    py3_index = {c: i for i, c in enumerate(py3_chars)}

    first_ch_code = -20319
    last_ch_code = -2050
    last_of_one_level = -10247

    names = list(py_name)
    name_index = {n: i for i, n in enumerate(names)}

    def intern(name):
        if name not in name_index:
            name_index[name] = len(names)
            names.append(name)
        return name_index[name]

    def py_of(ch):
        """与 C# PinYin.Get 完全同样的判定顺序。返回下标或 EMPTY/SELF。"""
        try:
            b = ch.encode("gb2312")
        except UnicodeEncodeError:
            return SELF
        if len(b) < 2:
            return SELF
        c = b[0] * 256 + b[1] - 65536
        if 0 < c < 160:
            return SELF

        if c > last_ch_code or c < first_ch_code:
            i = py3_index.get(ch)
            return intern(py3_values[i]) if i is not None else SELF

        if c <= last_of_one_level:
            for k in range(11, -1, -1):
                p = k * 33
                if c >= py_value[p]:
                    for i in range(p + 32, p - 1, -1):
                        if py_value[i] <= c:
                            return intern(py_name[i])
                    break
            return EMPTY

        i = py2_index.get(ch)
        if i is not None:
            v = py2_values[i]
            return intern(v[0].upper() + v[1:])

        i = py3_index.get(ch)
        if i is not None:
            return intern(py3_values[i])
        return EMPTY

    table = bytearray()
    hits = 0
    for cp in range(FIRST, LAST + 1):
        v = py_of(chr(cp))
        if v not in (EMPTY, SELF):
            hits += 1
        table += bytes((v & 0xFF, (v >> 8) & 0xFF))

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    bin_path = os.path.join(root, "src", "pinyin_table.bin")
    with open(bin_path, "wb") as f:
        f.write(table)

    lines = []
    lines.append("//! 由 `tools/gen_pinyin.py` 生成，请勿手改。")
    lines.append("//!")
    lines.append("//! 源：C# `DH.NCore/DH.NCore/Common/PinYin.cs` 的 `pyName` + `_pyValue2` + `_pyValue3`。")
    lines.append("//! 改拼音表请改 C# 源后重新生成，不要在 Zig 侧手改。")
    lines.append("")
    lines.append("/// 拼音名（下标与 `pinyin_table.bin` 里的值对应）")
    lines.append("pub const names = [_][]const u8{")
    for i in range(0, len(names), 8):
        chunk = ", ".join('"%s"' % n for n in names[i:i + 8])
        lines.append("    " + chunk + ",")
    lines.append("};")
    lines.append("")
    lines.append("/// 码表覆盖的 Unicode 区间起点（含）")
    lines.append("pub const first_code: u32 = 0x%04X;" % FIRST)
    lines.append("/// 码表覆盖的 Unicode 区间终点（含）")
    lines.append("pub const last_code: u32 = 0x%04X;" % LAST)
    lines.append("")
    lines.append("test \"码表长度与区间一致\" {")
    lines.append("    const bin = @embedFile(\"pinyin_table.bin\");")
    lines.append("    try @import(\"std\").testing.expectEqual((last_code - first_code + 1) * 2, bin.len);")
    lines.append("}")
    lines.append("")

    zig_path = os.path.join(root, "src", "pinyin_table.zig")
    io.open(zig_path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))

    print("汉字 %d 个，其中可转拼音 %d 个；names=%d；bin=%d 字节"
          % (LAST - FIRST + 1, hits, len(names), len(table)))


if __name__ == "__main__":
    sys.exit(main())
