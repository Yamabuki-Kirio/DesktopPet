# 08 · Ace Attorney 素材扫描结果与索引示例
> 本文件由 `tools/gen_scan_report.py` 依据真实素材自动生成，不是手写。

素材目录：`C:\Users\Administrator\WorkBuddy\DesktopPet\Ace Attorney`

扫描工具：`tools/webp_probe.py`（纯 Python 标准库解析 RIFF/WEBP 容器头，与 Dart 侧 `WebpContainerParser` 使用同一套规则）

## 1. 汇总

| 指标 | 值 |
|---|---|
| 识别到的文件数 | 13 |
| 作品包 | Ace Attorney（1 个） |
| 角色 | Maya（1 个） |
| 情绪数 | 13 |
| 动态图片 | 13 |
| 静态图片 | 0 |
| 损坏文件 | 0 |
| 画布尺寸 | 256 x 192（全部一致） |
| 带透明通道 | 13 / 13 |
| 总帧数 | 116 |
| 总体积 | 58162 字节（56.8 KB） |
| 帧数区间 | 5 ~ 15 |

## 2. 逐文件明细

| 文件名 | 角色 | 情绪 | 变体 | 真实格式 | 尺寸 | 帧数 | 动态 | 透明 | 循环 | 一轮时长 | 大小 | 编码 | 帧矩形<画布 | SHA-256(前16) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Maya_Angry_1.webp | Maya | Angry | 1 | image/webp | 256x192 | 9 | 是 | 是 | 0 | 5320 ms | 3336 B | VP8L (lossless) | 是 | 4559ae6b9113114a |
| Maya_Bench_Exasperated_1.webp | Maya | Bench_Exasperated | 1 | image/webp | 256x192 | 5 | 是 | 是 | 0 | 3520 ms | 2182 B | VP8L (lossless) | 是 | 8243dec4466ead7e |
| Maya_Bench_Thinking_1.webp | Maya | Bench_Thinking | 1 | image/webp | 256x192 | 15 | 是 | 是 | 0 | 5640 ms | 3314 B | VP8L (lossless) | 是 | d63e02ec2cc921e1 |
| Maya_Cheerful_1.webp | Maya | Cheerful | 1 | image/webp | 256x192 | 9 | 是 | 是 | 0 | 5320 ms | 3712 B | VP8L (lossless) | 是 | 23f569e4b610b3d7 |
| Maya_Confident_1.webp | Maya | Confident | 1 | image/webp | 256x192 | 9 | 是 | 是 | 0 | 5660 ms | 3512 B | VP8L (lossless) | 是 | e5d1347d07ad4a3a |
| Maya_Crying_1.webp | Maya | Crying | 1 | image/webp | 256x192 | 5 | 是 | 是 | 0 | 3310 ms | 2976 B | VP8L (lossless) | 是 | b371fbab41da1b4a |
| Maya_Disheartened_1.webp | Maya | Disheartened | 1 | image/webp | 256x192 | 5 | 是 | 是 | 0 | 3310 ms | 2460 B | VP8L (lossless) | 是 | 01330a714855d83f |
| Maya_Excited_1.webp | Maya | Excited | 1 | image/webp | 256x192 | 9 | 是 | 是 | 0 | 5320 ms | 3670 B | VP8L (lossless) | 是 | 369b2256d1e9d55d |
| Maya_Nod.webp | Maya | Nod | default | image/webp | 256x192 | 7 | 是 | 是 | 0 | 1720 ms | 10064 B | VP8L (lossless) | 是 | bc216afc67b7539e |
| Maya_Shocked.webp | Maya | Shocked | default | image/webp | 256x192 | 12 | 是 | 是 | 0 | 2110 ms | 11908 B | VP8L (lossless) | 是 | 05e8637717bf9fc9 |
| Maya_Surprised_1.webp | Maya | Surprised | 1 | image/webp | 256x192 | 13 | 是 | 是 | 0 | 5400 ms | 4242 B | VP8L (lossless) | 是 | 9080a3fc95d7e758 |
| Maya_Thinking_1.webp | Maya | Thinking | 1 | image/webp | 256x192 | 9 | 是 | 是 | 0 | 4660 ms | 3482 B | VP8L (lossless) | 是 | 3bcbdbdec8d4bf68 |
| Maya_Worried_1.webp | Maya | Worried | 1 | image/webp | 256x192 | 9 | 是 | 是 | 0 | 6640 ms | 3304 B | VP8L (lossless) | 是 | 0cd45fb63b4443ed |

## 3. 帧矩形实测（关键技术点）

这些文件的 **ANMF 帧矩形小于画布**，即每一帧是带偏移的子矩形，而不是整幅画面。例如：

| 文件 | 画布 | 首帧矩形 | 说明 |
|---|---|---|---|
| Maya_Angry_1.webp | 256x192 | 95x160 | 帧仅为画布的一部分 |
| Maya_Bench_Exasperated_1.webp | 256x192 | 72x164 | 帧仅为画布的一部分 |
| Maya_Bench_Thinking_1.webp | 256x192 | 66x168 | 帧仅为画布的一部分 |
| Maya_Cheerful_1.webp | 256x192 | 92x156 | 帧仅为画布的一部分 |

**影响**：解码器必须正确处理「帧矩形 + 混合/处置标志」，否则会出现错位或缺块。
本项目的处理方式：把动画交给 Skia 的 WebP 解码器（libwebp 的动画解码器会返回**合成后的整幅画布帧**），并在 `emotion_assets` 表与日志中记录`frame_count` / `animation_duration_ms` / `has_alpha`，同时在导入日志中明确打印 `subRect=` 标记，便于日后排查显示问题。
验收第 6/7/8 项会对此做实际确认。

## 4. 自动生成的素材索引示例（emotion_assets 表内容）

以其中 3 条为例（JSON 形式，实际存 SQLite）：

```json
[
  {
    "id": "<uuidv5(asset|Maya|angry|1)>",
    "character_id": "<uuidv5(character|Ace Attorney|maya)>",
    "emotion_name": "Angry",
    "variant_name": "1",
    "file_path": "<AppData>/PetLife/assets/local.default/Ace Attorney/Maya/Maya_Angry_1.webp",
    "original_file_path": "C:\\Users\\Administrator\\WorkBuddy\\DesktopPet\\Ace Attorney\\Maya_Angry_1.webp",
    "file_hash": "4559ae6b9113114a8fb7c81ff9c21129dc66b8b31ff33e41affd630acc0ded9f",
    "mime_type": "image/webp",
    "file_size": 3336,
    "width": 256,
    "height": 192,
    "frame_count": 9,
    "is_animated": 1,
    "has_alpha": 1,
    "enabled": 1,
    "validation_status": "valid",
    "validation_error": null,
    "animation_duration_ms": 5320,
    "created_at": "<毫秒时间戳>"
  },
  {
    "id": "<uuidv5(asset|Maya|bench_exasperated|1)>",
    "character_id": "<uuidv5(character|Ace Attorney|maya)>",
    "emotion_name": "Bench_Exasperated",
    "variant_name": "1",
    "file_path": "<AppData>/PetLife/assets/local.default/Ace Attorney/Maya/Maya_Bench_Exasperated_1.webp",
    "original_file_path": "C:\\Users\\Administrator\\WorkBuddy\\DesktopPet\\Ace Attorney\\Maya_Bench_Exasperated_1.webp",
    "file_hash": "8243dec4466ead7e0971f27467e8ce36f17adbd1e69100b9fe906be3bfe5cde5",
    "mime_type": "image/webp",
    "file_size": 2182,
    "width": 256,
    "height": 192,
    "frame_count": 5,
    "is_animated": 1,
    "has_alpha": 1,
    "enabled": 1,
    "validation_status": "valid",
    "validation_error": null,
    "animation_duration_ms": 3520,
    "created_at": "<毫秒时间戳>"
  },
  {
    "id": "<uuidv5(asset|Maya|bench_thinking|1)>",
    "character_id": "<uuidv5(character|Ace Attorney|maya)>",
    "emotion_name": "Bench_Thinking",
    "variant_name": "1",
    "file_path": "<AppData>/PetLife/assets/local.default/Ace Attorney/Maya/Maya_Bench_Thinking_1.webp",
    "original_file_path": "C:\\Users\\Administrator\\WorkBuddy\\DesktopPet\\Ace Attorney\\Maya_Bench_Thinking_1.webp",
    "file_hash": "d63e02ec2cc921e14b632bd3c9e68f9b8d0dee3ed6bfb1362796e5f47eb7cc16",
    "mime_type": "image/webp",
    "file_size": 3314,
    "width": 256,
    "height": 192,
    "frame_count": 15,
    "is_animated": 1,
    "has_alpha": 1,
    "enabled": 1,
    "validation_status": "valid",
    "validation_error": null,
    "animation_duration_ms": 5640,
    "created_at": "<毫秒时间戳>"
  }
]
```

## 5. 状态映射示例（state_mappings 表内容）

导入后应用会按「建议情绪表」自动生成一组映射。以 Maya 为例，实际生成结果如下：

| 系统状态 | 优先级 | 建议情绪 | 素材里是否存在 | 命中情况 |
|---|---|---|---|---|
| default | - | Cheerful | 是 | 生成 Cheerful 的映射 |
| focused | - | Thinking 或 Bench_Thinking | 是 | 生成 Thinking、Bench_Thinking 的映射 |
| gaming | - | Excited 或 Confident | 是 | 生成 Excited、Confident 的映射 |
| social | - | Cheerful 或 Nod | 是 | 生成 Cheerful、Nod 的映射 |
| entertained | - | Excited 或 Surprised | 是 | 生成 Excited、Surprised 的映射 |
| tired | - | Disheartened 或 Bench_Exasperated | 是 | 生成 Disheartened、Bench_Exasperated 的映射 |
| away | - | Thinking | 是 | 生成 Thinking 的映射 |
| happy | - | Cheerful、Excited 或 Nod | 是 | 生成 Cheerful、Excited、Nod 的映射 |
| concerned | - | Worried | 是 | 生成 Worried 的映射 |
| error | - | Shocked 或 Angry | 是 | 生成 Shocked、Angry 的映射 |
| manual | - | 用户指定图片 | 否 | 无映射，走回退链 |

映射记录的字段结构：

```json
[
  {
    "id": "<uuidv5(mapping|characterId|default|0)>",
    "character_id": "<Maya 的 character_id>",
    "system_state": "default",
    "asset_id": null,
    "emotion_name": "Cheerful",
    "weight": 1,
    "priority": 0,
    "created_at": "<毫秒时间戳>",
    "updated_at": "<毫秒时间戳>"
  },
  {
    "id": "<uuidv5(mapping|characterId|focused|0)>",
    "character_id": "<Maya 的 character_id>",
    "system_state": "focused",
    "asset_id": null,
    "emotion_name": "Thinking",
    "weight": 1,
    "priority": 50,
    "created_at": "<毫秒时间戳>",
    "updated_at": "<毫秒时间戳>"
  }
]
```

> `emotion_name` 绑定的是**情绪**而不是具体文件，因此用户以后往同一情绪里补充新变体，映射会自动覆盖到新图片。
> 若需要精确锁定某一张图，可在状态映射页选择「按具体图片添加」，此时写的是 `asset_id`（回退链第 1 级）。
