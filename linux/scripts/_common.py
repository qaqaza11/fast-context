"""Shared local I/O helpers. No third-party imports at startup."""
import json
import os
import shutil
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

RUNTIME = Path(os.environ.get('FAST_CONTEXT_HOME', str(Path.home() / '.local' / 'share' / 'fast-context'))).expanduser()


def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(',', ':')))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, path)


def tool(name):
    found = shutil.which(name)
    if found:
        return found
    state_file = RUNTIME / 'installation.json'
    if state_file.is_file():
        state = json.loads(state_file.read_text(encoding='utf-8-sig'))
        configured = state.get('tools', {}).get(name)
        if configured and Path(configured).is_file():
            return configured
    # Common user-local bin locations used by this installer.
    for directory in (Path.home() / '.local' / 'bin', Path('/usr/local/bin')):
        candidate = directory / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise RuntimeError(f'{name} is unavailable; open a new terminal or check the user installation.')


def run(command, timeout=120):
    result = subprocess.run([str(x) for x in command], capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{Path(str(command[0])).name} failed ({result.returncode}): {result.stderr[-1200:].strip()}')
    return result.stdout


def probe(path):
    path = Path(path).resolve(strict=True)
    return json.loads(run([tool('ffprobe'), '-v', 'error', '-show_format', '-show_streams',
                           '-of', 'json', str(path)]))


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def fps(value):
    try:
        return round(float(Fraction(value)), 3)
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def stamp(seconds):
    milliseconds = max(0, round(float(seconds) * 1000))
    hours, milliseconds = divmod(milliseconds, 3600000)
    minutes, milliseconds = divmod(milliseconds, 60000)
    seconds, milliseconds = divmod(milliseconds, 1000)
    return f'{hours:02d}:{minutes:02d}:{seconds:02d}.{milliseconds:03d}'


def sample(items, limit):
    if len(items) <= limit:
        return list(items)
    if limit == 1:
        return [items[len(items) // 2]]
    return [items[round(i * (len(items) - 1) / (limit - 1))] for i in range(limit)]


def sanitize_no_proxy():
    """Drop IPv6 literals from no_proxy: httpx (used by huggingface_hub) raises
    InvalidURL on entries like [::1]. Process-local only."""
    for key in ('no_proxy', 'NO_PROXY'):
        value = os.environ.get(key)
        if not value:
            continue
        kept = [part for part in (p.strip() for p in value.split(','))
                if part and not (part.startswith('[') or part.count(':') > 1)]
        os.environ[key] = ','.join(kept)


def cli(main):
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    try:
        code = main()
    except Exception as exc:
        emit({'status': 'error', 'error_type': type(exc).__name__, 'error': str(exc)[:1600]})
        code = 1
    raise SystemExit(code or 0)
