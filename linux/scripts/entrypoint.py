"""Launch installed helpers using UTF-8 configuration instead of hardcoded paths."""
import json
import os
import runpy
import sys
from pathlib import Path

SCRIPTS = {'inspect-media', 'extract-keyframes', 'contact-sheet', 'transcribe', 'batch-ocr', 'verify'}


def main():
    runtime = Path(__file__).resolve().parent
    state = json.loads((runtime / 'installation.json').read_text(encoding='utf-8-sig'))
    if len(sys.argv) < 2 or sys.argv[1] not in SCRIPTS:
        raise ValueError('Expected one of: ' + ', '.join(sorted(SCRIPTS)))
    script = Path(state['skill_directory']) / 'scripts' / (sys.argv[1] + '.py')
    os.environ['FAST_CONTEXT_HOME'] = str(runtime)
    sys.path.insert(0, str(script.parent))
    sys.argv = [str(script)] + sys.argv[2:]
    runpy.run_path(str(script), run_name='__main__')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(json.dumps({'status': 'error', 'error_type': type(exc).__name__, 'error': str(exc)[:800]}))
        raise SystemExit(1)
