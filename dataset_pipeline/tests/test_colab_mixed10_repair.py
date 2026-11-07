"""Check source integrity and exclusion of reserved test pixels without a GPU."""
from pathlib import Path
import hashlib
import io
import json
import sys
import tempfile
import unittest
import zipfile

from PIL import Image
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from colab_mixed10_repair import digest, prepare


class RepairPreparationTests(unittest.TestCase):
    def fixture(self, root):
        package = root / 'package'; package.mkdir()
        drive = root / 'drive'; drive.mkdir()
        source = drive / 'PathGuide/mixed-source-20261026-v1'; source.mkdir(parents=True)
        model = source / 'continuation-20261026T105623Z/candidate-best.pt'
        model.parent.mkdir(); model.write_bytes(b'fixture-checkpoint-not-executed')
        rows = []; coverage = {}; images = {}
        for split, name, color in [('train', 'train.jpg', 'red'), ('val', 'val.jpg', 'blue'), ('test', 'test.jpg', 'green')]:
            stream = io.BytesIO(); Image.new('RGB', (32, 32), color).save(stream, format='JPEG')
            raw = stream.getvalue(); identity = 'hk9-' + hashlib.sha256(name.encode()).hexdigest()[:20]
            rows.append({'id': identity, 'source': 'legacy-hk9', 'split': split,
                         'image_sha256': hashlib.sha256(raw).hexdigest(),
                         'boxes': [{'class_id': 0, 'xyxy': [.1, .1, .9, .9]}], 'coverage': list(range(8))})
            coverage[identity + '.jpg'] = list(range(8)); images[(split, name)] = raw
        (source/'records.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        (source/'coverage.json').write_text(json.dumps(coverage))
        with zipfile.ZipFile(drive/'pathguide-hk-8classes.zip', 'w') as archive:
            for (split, name), raw in images.items(): archive.writestr(f'{split}/images/{name}', raw)
            archive.writestr('../../outside.txt', b'never extract arbitrary archive entries')
        with zipfile.ZipFile(source/'PathGuide-Mixed-Source-Assets-20261026.zip', 'w'):
            pass
        manifest = {'original_metadata_sha256': {n: digest(source/n) for n in ['records.jsonl', 'coverage.json']},
                    'source_pt_sha256': digest(model), 'original_train_ids': [rows[0]['id']],
                    'original_train_unique': 1, 'original_validation_count': 1, 'original_public_filenames': {}}
        (package/'manifest.json').write_text(json.dumps(manifest))
        (package/'original-absence-review.json').write_text('{}')
        (package/'fresh-reviewed-candidates.json').write_text('{"records": []}')
        return package, drive, rows

    def test_selective_extraction_preserves_splits_and_never_extracts_test_or_arbitrary_members(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); package, drive, rows = self.fixture(root)
            prepare(package, root/'work', drive)
            files = list((root/'work/dataset').rglob('*.jpg'))
            self.assertEqual({f.stem for f in files}, {r['id'] for r in rows if r['split'] != 'test'})
            self.assertFalse((root/'work/dataset/test').exists())
            self.assertFalse((root/'outside.txt').exists())
            train = (root/'work/dataset/train.txt').read_text()
            self.assertIn(rows[0]['id'], train)
            self.assertNotIn(rows[1]['id'], train)
            self.assertNotIn(rows[2]['id'], train)

    def test_metadata_drift_fails_before_extraction(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); package, drive, _ = self.fixture(root)
            (drive/'PathGuide/mixed-source-20261026-v1/coverage.json').write_text('{}')
            with self.assertRaisesRegex(AssertionError, 'Original metadata changed'):
                prepare(package, root/'work', drive)
            self.assertFalse((root/'work/dataset').exists())


if __name__ == '__main__':
    unittest.main()
