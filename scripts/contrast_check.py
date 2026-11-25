#!/usr/bin/env python3
"""v6 令牌对比度复算。数值取自 Sources/LeapinApp/Design/Theme.swift 的 LP 令牌。

跑法：python3 scripts/contrast_check.py
退出码：全部 >= 4.5:1 为 0，否则 1（正文标准 WCAG 2.2 AA）。
"""

def lin(c: float) -> float:
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(v: int) -> float:
    r, g, b = (v >> 16) & 255, (v >> 8) & 255, v & 255
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def ratio(fg: int, bg: int) -> float:
    a, b = lum(fg), lum(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


# LP 令牌（Theme.swift）
TEXT_L, TEXT_S_L, TEXT_T_L = 0x16150F, 0x5F5C53, 0x6F6B60
ACCENT_L, PANEL_L, PAPER_L = 0xC63A12, 0xFCFBF8, 0xF4EFE6
TEXT_D, TEXT_S_D, TEXT_T_D = 0xF3F1EA, 0xA6A39A, 0x87847B
ACCENT_D, PANEL_D, PAPER_D = 0xFF7A4D, 0x151517, 0x0F0F10

PAIRS = [
    ("light 正文 on 面板", TEXT_L, PANEL_L),
    ("light 次级 on 面板", TEXT_S_L, PANEL_L),
    ("light 三级 on 面板", TEXT_T_L, PANEL_L),
    ("light 正文 on 书脊纸", TEXT_L, PAPER_L),
    ("light 次级 on 书脊纸", TEXT_S_L, PAPER_L),
    ("light 三级 on 书脊纸（来源小字）", TEXT_T_L, PAPER_L),
    ("light 朱红 on 书脊纸（计数）", ACCENT_L, PAPER_L),
    ("dark 正文 on 面板", TEXT_D, PANEL_D),
    ("dark 次级 on 面板", TEXT_S_D, PANEL_D),
    ("dark 三级 on 面板", TEXT_T_D, PANEL_D),
    ("dark 正文 on 书脊纸", TEXT_D, PAPER_D),
    ("dark 次级 on 书脊纸", TEXT_S_D, PAPER_D),
    ("dark 三级 on 书脊纸（来源小字）", TEXT_T_D, PAPER_D),
    ("dark 朱红 on 书脊纸（计数）", ACCENT_D, PAPER_D),
]

worst = 99.0
for name, fg, bg in PAIRS:
    r = ratio(fg, bg)
    worst = min(worst, r)
    print("%-34s %5.2f:1  %s" % (name, r, "OK" if r >= 4.5 else "LOW"))

print("\n最低 %.2f:1（门槛 4.5:1，正文 AA）" % worst)
raise SystemExit(0 if worst >= 4.5 else 1)
