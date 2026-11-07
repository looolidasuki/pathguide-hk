"""A-model class selection matching the App's one-class-per-anchor decoder.

Coverage still filters unknown classes only after argmax and NMS. The legacy
CoverageValidator retains its existing behaviour for other experiments/B11.
This does not replace camera-format or native postprocessing parity checks.
Requires the same Ultralytics 8.4.182 environment as coverage_training.
"""
from ultralytics.utils import nms
from coverage_training import CoverageValidator


class AppArgmaxCoverageValidator(CoverageValidator):
    def postprocess(self, preds):
        outputs = nms.non_max_suppression(
            preds, self.args.conf, self.args.iou,
            nc=0 if self.args.task == 'detect' else self.nc,
            multi_label=False,
            agnostic=self.args.single_cls or self.args.agnostic_nms,
            max_det=self.args.max_det,
            end2end=self.end2end,
            rotated=self.args.task == 'obb',
        )
        return [
            {'bboxes': x[:, :4], 'conf': x[:, 4], 'cls': x[:, 5], 'extra': x[:, 6:]}
            for x in outputs
        ]
