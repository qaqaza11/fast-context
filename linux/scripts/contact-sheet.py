"""Make a compact timestamp-labelled contact sheet using Pillow."""
import argparse
import json
import math
import subprocess
from pathlib import Path
from _common import cli, emit, sample


def find_label_font():
    """Prefer a monospace TTF on Linux; fall back to Pillow's built-in font."""
    candidates = [
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'),
        Path('/usr/share/fonts/TTF/DejaVuSansMono.ttf'),
        Path.home() / '.local' / 'share' / 'fast-context' / 'fonts' / 'NotoSansSC-Regular.ttf',
    ]
    for path in candidates:
        if path.is_file():
            return str(path)
    try:
        result = subprocess.run(['fc-list', ':style=Regular', 'file'], capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=15)
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.lower().endswith('.ttf') and Path(line).is_file():
                return line
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Directory of frames, optionally containing frames.json')
    parser.add_argument('-o', '--output', type=Path, required=True)
    parser.add_argument('--max-frames', type=int, default=48)
    parser.add_argument('--columns', type=int, default=6)
    parser.add_argument('--thumb-width', type=int, default=240)
    args = parser.parse_args()
    if not 1 <= args.max_frames <= 1000 or not 1 <= args.columns <= 20 or not 64 <= args.thumb_width <= 1024:
        parser.error('Invalid frame limit, column count, or thumbnail width')
    from PIL import Image, ImageDraw, ImageFont, ImageOps
    directory = args.input.resolve(strict=True)
    output = args.output.resolve()
    manifest = directory / 'frames.json'
    if manifest.is_file():
        entries = json.loads(manifest.read_text(encoding='utf-8'))['frames']
        candidates = [(directory / item['file'], item['timestamp']) for item in entries]
    else:
        extensions = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tif', '.tiff'}
        candidates = [(p, p.name[:36]) for p in sorted(directory.iterdir())
                      if p.suffix.lower() in extensions and p.resolve() != output]
    candidates = sample(candidates, args.max_frames)
    if not candidates:
        raise ValueError('No frames found.')
    width, height, label_height = args.thumb_width, round(args.thumb_width * 2 / 3), 24
    columns = min(args.columns, len(candidates))
    canvas = Image.new('RGB', (columns * width, math.ceil(len(candidates) / columns) * (height + label_height)), '#20242a')
    draw = ImageDraw.Draw(canvas)
    font_file = find_label_font()
    font = ImageFont.truetype(font_file, 14) if font_file else ImageFont.load_default()
    good, failures = 0, []
    for i, (path, label) in enumerate(candidates):
        x, y = (i % columns) * width, (i // columns) * (height + label_height)
        try:
            with Image.open(path) as image:
                image = ImageOps.exif_transpose(image).convert('RGB')
                image.thumbnail((width - 8, height - 8), Image.Resampling.LANCZOS)
                canvas.paste(image, (x + (width - image.width) // 2, y + (height - image.height) // 2))
            good += 1
        except (OSError, ValueError) as exc:
            label = 'unreadable'
            failures.append({'file': str(path), 'error': str(exc)[:160]})
        draw.text((x + 6, y + height + 3), label, fill='white', font=font)
    if not good:
        raise ValueError('No readable images found.')
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)
    emit({'images': good, 'failed': len(failures), 'dimensions': list(canvas.size), 'file': str(output)})


if __name__ == '__main__':
    cli(main)
