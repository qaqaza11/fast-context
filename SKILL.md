---
name: fast-context
description: Reduce context and token usage for large repositories, logs, datasets, documents, text-heavy images, audio, and video by searching, filtering, extracting, OCRing, transcribing, and sampling before loading full content.
---

# Fast Context

Do not load large raw inputs when local preprocessing can narrow them first.
Use progressive disclosure: metadata -> search/filter -> compact extraction -> relevant sections -> original high-detail regions when necessary. Preserve correctness; inspect visual or structural information that extraction loses.

## Code and logs

- Never recursively read an entire repository. Use `fd` for candidate paths, `rg` for strings/symbols/references, and `sg` (`ast-grep`) for AST structure. Search large source files before reading relevant line ranges.
- Respect `.gitignore`. Exclude generated/vendor trees unless relevant: `.git`, `node_modules`, `dist`, `build`, `target`, `.venv`, `venv`, `__pycache__`, `coverage`. Bound matches with `rg -n -m 20`; avoid dumping thousands of filenames.
- For logs, first search `error|exception|fatal|warning|failed|traceback|panic` with case-insensitive `rg` and nearby context. Deduplicate repetitive noise while preserving timestamps, the first meaningful error, stack traces, and preceding warnings. Save large matches locally and inspect relevant ranges.

## Data and documents

- Inspect JSON/CSV schemas, row counts, columns, selected fields, filters, aggregates, deduplication, and representative samples locally. Calculate exact totals locally; return only needed subsets.
- For ordinary text-heavy PDF/Office/HTML/CSV/JSON/EPUB, try `markitdown input -o work/document.md`, then search headings/keywords and inspect nearby sections.
- If conversion loses layout, tables, equations, diagrams, or scanned text, render/OCR or visually inspect only the relevant pages. Do not route every media file through MarkItDown.

## Images, audio, and video

- For text-heavy screenshots, pages, slides, forms, code, and UI, OCR first. Use confidence and text as primary context; inspect the original for insufficient OCR, spatial relations, diagrams, ambiguous equations, icons/colors/shapes, or requested visual detail.
- For many images, use bounded OCR workers and independent per-image outputs; search results before loading text. A failed image must not prevent others from finishing.
- For audio, transcribe locally with segment start/end timestamps, then search the transcript and inspect relevant ranges. Enable word timestamps only when needed.
- For video: inspect ffprobe metadata and existing subtitles first; use subtitles when sufficient. Otherwise extract/transcribe audio, sample scene/keyframes, OCR text-heavy frames, and build a timestamp index. For screen recordings/lectures/tutorials prefer transcription + OCR + sparse frames.
- Initially cap long-video previews at about 30-60 frames (default 48). Use a contact sheet; do not send dozens of full-resolution images or analyze every frame by default. Once a timestamp is relevant, extract a short high-quality interval. Bound concurrency for independent segments.

## Local helpers

On Windows, install with `pwsh -File <skill-directory>/install.ps1` when dependencies or launchers are missing. This installer reuses working tools and keeps dependencies in a user-only Python 3.12 environment. See [README.md](README.md) only for installation or troubleshooting.
Default runtime: `<user-home>/.codex/tools/fast-context/.venv/Scripts/python.exe`; override with `FAST_CONTEXT_HOME` when using a custom runtime. Scripts live beside this file under `scripts/`; prefer the launchers below, or run the script with that Python. All accept `--help` without loading models. Use explicit output directories under the task's `work/` (or a requested destination).

| Command | Purpose |
|---|---|
| `fc-inspect-media VIDEO` | Compact duration, size, resolution, fps, codec, audio/subtitles |
| `fc-extract-keyframes VIDEO -o work/frames --max-frames 48` | Scene-first frames plus uniform fallback; `frames.json` maps timestamps |
| `fc-contact-sheet work/frames -o work/contact.jpg` | Small timestamp-labelled overview |
| `fc-transcribe AUDIO_OR_VIDEO -o work/transcript` | faster-whisper small, CPU/int8; JSON + Markdown with segment times |
| `fc-batch-ocr IMAGE_DIR -o work/ocr` | PaddleOCR mobile models, Chinese/English; per-image TXT/JSON + index |

Scene detection scans the full video at low resolution; use `--uniform-only` for a faster initial pass on very long videos. OCR defaults to at most four workers with two CPU threads each; lower `--workers` on busy machines. OCR disables orientation/unwarping by default for speed; rotate/preprocess affected pages or inspect them when needed. Whisper supports `--model base`, explicit model paths, `--language zh`, and cached `--local-files-only`. First use may download a selected model; retain model caches.

## Output discipline

Return counts, summaries, paths, timestamps, matches, and short relevant excerpts. Keep complete dependency output, large JSON, OCR results, transcripts, and logs in local files. Never paste them wholesale unless requested. Cheapest useful order: metadata -> search/filter -> text extraction -> OCR/transcription -> thumbnails/keyframes -> original region.
