# fast-context-linux

一个 Linux 原生的本地预处理工具包 + Agent Skill，用于加速阅读、降低消耗。

**先搜索和提取，再把相关内容交给模型。** 普通文档转换为 Markdown；文字图片先 OCR；视频先元数据、字幕/语音转写、稀疏关键帧和联系表。完整结果写入本地文件，终端只返回摘要和路径。

> 灵感与设计来自 [qaqaza11/fast-context](https://github.com/qaqaza11/fast-context)（Windows 版 Codex Skill）。那是 Windows x64 专用（PowerShell 7 + winget），本项目是它的 Linux 兄弟版本：同样的"先搜索提取再喂模型"思想，按 Linux 原生重写（bash 安装器、apt 工具链、XDG 风格目录）。

## 安装（Linux x86_64）

需要 Python 3.12。系统工具（ripgrep / fd / ffmpeg）走 apt 安装；ast-grep 优先用已有的，其次 npm 全局包，最后 pip 的 `ast-grep-cli`。安装器使用用户级目录（不需要 sudo 装依赖，但 apt 本身需要 root 或 sudo），把 Python 依赖保存在独立的 Python 3.12 venv 中。

```
git clone https://github.com/qaqaza11/fast-context-linux.git
cd fast-context-linux
bash install.sh
```

安装结束后新开终端（安装器会把 `~/.local/bin` 加进 `~/.bashrc` 的 PATH）。

默认 Skill 位置为 `~/.agents/skills/fast-context-linux`。默认运行时为 `~/.local/share/fast-context`，命令入口在 `~/.local/bin/fc-*`。模型在首次 OCR/转写时下载，安装过程不会预先下载模型。默认使用 PaddleOCR 的中文/英文 mobile 模型和 faster-whisper small/CPU/int8；不安装 CUDA。

```
# 查看安装计划，不修改文件、PATH 或依赖
bash install.sh --check-only

# 不需要 OCR/语音时，跳过这两组依赖
bash install.sh --skip-ocr --skip-audio

# 自定义运行时目录
bash install.sh --home /path/to/runtime

# 更新已有同名 Skill，先备份原文件
bash install.sh --update
```

还支持 `--skip-dependencies`（复用已准备好的 Python 3.12 运行环境）、`--no-path`（不改 PATH）、`--no-verify`（跳过安装后自检）。安装器不会删除既有 Skill、环境或模型缓存；某组大型依赖失败时，会继续安装其余组，并在汇总和日志（`~/.local/share/fast-context/install.log`）中记录失败；完成后返回非零退出码。

## 使用

可以直接运行命令：

```
fd -e py -e ts . .
rg -n -i -m 20 'error|exception|failed' ./logs
sg run -l javascript -p 'console.log($ARG)' ./src
markitdown ./report.pdf -o ./work/report.md
fc-inspect-media ./video.mp4
fc-extract-keyframes ./video.mp4 -o ./work/frames --max-frames 48
fc-contact-sheet ./work/frames -o ./work/contact.jpg
fc-transcribe ./video.mp4 -o ./work/transcript --language zh
fc-batch-ocr ./screenshots -o ./work/ocr --workers 2
```

每个辅助命令都支持 `--help`。视频场景检测会低分辨率扫描完整视频；超长视频首次预览可加 `--uniform-only`。OCR 默认最多 4 个进程，每个进程 2 个 CPU 线程；低置信度文本保留在 JSON 中。对复杂布局、图表、公式或识别不充分的区域，仍需要查看原图。

`frames.json` 保存抽帧时间映射；OCR 输出每图 TXT/JSON 和 `index.json`；语音转写输出带 segment 起止时间的 JSON/Markdown。使用新的输出目录，避免混入之前任务的结果。

## 验证

```
# 快速测试：真实搜索、结构查询、文档转换、视频生成/抽帧/联系表与 import
fc-verify

# 额外执行真实 OCR 和 small 模型推理，首次运行可能下载模型
fc-verify --models
```

验证器自动清理它新建的临时测试素材，保留模型缓存，并将检查结果写入运行目录的 `verification.json`。`--model-cache PATH` 可指定已有 Whisper 缓存，仅使用本地模型。安装器默认执行快速测试，完整模型测试由用户显式运行。

## 依赖与维护

| 工具 | 安装来源 / 当前配置 |
| --- | --- |
| ripgrep / fd | apt 官方包（Debian 系 fd 二进制叫 `fdfind`，安装器建 `fd` 软链接），优先复用现有命令 |
| ast-grep | 已有安装；否则 npm 全局 `@ast-grep/cli`，无 npm 时用 pip 的 `ast-grep-cli` |
| FFmpeg / ffprobe | apt 官方包 |
| MarkItDown | `markitdown[all]==0.1.8` |
| PaddleOCR / PaddlePaddle | `3.7.0` / `3.3.0` CPU（PaddlePaddle 从官方 CPU index 安装） |
| faster-whisper / PyAV | `1.2.1` / `18.1.0` |
| Pillow | `12.3.0` |

Python 依赖版本记录在 `requirements-*.txt`。PyAV 19 移除了 faster-whisper 1.2.1 仍使用的 `metadata_errors` 参数，因此当前锁定 18.1.0；更新时请运行完整验证。

Skill 和脚本以 MIT 许可证发布。外部工具、模型、字体使用各自许可证；仓库不包含这些二进制或模型。此工作流旨在减少无关内容进入上下文；实际速度和 token 节省随任务而变化，目前不提供量化节省承诺。
