"""Scene-first sparse frames with timestamps and uniform fallback."""
import argparse
import math
import re
import subprocess
import tempfile
from collections import deque
from pathlib import Path
from _common import cli, emit, number, probe, run, sample, stamp, tool, write_json


def scenes(path, threshold, width):
    command = [tool('ffmpeg'), '-hide_banner', '-nostdin', '-loglevel', 'info',
               '-threads', '2', '-i', str(path), '-map', '0:v:0', '-an', '-sn',
               '-vf', f"scale={width}:-2,select='eq(n,0)+gt(scene,{threshold})',showinfo",
               '-fps_mode', 'vfr', '-f', 'null', '-']
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               text=True, encoding='utf-8', errors='replace')
    times, tail = [], deque(maxlen=10)
    try:
        for line in process.stderr:
            tail.append(line.strip())
            match = re.search(r'pts_time:([\d.eE+-]+)', line)
            if match:
                times.append(float(match.group(1)))
        if process.wait():
            raise RuntimeError('Scene scan failed: ' + ' '.join(tail)[-1200:])
    finally:
        process.stderr.close()
        if process.poll() is None:
            process.kill()
            process.wait()
    return sorted(set(times))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('-o', '--output', type=Path, required=True, help='Frame output directory')
    parser.add_argument('--max-frames', type=int, default=48)
    parser.add_argument('--scene-threshold', type=float, default=0.30)
    parser.add_argument('--max-dimension', type=int, default=960)
    parser.add_argument('--uniform-only', action='store_true', help='Skip full video scene scanning')
    args = parser.parse_args()
    if not 1 <= args.max_frames <= 1000 or not 0 <= args.scene_threshold <= 1 or args.max_dimension < 32:
        parser.error('max-frames must be 1..1000, threshold 0..1, dimension >=32')
    path = args.input.resolve(strict=True)
    data = probe(path)
    if not any(s.get('codec_type') == 'video' for s in data.get('streams', [])):
        raise ValueError('Input has no video stream.')
    duration = number(data.get('format', {}).get('duration'))
    if duration is None or duration <= 0:
        raise ValueError('A finite positive duration is required; trim live/unknown-length inputs first.')
    desired = min(args.max_frames, max(1, math.ceil(duration / 5)))
    warnings = []
    times = []
    if not args.uniform_only:
        try:
            times = scenes(path, args.scene_threshold, 320)
        except RuntimeError as exc:
            warnings.append(str(exc)[:300])
    detected = len(times)
    mode = 'scene'
    if args.uniform_only or len(times) < min(desired, 4):
        mode = 'uniform' if not times else 'scene+uniform'
        for i in range(desired):
            timestamp = duration * (i + 0.5) / desired
            if not any(abs(timestamp - t) < min(0.5, duration / desired / 4) for t in times):
                times.append(timestamp)
    times = sample(sorted(set(round(t, 6) for t in times)), args.max_frames)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = output / 'frames.json'
    if manifest.exists():
        raise ValueError('Output already contains frames.json; choose a new directory to preserve previous results.')
    frames = []
    scale = f"scale=w='min({args.max_dimension},iw)':h='min({args.max_dimension},ih)':force_original_aspect_ratio=decrease"
    # Seeking separately bounds output and covers the full timeline even with many scene cuts.
    with tempfile.TemporaryDirectory(prefix='fc-frame-', dir=output) as scratch:
        for i, timestamp in enumerate(times, 1):
            filename = f'frame_{i:03d}_t{round(timestamp * 1000):012d}ms.jpg'
            temporary = Path(scratch) / filename
            run([tool('ffmpeg'), '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
                 '-ss', f'{timestamp:.6f}', '-threads', '2', '-i', str(path), '-map', '0:v:0',
                 '-frames:v', '1', '-an', '-sn', '-vf', scale, '-q:v', '3', str(temporary)])
            if not temporary.exists():
                warnings.append(f'No frame at {stamp(timestamp)}')
                continue
            destination = output / filename
            if destination.exists():
                raise ValueError(f'Refusing to overwrite {destination}')
            temporary.replace(destination)
            frames.append({'file': filename, 'timestamp_seconds': round(timestamp, 3),
                           'timestamp': stamp(timestamp)})
    if not frames:
        raise RuntimeError('No frames could be extracted.')
    write_json(manifest, {'source': str(path), 'duration_seconds': duration,
                         'sampling': mode, 'scene_candidates': detected, 'frames': frames,
                         'warnings': warnings})
    emit({'frames': len(frames), 'sampling': mode, 'scene_candidates': detected,
          'index': str(manifest), 'warnings': warnings[:3]})


if __name__ == '__main__':
    cli(main)
