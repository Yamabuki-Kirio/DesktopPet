#!/usr/bin/env python3
"""生成 PetLife 的 APK 图标与启动页资源（可复现）。

设计（原创，不使用任何动漫角色 / 商标 / 文字）：
  * 白色圆角方形底（主色 #FFFFFF）
  * 粉色放射环（强调色 #F24D96）
  * 中央粉色圆盘 + **白色爪印**
  * 无文字、无角色

产出：
  android/app/src/main/res/mipmap-*/ic_launcher.png            传统图标（API < 26）
  android/app/src/main/res/mipmap-*/ic_launcher_round.png      传统圆形图标
  android/app/src/main/res/mipmap-*/ic_launcher_foreground.png adaptive icon 前景层
  android/app/src/main/res/drawable-*/splash_petlife.png       启动页位图（图标 + PetLife + 粉色加载线）

adaptive icon 的**背景层**是纯色 `@color/ic_launcher_background`（白色），
因此不需要位图；前景层内容全部落在 108dp 画布的中央 66dp 安全圆内，
无论启动器用圆形、方形还是水滴形遮罩都不会被裁掉。

用法：
  python tools/make_app_icon.py
"""

from __future__ import annotations

import math
import os
from PIL import Image, ImageDraw

# --- 设计令牌（与 lib/ui/theme/design_tokens.dart 保持一致）---
PRIMARY = (255, 255, 255, 255)      # #FFFFFF
ACCENT = (242, 77, 150, 255)        # #F24D96
TEXT_PRIMARY = (42, 21, 48, 255)    # #2A1530

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(REPO, "android", "app", "src", "main", "res")

# 5 档密度的缩放因子（mdpi 为基准）
DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}

# 超高分辨率绘制后再缩小，得到平滑边缘（抗锯齿）
SUPERSAMPLE = 4


def _paw(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float,
         color: tuple[int, int, int, int]) -> None:
    """在 (cx, cy) 处画一个爪印，整体半径约 r。

    结构：下方一个掌垫 + 上方四个**分开的**脚趾豆。
    刻意让脚趾与掌垫之间留出空隙 —— 否则小尺寸下会糊成一团圆饼。
    """
    # 掌垫：略宽的圆角形状，位于爪印下半部
    pad_hw = r * 0.56
    pad_hh = r * 0.44
    pad_cy = cy + r * 0.44
    draw.ellipse(
        [cx - pad_hw, pad_cy - pad_hh, cx + pad_hw, pad_cy + pad_hh],
        fill=color,
    )

    # 四个脚趾豆：中间两个更高、更小，外侧两个更低。
    # 半径刻意小于间距的一半，保证小尺寸下四个豆**互不相连**。
    toes = [
        (-0.72, -0.14, 0.19),
        (-0.30, -0.52, 0.21),
        (0.30, -0.52, 0.21),
        (0.72, -0.14, 0.19),
    ]
    for tx, ty, tr in toes:
        x = cx + tx * r
        y = cy + ty * r
        rad = tr * r
        draw.ellipse([x - rad, y - rad, x + rad, y + rad], fill=color)


def draw_mark(size: int, *, burst: bool, disc: bool) -> Image.Image:
    """画出「粉色圆盘 + 放射环 + 爪印」的标记（透明底）。

    [burst] 是否画粉色短放射线；[disc] 是否画中央粉色圆盘（此时爪印为白色）。
    """
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = cy = s / 2.0
    disc_r = s * 0.30

    if burst:
        # 12 条**短**放射线紧贴圆盘外沿：读起来是"放射环"而不是太阳。
        rays = 12
        for i in range(rays):
            angle = (2 * math.pi * i) / rays - math.pi / 2
            long_ray = i % 2 == 0
            r_in = disc_r * (1.02 if long_ray else 1.10)
            r_out = disc_r * (1.42 if long_ray else 1.28)
            width = max(1, int(s * (0.030 if long_ray else 0.022)))
            x0 = cx + math.cos(angle) * r_in
            y0 = cy + math.sin(angle) * r_in
            x1 = cx + math.cos(angle) * r_out
            y1 = cy + math.sin(angle) * r_out
            d.line([x0, y0, x1, y1], fill=ACCENT, width=width)
            for (px, py) in ((x0, y0), (x1, y1)):
                d.ellipse(
                    [px - width / 2, py - width / 2, px + width / 2, py + width / 2],
                    fill=ACCENT,
                )

    if disc:
        d.ellipse(
            [cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r],
            fill=ACCENT,
        )
        _paw(d, cx, cy - disc_r * 0.06, disc_r * 0.62, PRIMARY)
    else:
        _paw(d, cx, cy, s * 0.30, TEXT_PRIMARY)

    return img.resize((size, size), Image.LANCZOS)


def rounded_square(size: int, mark_ratio: float,
                   bg: tuple[int, int, int, int]) -> Image.Image:
    """白色圆角方形底 + 居中标记（[mark_ratio] 控制标记占整体宽度的比例）。"""
    s = size * SUPERSAMPLE
    base = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(base)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 0.22), fill=bg)
    inner = int(round(s * mark_ratio))
    base.alpha_composite(
        draw_mark(inner, burst=True, disc=True),
        ((s - inner) // 2, (s - inner) // 2),
    )
    return base.resize((size, size), Image.LANCZOS)


def circle_icon(size: int, mark_ratio: float) -> Image.Image:
    """传统圆形图标（ic_launcher_round）。"""
    s = size * SUPERSAMPLE
    base = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(base)
    d.ellipse([0, 0, s - 1, s - 1], fill=PRIMARY)
    inner = int(round(s * mark_ratio))
    base.alpha_composite(
        draw_mark(inner, burst=True, disc=True),
        ((s - inner) // 2, (s - inner) // 2),
    )
    return base.resize((size, size), Image.LANCZOS)


def adaptive_foreground(size: int) -> Image.Image:
    """adaptive icon 前景层：108dp 画布，内容收在中央 66dp 安全圆内。

    这里画布本身就是 108dp，标记只占中间约 61% —— 于是无论启动器用
    圆形 / 方形 / 水滴形遮罩，爪印与放射环都不会被切掉。
    """
    s = size * SUPERSAMPLE
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    inner = int(s * 0.61)
    mark = draw_mark(inner, burst=True, disc=True)
    offset = (s - inner) // 2
    canvas.alpha_composite(mark, (offset, offset))
    return canvas.resize((size, size), Image.LANCZOS)

def splash_image(width: int) -> Image.Image:
    """启动页位图：中央图标 + 下方 PetLife + 一条粉色加载线。"""
    height = int(width * 1.15)
    s = SUPERSAMPLE
    w, h = width * s, height * s
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 图标：白色圆角方形底会与暖白背景连成一片，因此这里只用标记本身，
    # 保证启动页是"白色背景 + 中央图标"。
    icon = int(w * 0.42)
    mark = draw_mark(icon, burst=True, disc=True)
    img.alpha_composite(mark, ((w - icon) // 2, int(h * 0.20)))

    # 「PetLife」用几何块拼出，不依赖任何字体（避免不同机器字形不一致）。
    # 字号由**可用宽度**反推，保证永远不超出画布（否则会被裁掉首尾字母）。
    cols = len("PetLife") * 6 - 1
    unit = min(int(w * 0.030), max(2, int(w * 0.74) // cols))
    _block_text(d, "PetLife", cx=w // 2, cy=int(h * 0.70), unit=unit,
                color=TEXT_PRIMARY)

    # 一条粉色加载线
    line_w = int(w * 0.30)
    line_h = max(2, int(w * 0.010))
    d.rounded_rectangle(
        [(w - line_w) // 2, int(h * 0.83), (w + line_w) // 2, int(h * 0.83) + line_h],
        radius=line_h // 2,
        fill=ACCENT,
    )
    return img.resize((width, height), Image.LANCZOS)


# 用 7 段式几何块拼字母（只覆盖 PetLife 需要的字符）。
_GLYPHS: dict[str, list[str]] = {
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "e": ["00000", "00000", "01110", "10001", "11111", "10000", "01110"],
    "t": ["01000", "11100", "01000", "01000", "01000", "01001", "00110"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "i": ["01000", "00000", "11000", "01000", "01000", "01000", "01110"],
    "f": ["00110", "01000", "11100", "01000", "01000", "01000", "01000"],
}


def splash_icon(size: int) -> Image.Image:
    """Android 12+ 启动页图标位图（透明底）。

    系统把该位图按 288dp 画布处理、只显示中央 2/3（192dp），
    因此标记必须落在中央 66.7% 以内，否则会被裁掉。
    """
    s = size * SUPERSAMPLE
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    inner = int(s * (192.0 / 288.0))
    mark = draw_mark(inner, burst=True, disc=True)
    offset = (s - inner) // 2
    canvas.alpha_composite(mark, (offset, offset))
    return canvas.resize((size, size), Image.LANCZOS)


def splash_branding(width: int) -> Image.Image:
    """Android 12+ 启动页品牌图（200×80dp）：PetLife + 粉色加载线。"""
    height = int(width * 80 / 200)
    s = SUPERSAMPLE
    w, h = width * s, height * s
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    cols = len("PetLife") * 6 - 1
    unit = min(int(w * 0.030), max(2, int(w * 0.80) // cols))
    _block_text(d, "PetLife", cx=w // 2, cy=int(h * 0.38), unit=unit,
                color=TEXT_PRIMARY)

    line_w = int(w * 0.34)
    line_h = max(2, int(w * 0.012))
    d.rounded_rectangle(
        [(w - line_w) // 2, int(h * 0.80), (w + line_w) // 2, int(h * 0.80) + line_h],
        radius=line_h // 2,
        fill=ACCENT,
    )
    return img.resize((width, height), Image.LANCZOS)


def _block_text(d: ImageDraw.ImageDraw, text: str, *, cx: int, cy: int, unit: int,
                color: tuple[int, int, int, int]) -> None:
    """用 5×7 点阵拼出文字（无字体依赖，跨机器结果完全一致）。"""
    cols = len(text) * 6 - 1
    total_w = cols * unit
    x0 = cx - total_w // 2
    y0 = cy - (7 * unit) // 2
    for index, char in enumerate(text):
        glyph = _GLYPHS.get(char)
        if glyph is None:
            continue
        for row, line in enumerate(glyph):
            for col, bit in enumerate(line):
                if bit != "1":
                    continue
                left = x0 + (index * 6 + col) * unit
                top = y0 + row * unit
                d.rectangle([left, top, left + unit - 1, top + unit - 1], fill=color)


def main() -> None:
    for density, factor in DENSITIES.items():
        folder = os.path.join(RES, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)

        legacy_size = int(round(48 * factor))
        rounded_square(legacy_size, 0.80, PRIMARY).save(
            os.path.join(folder, "ic_launcher.png")
        )
        circle_icon(legacy_size, 0.80).save(
            os.path.join(folder, "ic_launcher_round.png")
        )

        foreground_size = int(round(108 * factor))
        adaptive_foreground(foreground_size).save(
            os.path.join(folder, "ic_launcher_foreground.png")
        )

        drawable = os.path.join(RES, f"drawable-{density}")
        os.makedirs(drawable, exist_ok=True)
        # 传统启动背景（API < 31）：完整构图（图标 + PetLife + 加载线）。
        splash_image(int(round(200 * factor))).save(
            os.path.join(drawable, "splash_petlife.png")
        )
        # Android 12+ 系统启动页：图标层 + 品牌层分别提供。
        splash_icon(int(round(288 * factor))).save(
            os.path.join(drawable, "splash_icon.png")
        )
        splash_branding(int(round(200 * factor))).save(
            os.path.join(drawable, "splash_branding.png")
        )

    print("已生成图标与启动页资源：")
    print(f"  {RES}\\mipmap-*\\ic_launcher.png")
    print(f"  {RES}\\mipmap-*\\ic_launcher_round.png")
    print(f"  {RES}\\mipmap-*\\ic_launcher_foreground.png")
    print(f"  {RES}\\drawable-*\\splash_petlife.png")
    print(f"  {RES}\\drawable-*\\splash_icon.png")
    print(f"  {RES}\\drawable-*\\splash_branding.png")


if __name__ == "__main__":
    main()
