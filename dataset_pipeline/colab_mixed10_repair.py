"""One interactive Colab A10 candidate job; no LLM API, deployment or B11 work.

Requires a frozen package and the original owner's mounted Drive source files.
Paid GPU use is disabled: the caller must verify a free Colab GPU session.
The package's public candidate annotations are not independent human approval.
"""
from pathlib import Path, PurePosixPath
import argparse
import copy
import hashlib
import json
import os
import shutil
import sys
import time
import zipfile

import torch
import yaml
from ultralytics import YOLO

from coverage_training import CoverageTrainer
from argmax_validation import AppArgmaxCoverageValidator

NAMES = ['person', 'bicycle', 'bin', 'bollard', 'traffic_cone',
         'caution_slippery', 'stairs', 'escalator', 'fence', 'door']


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def prepare(package, workspace, drive):
    manifest = json.loads((package / 'manifest.json').read_text())
    source_root = drive / 'PathGuide/mixed-source-20261026-v1'
    source = source_root / 'continuation-20261026T105623Z/candidate-best.pt'
    for name, expected in manifest['original_metadata_sha256'].items():
        assert digest(source_root / name) == expected, 'Original metadata changed: ' + name
    assert digest(source) == manifest['source_pt_sha256'], 'Original model changed'
    rows = [json.loads(line) for line in (source_root / 'records.jsonl').read_text().splitlines()]
    original_coverage = json.loads((source_root / 'coverage.json').read_text())
    filenames = {Path(name).stem: name for name in original_coverage}
    selected = set(manifest['original_train_ids'])
    assert all(r['split'] == 'train' for r in rows if r['id'] in selected)
    rows = [r for r in rows if r['id'] in selected or r['split'] == 'val']
    assert len(rows) == manifest['original_train_unique'] + manifest['original_validation_count']
    by_id = {r['id']: r for r in rows}
    data = workspace / 'dataset'
    for split in ['train', 'val']:
        (data / split / 'images').mkdir(parents=True)
        (data / split / 'labels').mkdir()

    def save_source(row, raw):
        assert hashlib.sha256(raw).hexdigest() == row['image_sha256'], row['id']
        (data / row['split'] / 'images' / filenames[row['id']]).write_bytes(raw)

    # Selective extraction: original test photos are never extracted or inferred.
    wanted = {r['id'] for r in rows if r['source'] == 'legacy-hk9'}
    with zipfile.ZipFile(drive / 'pathguide-hk-8classes.zip') as archive:
        found = set()
        for member in archive.infolist():
            name = PurePosixPath(member.filename).name
            if Path(name).suffix.lower() not in ['.jpg', '.jpeg', '.png']:
                continue
            identity = 'hk9-' + hashlib.sha256(name.encode()).hexdigest()[:20]
            if identity in wanted:
                save_source(by_id[identity], archive.read(member)); found.add(identity)
        assert found == wanted, 'Missing original legacy images'
    needed_public = {r['id']: manifest['original_public_filenames'][r['id']]
                     for r in rows if r['source'] in ['indoor-ccby4', 'macao-ccby4']}
    by_name = {name: identity for identity, name in needed_public.items()}
    with zipfile.ZipFile(source_root / 'PathGuide-Mixed-Source-Assets-20261026.zip') as archive:
        found = set()
        for member in archive.infolist():
            identity = by_name.get(PurePosixPath(member.filename).name)
            if identity:
                raw = archive.read(member)
                if hashlib.sha256(raw).hexdigest() == by_id[identity]['image_sha256']:
                    save_source(by_id[identity], raw); found.add(identity)
        assert found == set(needed_public), 'Missing original public source images'
    for r in rows:
        if r['source'] == 'oid-ccby2':
            save_source(r, (package / 'public_images' / (r['id'][4:] + '.jpg')).read_bytes())

    absence = json.loads((package / 'original-absence-review.json').read_text())
    for r in rows:
        if r['id'] in absence:
            assert r['split'] == 'train'
            patch = absence[r['id']]
            assert patch['image_sha256'] == r['image_sha256']
            r['coverage'] = sorted(set(r['coverage'] + patch['add_absent_classes']))
    fresh = json.loads((package / 'fresh-reviewed-candidates.json').read_text())['records']
    for r in fresh:
        assert r['split'] in ['train', 'val'] and not r['production_ready']
        filenames[r['id']] = r['id'] + '.jpg'
        save_source(r, (package / 'public_images' / (r['source_id'] + '.jpg')).read_bytes())
        rows.append(r)
    train_authors = {r['author'] for r in fresh if r['split'] == 'train'}
    val_authors = {r['author'] for r in fresh if r['split'] == 'val'}
    assert not train_authors & val_authors
    coverage = {}; train = []; val = []; index = []
    for r in rows:
        filename = filenames[r['id']]; image = data / r['split'] / 'images' / filename
        assert image.is_file()
        lines = []
        for box in r['boxes']:
            c = box['class_id']; x1, y1, x2, y2 = box['xyxy']
            assert c in r['coverage'] and 0 <= x1 < x2 <= 1 and 0 <= y1 < y2 <= 1
            lines.append(str(c) + ' ' + ' '.join(f'{x:.10f}' for x in
                         [(x1+x2)/2, (y1+y2)/2, x2-x1, y2-y1]))
        (data / r['split'] / 'labels' / (r['id'] + '.txt')).write_text('\n'.join(lines) + ('\n' if lines else ''))
        coverage[filename] = r['coverage']
        if r['split'] == 'train':
            repeat = (12 if r['boxes'] else 4) if r['id'].startswith('fresh-') else (4 if r['id'] in absence else 1)
            train.extend([str(image)] * repeat)
        else:
            val.append(str(image))
        index.append({**r, 'path': str(image), 'filename': filename})
    (data / 'train.txt').write_text('\n'.join(train) + '\n')
    (data / 'val.txt').write_text('\n'.join(val) + '\n')
    # Fixed epoch count; validation does not change hyperparameters or labels.
    (data / 'data.yaml').write_text(yaml.safe_dump({'path': str(data), 'train': str(data/'train.txt'),
        'val': str(data/'val.txt'), 'nc': 10, 'names': NAMES}, sort_keys=False))
    (workspace / 'coverage-repair.json').write_text(json.dumps(coverage))
    (workspace / 'source-index.json').write_text(json.dumps(index))
    (workspace / 'absence-review.json').write_text(json.dumps(absence))
    return source, manifest


def run(package, workspace, drive, persist):
    assert os.environ.get('PATHGUIDE_CONFIRMED_FREE_COLAB_GPU') == '1', 'Verify free GPU session first; paid GPU is disabled'
    assert torch.cuda.is_available(), 'No long CPU fallback or paid GPU submission'
    assert not workspace.exists(), 'Use a fresh workspace; never replace an active run'
    workspace.mkdir(parents=True)
    persist.mkdir(parents=True, exist_ok=False)
    source, manifest = prepare(package, workspace, drive)

    class RepairTrainer(CoverageTrainer):
        coverage_manifest = workspace / 'coverage-repair.json'

        def _model_train(self):
            super()._model_train()
            for module in self.model.modules():
                if isinstance(module, torch.nn.modules.batchnorm._BatchNorm):
                    module.eval()

        def get_validator(self):
            self.loss_names = 'box_loss', 'cls_loss', 'dfl_loss'
            return AppArgmaxCoverageValidator(self.test_loader, save_dir=self.save_dir,
                args=copy.copy(self.args), _callbacks=self.callbacks, coverage=self.coverage)

    def preserve(trainer):
        for source_file, name in [(trainer.last, 'candidate-last.pt'), (trainer.best, 'candidate-best.pt'), (trainer.csv, 'results.csv')]:
            if Path(source_file).is_file():
                pending = persist / (name + '.pending')
                shutil.copy2(source_file, pending); pending.replace(persist / name)
        (persist / 'progress.json').write_text(json.dumps({'status': 'training', 'epoch': trainer.epoch+1,
            'total_epochs': 6, 'deployment_authorized': False}))

    model = YOLO(str(source))
    assert list(model.names.values()) == NAMES and model.model.model[-1].nc == 10
    model.add_callback('on_model_save', preserve)
    args = dict(data=str(workspace/'dataset/data.yaml'), device=0, imgsz=640,
        epochs=6, patience=10, batch=16, nbs=16, workers=2, optimizer='AdamW',
        lr0=.0002, lrf=.3, warmup_epochs=.5, weight_decay=.0001, freeze=10,
        amp=False, cache=False, plots=False, resume=False, save=True, save_period=-1,
        mosaic=0, mixup=0, cutmix=0, copy_paste=0, multi_scale=False, rect=False,
        degrees=2., translate=.05, scale=.1, fliplr=.5, flipud=0., hsv_s=.25, hsv_v=.2,
        val=False, conf=.001, iou=.45, max_det=100, seed=30, deterministic=True,
        project=str(workspace/'runs'), name='repair', exist_ok=False)
    (persist/'frozen-config.json').write_text(json.dumps(args, indent=2))
    (persist/'package-manifest.json').write_text(json.dumps(manifest, indent=2))
    started = time.monotonic()
    model.train(trainer=RepairTrainer, **args)
    checkpoint = Path(model.trainer.last)
    portable = YOLO(str(checkpoint))
    assert list(portable.names.values()) == NAMES and not hasattr(portable.model, 'criterion')
    result = {'arm': 'repair', 'checkpoint': str(checkpoint), 'checkpoint_sha256': digest(checkpoint),
        'source_pt_sha256': digest(source), 'wall_seconds': time.monotonic()-started,
        'head_reinitialized': False, 'deployment_authorized': False, 'quality_gate_passed': False,
        'torch_version': torch.__version__, 'gpu': torch.cuda.get_device_name(0),
        'free_gpu_verified_by_caller': True, 'paid_gpu_allowed': False}
    (workspace/'repair-result.json').write_text(json.dumps(result, indent=2))
    shutil.copy2(checkpoint, persist/'candidate-last.pt')
    (persist/'training-summary.json').write_text(json.dumps(result, indent=2))
    (persist/'progress.json').write_text(json.dumps({'status': 'trained_pending_evaluation',
        'deployment_authorized': False, 'quality_gate_passed': False}))
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--drive', type=Path, default=Path('/content/drive/MyDrive'))
    parser.add_argument('--persist', type=Path, required=True)
    options = parser.parse_args()
    run(options.package.resolve(), options.workspace.resolve(), options.drive.resolve(), options.persist.resolve())
