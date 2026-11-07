"""Regressions for partial labels and the App's class competition."""
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import torch
from ultralytics.models.yolo.detect import DetectionValidator
from coverage_training import CoverageBCE, coverage_mask
from argmax_validation import AppArgmaxCoverageValidator


class AppClassSelectionTests(unittest.TestCase):
    def test_unknown_fence_outscores_door_instead_of_leaking_second_class_into_metrics(self):
        validator = object.__new__(AppArgmaxCoverageValidator)
        validator.nc = 10
        validator.device = 'cpu'
        validator.end2end = False
        validator.args = SimpleNamespace(conf=.3, iou=.45, task='detect',
                                        single_cls=False, agnostic_nms=False, max_det=100)
        validator.coverage = {'door.jpg': [9]}
        predictions = torch.zeros(1, 14, 2)
        predictions[0, :4, 0] = torch.tensor([320., 320., 200., 300.])
        predictions[0, 12, 0] = .96  # fence, unknown in the source annotations
        predictions[0, 13, 0] = .90  # door, known positive, but loses in the App
        legacy = DetectionValidator.postprocess(validator, predictions.clone())
        self.assertEqual(set(legacy[0]['cls'].tolist()), {8., 9.})
        selected = validator.postprocess(predictions.clone())
        self.assertEqual(selected[0]['cls'].tolist(), [8.])
        with patch.object(DetectionValidator, 'update_metrics', side_effect=lambda p, b: p):
            known = validator.update_metrics(selected, {'im_file': ['door.jpg']})
        self.assertEqual(known[0]['cls'].tolist(), [])
        # Keeping the lower-scored door would incorrectly conceal the App miss.

    def test_confirmed_absences_add_negative_gradient_without_unmasking_other_unknown_classes(self):
        gradients = []
        for known in [[9], [0, 8, 9]]:
            logits = torch.zeros(1, 2, 10, requires_grad=True)
            targets = torch.zeros_like(logits)
            targets[0, 0, 9] = 1
            loss = CoverageBCE()
            loss.mask = coverage_mask(['door.jpg'], {'door.jpg': known}, 10, 'cpu')
            loss(logits, targets).sum().backward()
            gradients.append(logits.grad)
        self.assertEqual(gradients[0][0, :, 8].abs().sum().item(), 0)
        self.assertTrue((gradients[1][0, :, [0, 8]] > 0).all())
        self.assertTrue((gradients[1][0, :, 7] == 0).all())
        self.assertLess(gradients[1][0, 0, 9].item(), 0)


if __name__ == '__main__':
    unittest.main()
