"""Return compact ffprobe metadata, never the raw probe dump."""
import argparse
from pathlib import Path
from _common import cli, emit, fps, number, probe, write_json

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('-o', '--output', type=Path, help='Optionally save the compact JSON')
    args = parser.parse_args()
    path = args.input.resolve(strict=True)
    data = probe(path)
    streams = data.get('streams', [])
    videos = [s for s in streams if s.get('codec_type') == 'video']
    duration = number(data.get('format', {}).get('duration'))
    if duration is None:
        durations = [number(s.get('duration')) for s in streams]
        duration = max((d for d in durations if d is not None), default=None)
    result = {'file': str(path), 'size_bytes': path.stat().st_size,
              'duration_seconds': duration,
              'video': [{'index': s['index'], 'resolution': [s.get('width'), s.get('height')],
                         'fps': fps(s.get('avg_frame_rate')) or fps(s.get('r_frame_rate')),
                         'codec': s.get('codec_name')} for s in videos],
              'audio_streams': [{'index': s['index'], 'codec': s.get('codec_name'),
                                'channels': s.get('channels'), 'sample_rate': s.get('sample_rate'),
                                'language': s.get('tags', {}).get('language')} for s in streams
                               if s.get('codec_type') == 'audio'],
              'subtitle_streams': [{'index': s['index'], 'codec': s.get('codec_name'),
                                   'language': s.get('tags', {}).get('language')} for s in streams
                                  if s.get('codec_type') == 'subtitle']}
    if args.output:
        write_json(args.output, result)
    emit(result)

if __name__ == '__main__':
    cli(main)
