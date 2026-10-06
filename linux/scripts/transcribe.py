"""Local faster-whisper transcription; default small/CPU/int8, concise stdout."""
import argparse
import contextlib
import os
from pathlib import Path
from _common import RUNTIME, cli, emit, sanitize_no_proxy, stamp, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Audio or video containing audio')
    parser.add_argument('-o', '--output', type=Path, required=True, help='Output basename, e.g. work/transcript')
    parser.add_argument('--model', default='small', help='Model name or existing local model directory')
    parser.add_argument('--device', choices=['cpu', 'cuda', 'auto'], default='cpu')
    parser.add_argument('--compute-type', default='int8')
    parser.add_argument('--cpu-threads', type=int, default=min(8, max(1, (os.cpu_count() or 4) // 2)))
    parser.add_argument('--language', help='Language code, e.g. zh or en; otherwise detect')
    parser.add_argument('--format', choices=['json', 'md', 'both'], default='both')
    parser.add_argument('--word-timestamps', action='store_true')
    parser.add_argument('--no-vad', action='store_true', help='Disable silence filtering')
    parser.add_argument('--local-files-only', action='store_true', help='Use cached models without network access')
    parser.add_argument('--download-root', type=Path, default=RUNTIME / 'models' / 'whisper')
    args = parser.parse_args()
    if not 1 <= args.cpu_threads <= 32:
        parser.error('cpu-threads must be 1..32')
    source = args.input.resolve(strict=True)
    base = args.output.resolve()
    # Permit either a basename or an explicit .json/.md output argument.
    if base.suffix.lower() in ('.json', '.md'):
        base = base.with_suffix('')
    base.parent.mkdir(parents=True, exist_ok=True)
    args.download_root.mkdir(parents=True, exist_ok=True)
    # Standard HTTPS is a conservative default when Xet connections time out.
    # The caller may opt back into Xet by setting HF_HUB_DISABLE_XET=0.
    os.environ.setdefault('HF_HUB_DISABLE_XET', '1')
    os.environ.setdefault('HF_HUB_DOWNLOAD_TIMEOUT', '30')
    # httpx (via huggingface_hub) cannot parse IPv6 literals in no_proxy.
    sanitize_no_proxy()
    log = base.with_name(base.name + '.log')
    with log.open('w', encoding='utf-8') as logfile, contextlib.redirect_stdout(logfile), contextlib.redirect_stderr(logfile):
        from faster_whisper import WhisperModel
        model = WhisperModel(args.model, device=args.device, compute_type=args.compute_type,
                             cpu_threads=args.cpu_threads, num_workers=1,
                             download_root=str(args.download_root), local_files_only=args.local_files_only)
        segments, info = model.transcribe(str(source), language=args.language, beam_size=5,
                                          vad_filter=not args.no_vad, word_timestamps=args.word_timestamps)
        rows = []
        for segment in segments:
            row = {'start': round(segment.start, 3), 'end': round(segment.end, 3), 'text': segment.text.strip()}
            if args.word_timestamps:
                row['words'] = [{'start': round(w.start, 3), 'end': round(w.end, 3),
                                 'word': w.word, 'probability': round(w.probability, 4)}
                                for w in (segment.words or [])]
            rows.append(row)
    result = {'source': str(source), 'model': args.model, 'device': args.device,
              'compute_type': args.compute_type, 'language': info.language,
              'language_probability': round(info.language_probability, 4),
              'duration_seconds': round(info.duration, 3), 'segments': rows}
    outputs = []
    if args.format in ('json', 'both'):
        destination = base.with_name(base.name + '.json')
        write_json(destination, result)
        outputs.append(str(destination))
    if args.format in ('md', 'both'):
        destination = base.with_name(base.name + '.md')
        header = f'# Transcript\n\nLanguage: {info.language}; model: {args.model}\n\n'
        text = '\n'.join(f'[{stamp(s["start"])} - {stamp(s["end"])}] {s["text"]}' for s in rows)
        destination.write_text(header + text + '\n', encoding='utf-8')
        outputs.append(str(destination))
    emit({'segments': len(rows), 'language': info.language,
          'duration_seconds': round(info.duration, 3), 'files': outputs, 'log': str(log)})


if __name__ == '__main__':
    cli(main)
