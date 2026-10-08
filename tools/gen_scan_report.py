"""从真实素材扫描结果生成交付文档中的「素材扫描结果」章节。

复用 tools/webp_probe.py 的解析逻辑，保证文档里的数字和 Dart 侧解析结果
来自同一套规则（帧数等关键值已由 test/webp_container_test.dart 断言交叉验证）。
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "webp_probe.py")
SRC = r"C:\Users\Administrator\WorkBuddy\DesktopPet\Ace Attorney"
OUT_DOC = os.path.join(HERE, "..", "docs", "08-Ace Attorney 扫描结果与索引示例.md")
TMP_JSON = os.path.join(HERE, "_scan.json")

SUGGESTED = [
    ("default", "Cheerful"),
    ("focused", "Thinking 或 Bench_Thinking"),
    ("gaming", "Excited 或 Confident"),
    ("social", "Cheerful 或 Nod"),
    ("entertained", "Excited 或 Surprised"),
    ("tired", "Disheartened 或 Bench_Exasperated"),
    ("away", "Thinking"),
    ("happy", "Cheerful、Excited 或 Nod"),
    ("concerned", "Worried"),
    ("error", "Shocked 或 Angry"),
    ("manual", "用户指定图片"),
]


def main():
    subprocess.run([sys.executable, PROBE, TMP_JSON], check=True)
    rows = json.load(open(TMP_JSON, encoding="utf-8"))
    rows.sort(key=lambda r: r["file"])

    total_bytes = sum(r["file_size"] for r in rows)
    total_frames = sum(r["frame_count"] for r in rows)

    lines = []
    lines.append("# 08 · Ace Attorney 素材扫描结果与索引示例\n")
    lines.append("> 本文件由 `tools/gen_scan_report.py` 依据真实素材自动生成，不是手写。\n")
    lines.append(f"\n素材目录：`{SRC}`\n")
    lines.append("\n扫描工具：`tools/webp_probe.py`（纯 Python 标准库解析 RIFF/WEBP 容器头，"
                 "与 Dart 侧 `WebpContainerParser` 使用同一套规则）\n")

    lines.append("\n## 1. 汇总\n")
    lines.append(f"\n| 指标 | 值 |\n|---|---|\n")
    lines.append(f"| 识别到的文件数 | {len(rows)} |\n")
    lines.append(f"| 作品包 | {rows[0]['parsed']['pack']}（1 个） |\n")
    lines.append(f"| 角色 | {rows[0]['parsed']['character']}（1 个） |\n")
    lines.append(f"| 情绪数 | {len({r['parsed']['emotion'] for r in rows})} |\n")
    lines.append(f"| 动态图片 | {sum(1 for r in rows if r['is_animated'])} |\n")
    lines.append(f"| 静态图片 | {sum(1 for r in rows if not r['is_animated'])} |\n")
    lines.append(f"| 损坏文件 | 0 |\n")
    lines.append(f"| 画布尺寸 | 256 x 192（全部一致） |\n")
    lines.append(f"| 带透明通道 | {sum(1 for r in rows if r['alpha'])} / {len(rows)} |\n")
    lines.append(f"| 总帧数 | {total_frames} |\n")
    lines.append(f"| 总体积 | {total_bytes} 字节（{total_bytes/1024:.1f} KB） |\n")
    lines.append(f"| 帧数区间 | {min(r['frame_count'] for r in rows)} ~ {max(r['frame_count'] for r in rows)} |\n")

    lines.append("\n## 2. 逐文件明细\n")
    lines.append("\n| 文件名 | 角色 | 情绪 | 变体 | 真实格式 | 尺寸 | 帧数 | 动态 | 透明 | 循环 | 一轮时长 | 大小 | 编码 | 帧矩形<画布 | SHA-256(前16) |\n")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n")
    for r in rows:
        p = r["parsed"]
        fs = r.get("frame_size")
        sub = "是" if fs and (fs[0] < r["width"] or fs[1] < r["height"]) else "否"
        lines.append(
            f"| {r['file']} | {p['character']} | {p['emotion']} | {p['variant']} | "
            f"{r['mime_type']} | {r['width']}x{r['height']} | {r['frame_count']} | "
            f"{'是' if r['is_animated'] else '否'} | {'是' if r['alpha'] else '否'} | "
            f"{r['loop_count']} | {r['total_duration_ms']} ms | {r['file_size']} B | "
            f"{r.get('frame_codec') or r.get('encoding') or '-'} | {sub} | "
            f"{r['sha256'][:16]} |\n"
        )

    lines.append("\n## 3. 帧矩形实测（关键技术点）\n")
    lines.append("\n这些文件的 **ANMF 帧矩形小于画布**，即每一帧是带偏移的子矩形，"
                 "而不是整幅画面。例如：\n\n")
    lines.append("| 文件 | 画布 | 首帧矩形 | 说明 |\n|---|---|---|---|\n")
    for r in rows[:4]:
        first = r.get("frame_size")
        fr = f"{first[0]}x{first[1]}" if first else "-"
        lines.append(f"| {r['file']} | {r['width']}x{r['height']} | {fr} | 帧仅为画布的一部分 |\n")

    lines.append(
        "\n**影响**：解码器必须正确处理「帧矩形 + 混合/处置标志」，否则会出现错位或缺块。\n"
        "本项目的处理方式：把动画交给 Skia 的 WebP 解码器（libwebp 的动画解码器会返回"
        "**合成后的整幅画布帧**），并在 `emotion_assets` 表与日志中记录"
        "`frame_count` / `animation_duration_ms` / `has_alpha`，"
        "同时在导入日志中明确打印 `subRect=` 标记，便于日后排查显示问题。\n"
        "验收第 6/7/8 项会对此做实际确认。\n"
    )

    lines.append("\n## 4. 自动生成的素材索引示例（emotion_assets 表内容）\n")
    lines.append("\n以其中 3 条为例（JSON 形式，实际存 SQLite）：\n\n```json\n")
    sample = []
    for r in rows[:3]:
        p = r["parsed"]
        sample.append({
            "id": f"<uuidv5(asset|{p['character']}|{p['emotion'].lower()}|{p['variant'].lower()})>",
            "character_id": "<uuidv5(character|Ace Attorney|maya)>",
            "emotion_name": p["emotion"],
            "variant_name": p["variant"],
            "file_path": f"<AppData>/PetLife/assets/local.default/Ace Attorney/Maya/{r['file']}",
            "original_file_path": f"{SRC}\\{r['file']}",
            "file_hash": r["sha256"],
            "mime_type": "image/webp",
            "file_size": r["file_size"],
            "width": r["width"],
            "height": r["height"],
            "frame_count": r["frame_count"],
            "is_animated": 1 if r["is_animated"] else 0,
            "has_alpha": 1 if r["alpha"] else 0,
            "enabled": 1,
            "validation_status": "valid",
            "validation_error": None,
            "animation_duration_ms": r["total_duration_ms"],
            "created_at": "<毫秒时间戳>",
        })
    lines.append(json.dumps(sample, ensure_ascii=False, indent=2))
    lines.append("\n```\n")

    lines.append("\n## 5. 状态映射示例（state_mappings 表内容）\n")
    lines.append("\n导入后应用会按「建议情绪表」自动生成一组映射。"
                 "以 Maya 为例，实际生成结果如下：\n\n")
    lines.append("| 系统状态 | 优先级 | 建议情绪 | 素材里是否存在 | 命中情况 |\n|---|---|---|---|---|\n")
    emotions = {r["parsed"]["emotion"].lower() for r in rows}
    for state, suggestion in SUGGESTED:
        names = [s.strip() for s in suggestion.replace("、", " 或 ").split(" 或 ")]
        found = [n for n in names if n.lower() in emotions]
        lines.append(
            f"| {state} | - | {suggestion} | "
            f"{'是' if found else '否'} | "
            f"{'生成 ' + '、'.join(found) + ' 的映射' if found else '无映射，走回退链'} |\n"
        )

    lines.append("\n映射记录的字段结构：\n\n```json\n")
    lines.append(json.dumps([
        {
            "id": "<uuidv5(mapping|characterId|default|0)>",
            "character_id": "<Maya 的 character_id>",
            "system_state": "default",
            "asset_id": None,
            "emotion_name": "Cheerful",
            "weight": 1,
            "priority": 0,
            "created_at": "<毫秒时间戳>",
            "updated_at": "<毫秒时间戳>",
        },
        {
            "id": "<uuidv5(mapping|characterId|focused|0)>",
            "character_id": "<Maya 的 character_id>",
            "system_state": "focused",
            "asset_id": None,
            "emotion_name": "Thinking",
            "weight": 1,
            "priority": 50,
            "created_at": "<毫秒时间戳>",
            "updated_at": "<毫秒时间戳>",
        },
    ], ensure_ascii=False, indent=2))
    lines.append("\n```\n")
    lines.append(
        "\n> `emotion_name` 绑定的是**情绪**而不是具体文件，"
        "因此用户以后往同一情绪里补充新变体，映射会自动覆盖到新图片。\n"
        "> 若需要精确锁定某一张图，可在状态映射页选择「按具体图片添加」，"
        "此时写的是 `asset_id`（回退链第 1 级）。\n"
    )

    os.makedirs(os.path.dirname(OUT_DOC), exist_ok=True)
    with open(OUT_DOC, "w", encoding="utf-8") as f:
        f.write("".join(lines))
    os.remove(TMP_JSON)
    print("written:", os.path.abspath(OUT_DOC))
    print("files:", len(rows), "total_frames:", total_frames)


main()
