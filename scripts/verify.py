"""Real smoke tests. Models are tested only with --models; concise JSON output."""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import wave
from pathlib import Path
from _common import RUNTIME, cli, emit, tool, write_json

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models', action='store_true', help='Run real OCR and small-model inference; may download models')
    parser.add_argument('--model-cache', type=Path, help='Reuse a specific Whisper cache during verification')
    parser.add_argument('--output', type=Path, default=RUNTIME / 'verification.json')
    parser.add_argument('--skip-ocr', action='store_true')
    parser.add_argument('--skip-audio', action='store_true')
    args = parser.parse_args()
    scripts = Path(__file__).resolve().parent
    state_file = RUNTIME / 'installation.json'
    state = json.loads(state_file.read_text(encoding='utf-8-sig')) if state_file.is_file() else {}
    groups = state.get('optional_groups', {'ocr': True, 'audio': True})
    use_ocr = not args.skip_ocr and groups.get('ocr', True)
    use_audio = not args.skip_audio and groups.get('audio', True)
    checks = []

    def check(name, command, accept=lambda r: r.returncode == 0):
        try:
            result = subprocess.run([str(c) for c in command], capture_output=True, text=True,
                                    encoding='utf-8', errors='replace', timeout=600 if args.models else 120)
            row = {'test': name, 'passed': bool(accept(result))}
            if not row['passed']:
                row['error'] = (result.stderr + result.stdout)[-1200:]
        except Exception as exc:
            row = {'test': name, 'passed': False, 'error': str(exc)[:800]}
        checks.append(row)

    manifest = scripts.parent / 'SKILL.md'
    text = manifest.read_text(encoding='utf-8')
    checks.append({'test': 'skill_frontmatter', 'passed': bool(re.match(r'^---\s*\nname: fast-context\n' , text)
                   and re.search(r'(?m)^description: .+\n---', text))})
    for name in ['inspect-media', 'extract-keyframes', 'contact-sheet', 'transcribe', 'batch-ocr']:
        check(name+'_help', [sys.executable, scripts / (name+'.py'), '--help'])
    for module in (['markitdown', 'PIL'] + (['paddle', 'paddleocr'] if use_ocr else []) + (['faster_whisper', 'av'] if use_audio else [])):
        check('import_'+module, [sys.executable, '-c', 'import '+module])
    with tempfile.TemporaryDirectory(prefix='fast-context-verify-') as temporary:
        root = Path(temporary)
        log = root / 'sample.log'
        log.write_text('INFO start\nERROR test failure\n', encoding='utf-8')
        check('rg_search', [tool('rg'), '-n', 'ERROR', log], lambda r: r.returncode == 0 and '2:' in r.stdout)
        source = root / 'sample.js'
        source.write_text('console.log("fast context");\n', encoding='utf-8')
        check('fd_search', [tool('fd'), '--extension', 'js', '.', root], lambda r: r.returncode == 0 and 'sample.js' in r.stdout)
        ast = state.get('tools', {}).get('ast-grep') or tool('ast-grep')
        check('ast_structural_search', [ast, 'run', '-l', 'javascript', '-p', 'console.log($ARG)', source, '--json=compact'],
              lambda r: r.returncode == 0 and any(x['text'].startswith('console.log') for x in json.loads(r.stdout)))
        html = root / 'sample.html'
        markdown = root / 'sample.md'
        html.write_text('<h1>Fast Context Test</h1><p>Relevant information.</p>', encoding='utf-8')
        check('markitdown_conversion', [sys.executable, '-m', 'markitdown', html, '-o', markdown],
              lambda r: r.returncode == 0 and '# Fast Context Test' in markdown.read_text(encoding='utf-8'))
        check('ffmpeg_version', [tool('ffmpeg'), '-version'])
        check('ffprobe_version', [tool('ffprobe'), '-version'])
        video = root / 'scene.mp4'
        command = [tool('ffmpeg'), '-hide_banner', '-nostdin', '-loglevel', 'error', '-y']
        for color in ['red', 'blue', 'green']:
            command.extend(['-f', 'lavfi', '-i', f'color=c={color}:s=320x180:r=5:d=2'])
        command.extend(['-filter_complex', '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]', '-map', '[v]',
                        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', video])
        check('synthetic_video', command)
        metadata = root / 'metadata.json'
        check('media_metadata', [sys.executable, scripts / 'inspect-media.py', video, '-o', metadata],
              lambda r: r.returncode == 0 and json.loads(metadata.read_text(encoding='utf-8'))['video'][0]['resolution'] == [320,180])
        frames = root / 'frames'
        check('scene_frames_and_cap', [sys.executable, scripts / 'extract-keyframes.py', video, '-o', frames, '--max-frames', '2'],
              lambda r: r.returncode == 0 and len(json.loads((frames/'frames.json').read_text(encoding='utf-8'))['frames']) == 2
              and json.loads((frames/'frames.json').read_text(encoding='utf-8'))['frames'][-1]['timestamp_seconds'] >= 3.9)
        fallback = root / 'uniform'
        check('uniform_fallback', [sys.executable, scripts / 'extract-keyframes.py', video, '-o', fallback, '--scene-threshold', '1'],
              lambda r: r.returncode == 0 and json.loads((fallback/'frames.json').read_text(encoding='utf-8'))['sampling'] == 'scene+uniform')
        sheet = root / 'contact.jpg'
        check('contact_sheet', [sys.executable, scripts / 'contact-sheet.py', frames, '-o', sheet],
              lambda r: r.returncode == 0 and sheet.is_file())
        if args.models and use_ocr:
            from PIL import Image, ImageDraw, ImageFont
            images = root / 'images'
            images.mkdir()
            fonts = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts'
            font_path = fonts / 'msyh.ttc'
            chinese = font_path.exists()
            if not chinese:
                font_path = fonts / 'arial.ttf'
            font = ImageFont.truetype(str(font_path), 44) if font_path.is_file() else ImageFont.load_default()
            image = Image.new('RGB', (950,230), 'white')
            draw = ImageDraw.Draw(image)
            draw.text((25,25), 'FAST CONTEXT TEST 2026', fill='black', font=font)
            if chinese:
                draw.text((25,100), '\u6587\u4ef6\u641c\u7d22\u4e0e\u56fe\u7247\u6587\u5b57\u8bc6\u522b', fill='black', font=font)
            image.save(images / 'first.png')
            image.save(images / 'second.jpg')
            (images / 'broken.png').write_bytes(b'invalid image fixture')
            output = root / 'ocr'
            def ocr_ok(result):
                if result.returncode:
                    return False
                index = json.loads((output/'index.json').read_text(encoding='utf-8'))
                if (index['success'],index['failed']) != (2,1):
                    return False
                for row in index['images']:
                    if row['status'] != 'ok':
                        continue
                    content = Path(row['text']).read_text(encoding='utf-8')
                    if 'FAST CONTEXT TEST 2026' not in content or (chinese and '\u6587\u4ef6\u641c\u7d22' not in content):
                        return False
                return True
            check('ocr_parallel_and_bad_image_isolation', [sys.executable, scripts/'batch-ocr.py', images, '-o', output, '--workers','2'], ocr_ok)
        if args.models and use_audio:
            audio = root / 'speech.wav'
            speech_available = False
            if os.name == 'nt':
                import shutil
                powershell = shutil.which('pwsh') or shutil.which('powershell')
                if powershell:
                    quoted = str(audio).replace("'", "''")
                    speech = "$v=New-Object -ComObject SAPI.SpVoice; $s=New-Object -ComObject SAPI.SpFileStream; $s.Open('"+quoted+"',3,$false); $v.AudioOutputStream=$s; [void]$v.Speak('Fast context test. Search files before reading the whole project.'); $s.Close()"
                    result = subprocess.run([powershell,'-NoProfile','-Command',speech],capture_output=True,timeout=60)
                    speech_available = result.returncode == 0 and audio.is_file()
            if not speech_available:
                with wave.open(str(audio), 'wb') as wav:
                    wav.setnchannels(1)
                    wav.setsampwidth(2)
                    wav.setframerate(16000)
                    wav.writeframes(b'\0\0'*16000)
            transcript = root / 'transcript'
            command = [sys.executable, scripts/'transcribe.py',audio,'-o',transcript,'--language','en']
            if not speech_available:
                command.append('--no-vad')
            if args.model_cache:
                command.extend(['--download-root',args.model_cache,'--local-files-only'])
            def transcript_ok(result):
                if result.returncode:
                    return False
                data = json.loads(transcript.with_suffix('.json').read_text(encoding='utf-8'))
                return data['model']=='small' and all(s['start'] < s['end'] for s in data['segments']) and (bool(data['segments']) or not speech_available)
            check('whisper_small_real_inference',command,transcript_ok)
    report = {'passed': sum(row['passed'] for row in checks), 'total': len(checks),
              'model_tests': args.models, 'checks': checks}
    write_json(args.output, report)
    emit({'passed': report['passed'], 'total': len(checks), 'failed': [row for row in checks if not row['passed']],
          'model_tests': args.models, 'record': str(args.output.resolve())})
    return 0 if all(row['passed'] for row in checks) else 1

if __name__ == '__main__':
    cli(main)
