#!/usr/bin/env python3
"""令牌对比度复算。数值取自 Sources/LeapinApp/Design/Theme.swift 的 LP 令牌（v7）。

跑法：python3 scripts/contrast_check.py
退出码：全部 >= 4.5:1 为 0，否则 1（正文标准 WCAG 2.2 AA）。

墨带在两种模式里都是深色，墨上的文字是「白按透明度叠在墨上」的合成色，这里按
alpha 混合先算出实际像素色再算对比度，和 `LP.onInk *` 三个令牌一一对应。
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


def blend(white_alpha: float, bg: int) -> int:
    """白按 white_alpha 叠在 bg 上的实际像素色（Theme 里的 Color.white.opacity）。"""
    r, g, b = (bg >> 16) & 255, (bg >> 8) & 255, bg & 255
    mix = lambda c: round(255 * white_alpha + c * (1 - white_alpha))
    return (mix(r) << 16) | (mix(g) << 8) | mix(b)


# LP 令牌（Theme.swift）
PAPER_L, PAPER_D = 0xF4EFE6, 0x0F0F10
SHEET_L, SHEET_D = 0xFDFBF7, 0x1A1A1E
INK_L, INK_D = 0x19191B, 0x26262B
TEXT_L, TEXT_S_L, TEXT_T_L = 0x16150F, 0x5F5C53, 0x6F6B60
TEXT_D, TEXT_S_D, TEXT_T_D = 0xF3F1EA, 0xA6A39A, 0x87847B
ACCENT_L, ACCENT_D = 0xC63A12, 0xFF7A4D
ACCENT_FILL_L, ACCENT_FILL_D = 0xB83510, 0xC2410F
WHITE = 0xFFFFFF

# onInk：白在两种墨上的三档合成色
ON_INK_L = blend(0.94, INK_L)
ON_INK_S_L = blend(0.66, INK_L)
ON_INK_T_L = blend(0.50, INK_L)
ON_INK_D = blend(0.94, INK_D)
ON_INK_S_D = blend(0.66, INK_D)
ON_INK_T_D = blend(0.50, INK_D)

PAIRS = [
    # 浅色：纸面与卡
    ("light 正文 on 卡", TEXT_L, SHEET_L),
    ("light 次级 on 卡", TEXT_S_L, SHEET_L),
    ("light 三级 on 卡", TEXT_T_L, SHEET_L),
    ("light 正文 on 纸", TEXT_L, PAPER_L),
    ("light 次级 on 纸", TEXT_S_L, PAPER_L),
    ("light 三级 on 纸", TEXT_T_L, PAPER_L),
    ("light 朱红 on 纸（计数）", ACCENT_L, PAPER_L),
    ("light 朱红 on 卡", ACCENT_L, SHEET_L),
    ("light 白字 on 朱红按钮", WHITE, ACCENT_FILL_L),
    # 深色：纸面与卡
    ("dark 正文 on 卡", TEXT_D, SHEET_D),
    ("dark 次级 on 卡", TEXT_S_D, SHEET_D),
    ("dark 三级 on 卡", TEXT_T_D, SHEET_D),
    ("dark 正文 on 纸", TEXT_D, PAPER_D),
    ("dark 次级 on 纸", TEXT_S_D, PAPER_D),
    ("dark 三级 on 纸", TEXT_T_D, PAPER_D),
    ("dark 朱红 on 纸（计数）", ACCENT_D, PAPER_D),
    ("dark 白字 on 朱红按钮", WHITE, ACCENT_FILL_D),
    # 墨带（两种模式同一段代码、不同的墨）
    ("light 墨带 正文", ON_INK_L, INK_L),
    ("light 墨带 次级", ON_INK_S_L, INK_L),
    ("light 墨带 三级", ON_INK_T_L, INK_L),
    ("light 墨带 朱红", 0xFF7A4D, INK_L),
    ("dark 墨带 正文", ON_INK_D, INK_D),
    ("dark 墨带 次级", ON_INK_S_D, INK_D),
    ("dark 墨带 三级", ON_INK_T_D, INK_D),
    ("dark 墨带 朱红", 0xFF7A4D, INK_D),
]

worst = 99.0
worst_name = ""
for name, fg, bg in PAIRS:
    r = ratio(fg, bg)
    if r < worst:
        worst, worst_name = r, name
    print("%-30s %5.2f:1  %s" % (name, r, "OK" if r >= 4.5 else "LOW"))

print("\n最低 %.2f:1（%s；门槛 4.5:1，正文 AA）" % (worst, worst_name))
raise SystemExit(0 if worst >= 4.5 else 1)
