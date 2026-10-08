"""生成 PetLife 的托盘图标（32x32 PNG + ICO），纯标准库实现。

之所以自己生成而不是引入一张二进制图片：仓库里不该出现来路不明的二进制资源，
而且这个图标很小，用代码画出来完全可读、可复现、可修改。
"""
import os
import struct
import zlib

OUT_DIR = r"C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\assets"
SIZE = 32


def png_chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def make_pixels():
    """画一个圆角蓝色方块 + 两只眼睛的桌宠图标，返回 RGBA 像素行。"""
    body = (0x4A, 0x7E, 0xBB)
    outline = (0x2F, 0x4A, 0x63)
    eye = (0xFF, 0xFF, 0xFF)
    pupil = (0x2F, 0x4A, 0x63)

    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            # 圆角矩形区域（留 3px 边距，半径 7）
            left, top, right, bottom, r = 3, 4, SIZE - 4, SIZE - 4, 7
            inside = False
            if left + r <= x <= right - r and top <= y <= bottom:
                inside = True
            elif top + r <= y <= bottom - r and left <= x <= right:
                inside = True
            else:
                for cx, cy in (
                    (left + r, top + r),
                    (right - r, top + r),
                    (left + r, bottom - r),
                    (right - r, bottom - r),
                ):
                    if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                        inside = True
                        break

            if not inside:
                row.append((0, 0, 0, 0))
                continue

            # 描边
            edge = (
                x <= left + 1
                or x >= right - 1
                or y <= top + 1
                or y >= bottom - 1
            )
            color = outline if edge else body

            # 眼睛：两个 4x4 白点 + 2x2 瞳孔
            for ex in (11, 18):
                if ex <= x < ex + 4 and 12 <= y < 16:
                    color = eye
            for ex in (12, 19):
                if ex <= x < ex + 2 and 13 <= y < 15:
                    color = pupil
            # 嘴巴
            if 14 <= x < 19 and y == 22:
                color = outline

            row.append((color[0], color[1], color[2], 255))
        rows.append(row)
    return rows


def encode_png(rows):
    raw = b""
    for row in rows:
        raw += b"\x00" + b"".join(bytes(px) for px in row)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += png_chunk(b"IHDR", ihdr)
    png += png_chunk(b"IDAT", zlib.compress(raw, 9))
    png += png_chunk(b"IEND", b"")
    return png


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    png = encode_png(make_pixels())

    png_path = os.path.join(OUT_DIR, "tray_icon.png")
    with open(png_path, "wb") as f:
        f.write(png)

    # ICO 容器：1 个条目，内嵌 PNG（Vista+ 支持）
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack(
        "<BBBBHHII",
        SIZE,
        SIZE,
        0,
        0,
        1,
        32,
        len(png),
        6 + 16,
    )
    ico_path = os.path.join(OUT_DIR, "tray_icon.ico")
    with open(ico_path, "wb") as f:
        f.write(header + entry + png)

    print("png:", png_path, os.path.getsize(png_path), "bytes")
    print("ico:", ico_path, os.path.getsize(ico_path), "bytes")


main()
