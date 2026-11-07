"""Run in the pinned Colab environment (requires torch + ultralytics)."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import unittest
import json
import tempfile
import torch
from coverage_training import CoverageBCE,coverage_mask,CoverageValidator,load_coverage
from ultralytics.models.yolo.detect import DetectionValidator
from unittest.mock import patch

class CoverageTests(unittest.TestCase):
    def test_twelve_class_symbol_manifest_and_gradients(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'coverage.json'
            p.write_text(json.dumps({'icons.jpg':[0,1,2,4,5,6,7], 'arrows.jpg':[8,9,10,11]}))
            manifest=load_coverage(p,nc=12)
            with self.assertRaisesRegex(ValueError,'Invalid coverage class'):
                load_coverage(p,nc=10)
        bce=CoverageBCE();bce.mask=coverage_mask(['icons.jpg','arrows.jpg'],manifest,12,'cpu')
        logits=torch.zeros(2,3,12,requires_grad=True);targets=torch.zeros_like(logits)
        targets[1,0,11]=1;bce(logits,targets).sum().backward()
        self.assertEqual(logits.grad[0,:,11].abs().sum().item(),0)
        self.assertLess(logits.grad[1,0,11].item(),0)

    def test_unknown_classes_have_zero_gradient_in_mixed_batch(self):
        manifest={'old.jpg':list(range(8)),'door.jpg':[0,2,9],'fence.jpg':[8]}
        mask=coverage_mask(['/a/old.jpg','/b/door.jpg','/c/fence.jpg'],manifest,10,'cpu')
        logits=torch.zeros(3,6,10,requires_grad=True);targets=torch.zeros_like(logits)
        targets[0,0,6]=1;targets[1,0,9]=1;targets[2,0,8]=1
        bce=CoverageBCE();bce.mask=mask;bce(logits,targets).sum().backward()
        g=logits.grad
        self.assertTrue(torch.equal(g[mask.expand_as(g)==0],torch.zeros_like(g[mask.expand_as(g)==0])))
        self.assertTrue((g[mask.expand_as(g)>0].abs()>0).all())
        self.assertLess(g[1,0,9].item(),0);self.assertGreater(g[1,1,9].item(),0)

    def test_missing_coverage_fails_closed(self):
        with self.assertRaisesRegex(ValueError,'Missing coverage'):coverage_mask(['unknown.jpg'],{},10,'cpu')

    def test_positive_unknown_class_is_rejected(self):
        bce=CoverageBCE();bce.mask=torch.zeros(1,1,10)
        with self.assertRaisesRegex(ValueError,'Positive target'):bce(torch.zeros(1,2,10),torch.ones(1,2,10))

    def test_single_source_full_coverage_equals_standard_bce(self):
        logits=torch.randn(2,12,10);targets=torch.rand_like(logits)
        bce=CoverageBCE();bce.mask=torch.ones(2,1,10)
        self.assertTrue(torch.equal(bce(logits,targets),torch.nn.functional.binary_cross_entropy_with_logits(logits,targets,reduction='none')))

    def test_validation_does_not_count_unknown_class_predictions(self):
        validator=object.__new__(CoverageValidator)
        validator.device='cpu';validator.nc=10;validator.coverage={'door.jpg':[9]}
        preds=[{'cls':torch.tensor([0.,9.,8.,9.]),'conf':torch.tensor([.9,.8,.7,.6]),'bboxes':torch.arange(16).reshape(4,4)}]
        batch={'im_file':['door.jpg']}
        with patch.object(DetectionValidator,'update_metrics',side_effect=lambda p,b:p):
            filtered=validator.update_metrics(preds,batch)
        self.assertEqual(filtered[0]['cls'].tolist(),[9.,9.])
        self.assertEqual(filtered[0]['bboxes'].tolist(),[[4,5,6,7],[12,13,14,15]])
        self.assertEqual(len(preds[0]['cls']),4)  # preserve raw predictions

if __name__=='__main__':unittest.main()
