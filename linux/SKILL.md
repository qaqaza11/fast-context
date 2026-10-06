---
name: fast-context-linux
description: 在 Linux 上减少大仓库、日志、文档、截图、音频和视频进入上下文的 token 消耗：先本地搜索、过滤、提取、OCR、转写、抽帧，再把相关内容交给模型。
---

# Fast Context (Linux)

不要在本地预处理能先缩小范围时，直接加载庞大的原始输入。
采用渐进披露：元数据 -> 搜索/过滤 -> 紧凑提取 -> 相关片段 -> 必要时再看原始高清区域。保证正确性；提取会丢失的视觉或结构信息要去看原图。

> 这是 [qaqaza11/fast-context](https://github.com/qaqaza11/fast-context)（Windows 版 Codex Skill）的 Linux 兄弟版本，设计思想相同，实现按 Linux 重写。

## 代码与日志

- 永远不要递归读完整个仓库。用 `fd` 找候选路径、`rg` 搜字符串/符号/引用、`sg`（ast-grep）做 AST 结构查询。大文件先搜索再按行读相关区间。
- 尊重 `.gitignore`。除非相关，排除生成/依赖目录：`.git`、`node_modules`、`dist`、`build`、`target`、`.venv`、`venv`、`__pycache__`、`coverage`。用 `rg -n -m 20` 限流；不要一次吐出几千个文件名。
- 日志先用 `rg` 不分大小写搜 `error|exception|fatal|warning|failed|traceback|panic` 及附近上下文。去重重复噪声，保留时间戳、第一个有意义的错误、堆栈和之前的警告。大匹配结果存本地文件再看相关区间。

## 数据与文档

- JSON/CSV 先看 schema、行数、列、选字段、过滤、聚合、去重和代表性抽样；精确总数本地算，只返回需要的子集。
- 普通文字型 PDF/Office/HTML/CSV/JSON/EPUB，先 `markitdown input -o work/document.md`，再搜标题/关键词看附近章节。
- 转换丢了排版、表格、公式、图表或扫描文字时，只对相关页面渲染/OCR 或目视原图。不要把每个媒体文件都过 MarkItDown。

## 图片、音频与视频

- 文字型截图、页面、幻灯片、表单、代码、UI 先 OCR。以置信度和文本为主要上下文；OCR 不足、空间关系、图表、模糊公式、图标/颜色/形状，或用户要求看细节时再看原图。
- 批量图片用有界 OCR 并发、每图独立输出；先搜结果再加载文本。单张坏图不能拖死整批。
- 音频本地转写，带 segment 起止时间戳；先搜转写文本再看相关区间。只在需要时开词级时间戳。
- 视频：先看 ffprobe 元数据和已有字幕；字幕够用就用字幕。否则抽取/转写音频、场景/关键帧采样、文字帧 OCR、建时间戳索引。录屏/讲座/教程优先 转写+OCR+稀疏帧。
- 长视频首次预览先卡 30-60 帧（默认 48）。用联系表总览；默认不要一次发几十张全分辨率图或逐帧分析。锁定时间戳后再抽取短的高质量片段。独立分段限制并发。

## 本地辅助命令

Linux 上首次安装或依赖缺失时运行 `bash install.sh`（见项目 README）。安装器复用已有工具，把依赖装进用户级 Python 3.12 独立环境。
默认运行时：`~/.local/share/fast-context/.venv/bin/python`；自定义运行时可用 `FAST_CONTEXT_HOME` 覆盖。命令入口在 `~/.local/bin/fc-*`（安装器写入）。脚本在 Skill 目录的 `scripts/` 下；可用入口脚本，或直接用该 Python 跑脚本。所有命令都支持 `--help` 且不加载大模型。输出用任务的 `work/` 下显式目录（或用户指定位置）。

| 命令 | 用途 |
|---|---|
| `fc-inspect-media VIDEO` | 紧凑的时长、大小、分辨率、fps、编码、音频/字幕信息 |
| `fc-extract-keyframes VIDEO -o work/frames --max-frames 48` | 场景优先抽帧 + 均匀兜底；`frames.json` 存时间映射 |
| `fc-contact-sheet work/frames -o work/contact.jpg` | 带时间戳标签的小总览图 |
| `fc-transcribe AUDIO_OR_VIDEO -o work/transcript` | faster-whisper small、CPU/int8；带 segment 时间的 JSON + Markdown |
| `fc-batch-ocr IMAGE_DIR -o work/ocr` | PaddleOCR mobile 模型，中英；每图 TXT/JSON + index |
| `fc-verify [--models]` | 自检；`--models` 才跑真实 OCR 与 small 模型推理 |

场景检测会低分辨率扫描完整视频；超长视频首次预览可加 `--uniform-only`。OCR 默认最多 4 个进程、每进程 2 个 CPU 线程；机器忙时调低 `--workers`。OCR 默认关闭方向分类/去畸变以求速度；受影响的页面先旋转预处理或直接看原图。Whisper 支持 `--model base`、显式模型路径、`--language zh`、缓存 `--local-files-only`。首次使用可能下载所选模型；保留模型缓存。

## 输出纪律

只返回计数、摘要、路径、时间戳、匹配和短的相关摘录。完整的依赖输出、大 JSON、OCR 结果、转写文本和日志一律存本地文件；除非用户要求，不要整段粘贴。最省的顺序：元数据 -> 搜索/过滤 -> 文本提取 -> OCR/转写 -> 缩略图/关键帧 -> 原始区域。
