# fast-context

A small Codex Skill and local preprocessing toolkit for reading large repositories, documents, screenshots, audio, and video progressively.

**先搜索和提取，再把相关内容交给模型。** 普通文档转换为 Markdown；文字图片先 OCR；视频先元数据、字幕/语音转写、稀疏关键帧和联系表。完整结果写入本地文件，终端只返回摘要和路径。

## 安装（Windows x64）

需要 PowerShell 7 和 winget。Git 只用于克隆仓库；也可以下载 ZIP 后解压。安装器使用用户级目录，复用可运行的基础命令，并将 Python 依赖保存在独立的 Python 3.12 环境中。

```powershell
git clone https://github.com/qaqaza11/fast-context.git
Set-Location fast-context
pwsh -File .\install.ps1
```

安装结束后新开终端。Codex 若仍使用旧 PATH，重启一次。

默认 Skill 位置为 `$env:USERPROFILE\.agents\skills\fast-context`。如果已经存在旧的 `.codex\skills\fast-context`，安装器复用该位置。若两个位置同时存在，需要显式指定 `-SkillDirectory`，避免重复加载。[Codex 官方 Skill 文档](https://learn.chatgpt.com/docs/build-skills)

运行环境和命令入口位于 `$env:USERPROFILE\.codex\tools\fast-context`。模型在首次 OCR/转写时下载，安装过程不会预先下载模型。默认使用 PaddleOCR 的中文/英文 mobile 模型和 faster-whisper small/CPU/int8；不安装 CUDA。

```powershell
# 查看安装计划，不修改文件、PATH 或依赖
pwsh -File .\install.ps1 -CheckOnly

# 不需要 OCR/语音时，跳过这两组依赖
pwsh -File .\install.ps1 -SkipOcr -SkipAudio

# 更新已有同名 Skill，先备份原文件
pwsh -File .\install.ps1 -Update
```

还支持 `-SkillDirectory PATH`、`-RuntimeRoot PATH`、`-NoPath`。`-SkipDependencies` 仅用于复用已经准备好的 Python 3.12 运行环境。安装器不会删除既有 Skill、环境或模型缓存，也不修改系统 PATH 或 Codex 配置。某组大型依赖失败时，会继续安装其余组，并在汇总和日志中记录失败；完成后返回非零退出码。

## 使用

在 Codex 中可以直接说：

- “用 fast-context 分析这个项目为什么编译失败。”
- “用 fast-context 快速读这个 PDF，只找和预算有关的内容。”
- “用 fast-context 分析这个目录里的截图，先 OCR 再筛选。”
- “用 fast-context 快速分析这个视频，先不要逐帧读取。”

也可以直接运行命令：

```powershell
fd -e py -e ts . .
rg -n -i -m 20 'error|exception|failed' .\logs
sg run -l javascript -p 'console.log($ARG)' .\src
markitdown .\report.pdf -o .\work\report.md
fc-inspect-media .\video.mp4
fc-extract-keyframes .\video.mp4 -o .\work\frames --max-frames 48
fc-contact-sheet .\work\frames -o .\work\contact.jpg
fc-transcribe .\video.mp4 -o .\work\transcript --language zh
fc-batch-ocr .\screenshots -o .\work\ocr --workers 2
```

每个辅助命令都支持 `--help`。视频场景检测会低分辨率扫描完整视频；超长视频首次预览可加 `--uniform-only`。OCR 默认最多 4 个进程，每个进程 2 个 CPU 线程；低置信度文本保留在 JSON 中。对复杂布局、图表、公式或识别不充分的区域，仍需要查看原图。

`frames.json` 保存抽帧时间映射；OCR 输出每图 TXT/JSON 和 `index.json`；语音转写输出带 segment 起止时间的 JSON/Markdown。使用新的输出目录，避免混入之前任务的结果。

## 验证

```powershell
# 快速测试：真实搜索、结构查询、文档转换、视频生成/抽帧/联系表与 import
fc-verify

# 额外执行真实 OCR 和 small 模型推理，首次运行可能下载模型
fc-verify --models
```

验证器自动清理它新建的临时测试素材，保留模型缓存，并将检查结果写入运行目录的 `verification.json`。`--model-cache PATH` 可指定已有 Whisper 缓存，仅使用本地模型。安装器默认执行快速测试，完整模型测试由用户显式运行。

此版本已在 Windows 11 x64 / PowerShell 7 / Python 3.12 上通过 25 项检查，包括中文/英文 OCR、损坏图片隔离和真实 small 模型语音推理。另已验证中文及空格目录安装、命令入口、其他 Skill 保护和更新前的显式 `-Update` 检查。安装器尚未在其他操作系统上验证；Python 辅助脚本可在手动准备相应依赖后使用。

## 依赖与维护

| 工具 | 安装来源 / 当前配置 |
|---|---|
| ripgrep / fd | winget 官方项目对应包，优先复用现有命令 |
| ast-grep | 已有安装；否则官方 npm 包，无 npm 时使用官方 Python CLI 包 |
| FFmpeg / ffprobe | winget 的 Gyan Essentials Windows 构建 |
| MarkItDown | `markitdown[all]==0.1.8` |
| PaddleOCR / PaddlePaddle | `3.7.0` / `3.3.0` CPU |
| faster-whisper / PyAV | `1.2.1` / `18.1.0` |
| Pillow | `12.3.0` |

Python 依赖版本记录在 `requirements-*.txt`。PyAV 19 移除了 faster-whisper 1.2.1 仍使用的 `metadata_errors` 参数，因此当前锁定 18.1.0；更新时请运行完整验证。[PyAV 官方变更记录](https://github.com/PyAV-Org/PyAV/blob/master/CHANGELOG.rst)

官方安装说明：[uv](https://docs.astral.sh/uv/getting-started/installation/)、[ast-grep](https://ast-grep.github.io/guide/quick-start)、[fd](https://github.com/sharkdp/fd)、[FFmpeg](https://ffmpeg.org/download.html)、[MarkItDown](https://github.com/microsoft/markitdown)、[PaddlePaddle CPU](https://www.paddlepaddle.org.cn/documentation/docs/en/install/pip/windows-pip_en.html)、[PaddleOCR](https://www.paddleocr.ai/main/en/version3.x/pipeline_usage/OCR.html)、[faster-whisper](https://github.com/SYSTRAN/faster-whisper)。

Skill 和脚本以 MIT 许可证发布。外部工具、模型、字体使用各自许可证；仓库不包含这些二进制或模型。此工作流旨在减少无关内容进入上下文；实际速度和 token 节省随任务而变化，目前不提供量化节省承诺。
