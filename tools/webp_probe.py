"""Pure-python WebP container probe: no third-party deps.

Parses RIFF/WEBP container to determine real format, canvas size, alpha,
animation flag and frame count. Used to validate the Ace Attorney asset set
independently of Flutter.
"""
import json
import os
import struct
import sys
import hashlib

SRC = r"C:\Users\Administrator\WorkBuddy\DesktopPet\Ace Attorney"


def parse_webp(path):
    with open(path, "rb") as f:
        data = f.read()
    info = {"file_size": len(data)}
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        info["error"] = "not a RIFF/WEBP container"
        return info
    info["riff_size_field"] = struct.unpack("<I", data[4:8])[0]
    pos = 12
    chunks = []
    frames = 0
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        payload = data[pos + 8:pos + 8 + size]
        chunks.append((cid.decode("ascii", "replace"), size))
        if cid == b"VP8X":
            flags = payload[0]
            info["alpha"] = bool(flags & 0b0001_0000)
            info["animated"] = bool(flags & 0b0000_0010)
            w = 1 + int.from_bytes(payload[4:7], "little")
            h = 1 + int.from_bytes(payload[7:10], "little")
            info["width"], info["height"] = w, h
        elif cid == b"ANIM":
            info["bgcolor"] = payload[:4].hex()
            info["loop_count"] = int.from_bytes(payload[4:6], "little")
        elif cid == b"ANMF":
            frames += 1
            fx = 2 * int.from_bytes(payload[0:3], "little")
            fy = 2 * int.from_bytes(payload[3:6], "little")
            fw = 1 + int.from_bytes(payload[6:9], "little")
            fh = 1 + int.from_bytes(payload[9:12], "little")
            dur = int.from_bytes(payload[12:15], "little")
            info.setdefault("frame_size", (fw, fh))
            info["total_duration_ms"] = info.get("total_duration_ms", 0) + dur
            # 动画帧的 VP8/VP8L 块嵌套在 ANMF 内部（16 字节帧头之后）
            if len(payload) >= 20:
                codec = payload[16:20]
                if codec == b"VP8 ":
                    info["frame_codec"] = "VP8 (lossy)"
                elif codec == b"VP8L":
                    info["frame_codec"] = "VP8L (lossless)"
        elif cid == b"VP8 ":
            info["encoding"] = "VP8 (lossy)"
            # keyframe header: 3 bytes frame tag, then 3-byte start code + 2-byte dims
            w = struct.unpack("<H", payload[6:8])[0] & 0x3FFF
            h = struct.unpack("<H", payload[8:10])[0] & 0x3FFF
            info["width"], info["height"] = w, h
        elif cid == b"VP8L":
            info["encoding"] = "VP8L (lossless)"
            b = payload[1:5]
            bits = int.from_bytes(b, "little")
            info["width"] = (bits & 0x3FFF) + 1
            info["height"] = ((bits >> 14) & 0x3FFF) + 1
            info["alpha"] = bool((bits >> 28) & 1)
        elif cid == b"ALPH":
            info["alpha"] = True
        elif cid == b"EXIF" or cid == b"XMP ":
            pass
        pos += 8 + size + (size & 1)
    info["chunks"] = chunks
    info["frame_count"] = frames if frames else 1
    info["is_animated"] = frames > 1
    info["mime_type"] = "image/webp"
    info["sha256"] = hashlib.sha256(data).hexdigest()
    return info


def parse_name(filename):
    stem = os.path.splitext(filename)[0]
    ext = os.path.splitext(filename)[1].lstrip(".").lower()
    parts = stem.split("_")
    pack = os.path.basename(SRC)
    if not parts:
        return None
    character = parts[0]
    rest = parts[1:]
    variant = "default"
    if rest and rest[-1].isdigit():
        variant = rest[-1]
        rest = rest[:-1]
    emotion = "_".join(rest) if rest else "default"
    return dict(pack=pack, character=character, emotion=emotion, variant=variant, ext=ext)


def main():
    rows = []
    for name in sorted(os.listdir(SRC)):
        path = os.path.join(SRC, name)
        if not os.path.isfile(path):
            continue
        if os.path.splitext(name)[1].lower() not in (".webp", ".png", ".jpg", ".jpeg", ".gif"):
            continue
        r = {"file": name}
        r.update(parse_webp(path))
        r["parsed"] = parse_name(name)
        rows.append(r)
    out = json.dumps(rows, ensure_ascii=False, indent=2)
    with open(sys.argv[1] if len(sys.argv) > 1 else "scan.json", "w", encoding="utf-8") as f:
        f.write(out)
    print("scanned", len(rows), "files")


main()
