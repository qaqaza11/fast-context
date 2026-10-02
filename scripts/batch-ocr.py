"""PaddleOCR 3.x: bounded Windows process pool, per-image text/JSON, compact index."""
import argparse
import contextlib
import gc
import os
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from _common import cli, emit, write_json

_ocr = None
_ocr_error = None
EXTENSIONS = {'.png', '.jpg', '.jpeg', '.bmp', '.tif', '.tiff', '.webp'}

def engine(config):
    global _ocr, _ocr_error
    if _ocr_error:
        raise RuntimeError(_ocr_error)
    if _ocr is None:
        # Process-local settings only; no CUDA or global environment changes.
        os.environ.setdefault('PADDLE_PDX_MODEL_SOURCE', 'BOS')
        os.environ.setdefault('PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK', 'True')
        os.environ.setdefault('OMP_NUM_THREADS', str(config['cpu_threads']))
        os.environ.setdefault('GLOG_minloglevel', '2')
        try:
            from paddleocr import PaddleOCR
            _ocr = PaddleOCR(device='cpu',
                             text_detection_model_name=config['det_model'],
                             text_recognition_model_name=config['rec_model'],
                             use_doc_orientation_classify=False, use_doc_unwarping=False,
                             use_textline_orientation=False, cpu_threads=config['cpu_threads'],
                             enable_mkldnn=False)
        except Exception as exc:
            _ocr_error = str(exc)[:600]
            raise
    return _ocr

def log_file(output):
    log_dir = Path(output) / '.logs'
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir / f'worker-{os.getpid()}.log'

def process_one(source, root, output, config):
    path = Path(source)
    relative = path.relative_to(Path(root))
    destination = Path(output) / 'images' / relative
    text_path = destination.with_name(destination.name + '.txt')
    json_path = destination.with_name(destination.name + '.json')
    destination.parent.mkdir(parents=True, exist_ok=True)
    summary = {'file': relative.as_posix(), 'status': 'ok',
               'text': str(text_path), 'json': str(json_path)}
    try:
        # A bad image must fail independently before it can reach the native predictor.
        from PIL import Image
        with Image.open(path) as image:
            image.verify()
        with log_file(output).open('a', encoding='utf-8') as logfile, contextlib.redirect_stdout(logfile), contextlib.redirect_stderr(logfile):
            results = engine(config).predict(str(path))
            lines = []
            for page in results:
                texts = page.get('rec_texts', [])
                scores = page.get('rec_scores', [])
                boxes = page.get('rec_polys', [])
                for index, text in enumerate(texts):
                    confidence = float(scores[index]) if index < len(scores) else None
                    box = boxes[index].tolist() if index < len(boxes) else None
                    lines.append({'text': str(text), 'confidence': round(confidence, 4) if confidence is not None else None,
                                  'polygon': box})
        text_path.write_text('\n'.join(row['text'] for row in lines) + '\n', encoding='utf-8')
        low = sum(row['confidence'] is None or row['confidence'] < config['confidence'] for row in lines)
        write_json(json_path, {'source': str(path), 'status': 'ok', 'lines': lines,
                               'low_confidence_count': low})
        summary.update(lines=len(lines), low_confidence=low)
    except Exception as exc:
        summary.update(status='error', error=str(exc)[:600])
        summary.pop('text', None)
        write_json(json_path, {'source': str(path), 'status': 'error', 'error': summary['error']})
    return summary

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Directory containing images')
    parser.add_argument('-o', '--output', type=Path, required=True)
    parser.add_argument('--recursive', action='store_true')
    parser.add_argument('--workers', type=int, default=min(4, max(1, (os.cpu_count() or 4) // 8)))
    parser.add_argument('--cpu-threads', type=int, default=2, help='Threads per OCR worker')
    parser.add_argument('--confidence', type=float, default=0.55, help='Flag low-confidence lines without discarding them')
    parser.add_argument('--det-model', default='PP-OCRv5_mobile_det')
    parser.add_argument('--rec-model', default='PP-OCRv5_mobile_rec', help='Default supports Chinese and English')
    args = parser.parse_args()
    if not 1 <= args.workers <= 8 or not 1 <= args.cpu_threads <= 8 or not 0 <= args.confidence <= 1:
        parser.error('workers and cpu-threads must be 1..8, confidence 0..1')
    root, output = args.input.resolve(strict=True), args.output.resolve()
    if not root.is_dir():
        raise ValueError('input must be an image directory')
    if root == output or root.is_relative_to(output):
        raise ValueError('output must not equal or contain the input directory')
    candidates = root.rglob('*') if args.recursive else root.iterdir()
    images = sorted(p for p in candidates if p.is_file() and p.suffix.lower() in EXTENSIONS
                    and not p.resolve().is_relative_to(output))
    if not images:
        raise ValueError('No supported images found.')
    output.mkdir(parents=True, exist_ok=True)
    config = {'cpu_threads': args.cpu_threads, 'confidence': args.confidence,
              'det_model': args.det_model, 'rec_model': args.rec_model}
    workers = min(args.workers, len(images))
    if workers == 1:
        rows = [process_one(str(p), str(root), str(output), config) for p in images]
    else:
        # Warm/download once before spawning, avoiding simultaneous model downloads.
        global _ocr
        try:
            with log_file(output).open('a', encoding='utf-8') as logfile, contextlib.redirect_stdout(logfile), contextlib.redirect_stderr(logfile):
                engine(config)
        except Exception as exc:
            raise RuntimeError(f'OCR model initialization failed; see {log_file(output)}: {str(exc)[:600]}') from exc
        _ocr = None
        gc.collect()
        rows = []
        with ProcessPoolExecutor(max_workers=workers) as pool:
            pending = {pool.submit(process_one, str(p), str(root), str(output), config): p for p in images}
            for future in as_completed(pending):
                try:
                    rows.append(future.result())
                except Exception as exc:
                    rows.append({'file': pending[future].relative_to(root).as_posix(),
                                 'status': 'error', 'error': str(exc)[:600]})
    rows.sort(key=lambda row: row['file'])
    successes = sum(row['status'] == 'ok' for row in rows)
    index = output / 'index.json'
    write_json(index, {'input': str(root), 'workers': workers, 'success': successes,
                       'failed': len(rows) - successes, 'images': rows})
    emit({'success': successes, 'failed': len(rows) - successes, 'workers': workers, 'index': str(index)})
    return 0 if successes else 1

if __name__ == '__main__':
    cli(main)
