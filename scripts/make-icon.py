#!/usr/bin/env python3
"""生成 App 图标：墨底 squircle + 三个点 + 一条线（「一条路」的图标母题）。

色值直接取自 Sources/LeapinApp/Design/Theme.swift，不另调一套：
  ink      dyn(hex(0x19191B), hex(0x1C1C1F))  -> 深/浅两套 appearances 里取浅色那支
  accent   dyn(hex(0xC63A12), hex(0xFF7A4D))  -> 同上
  text     0xF3F1EA（纸面文字色，用作两个端点）
顶部一层极轻的竖向渐变，避免纯平像贴在桌面上的色块。

用法（需要 Pillow + macOS 的 iconutil）：
  python3 scripts/make-icon.py
产物：
  Assets/AppIcon.png   1024×1024 源图
  Assets/AppIcon.icns  16–1024 全套
"""
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

SIZE = 1024
INK_TOP = (35, 35, 38)        # 0x19191B 之上提一档，仅用于渐变起点
INK_BOTTOM = (25, 25, 27)     # LP.ink = 0x19191B
PAPER = (243, 241, 234, 255)  # LP.text = 0xF3F1EA
ACCENT = (198, 58, 18, 255)   # LP.accent = 0xC63A12

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def rounded_mask(size, margin=84, radius=186):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (margin, margin, size - margin, size - margin), radius=radius, fill=255
    )
    return mask


def vertical_gradient(size, top, bottom):
    column = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        column.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return column.resize((size, size))


def build():
    mask = rounded_mask(SIZE)
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    img.paste(vertical_gradient(SIZE, INK_TOP, INK_BOTTOM), (0, 0), mask)

    d = ImageDraw.Draw(img)
    y = SIZE // 2
    xs = [286, SIZE // 2, 738]
    for a, b in ((xs[0], xs[1]), (xs[1], xs[2])):
        d.line((a, y, b, y), fill=(243, 241, 234, 82), width=12)
    for cx, radius, fill in ((xs[0], 54, PAPER), (xs[1], 40, ACCENT), (xs[2], 54, PAPER)):
        d.ellipse((cx - radius, y - radius, cx + radius, y + radius), fill=fill)
    return img


def write_outputs(img):
    png = os.path.join(ROOT, "Assets", "AppIcon.png")
    img.save(png)

    iconset = tempfile.mkdtemp(suffix=".iconset")
    for size, name in [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]:
        img.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))

    icns = os.path.join(ROOT, "Assets", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    return png, icns


if __name__ == "__main__":
    png, icns = write_outputs(build())
    print("wrote", png)
    print("wrote", icns)
