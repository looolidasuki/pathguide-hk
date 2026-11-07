"""Source-aware loss/metrics for partially annotated detection datasets.

Requires Ultralytics 8.4.182. A manifest must explicitly declare which classes
are annotated in every image. Unknown classes receive no negative BCE gradient.
Cross-image augmentations are prohibited because their coverage would differ.
"""
import json
from pathlib import Path
import torch
from torch import nn
from ultralytics.utils.loss import v8DetectionLoss
from ultralytics.models.yolo.detect import DetectionTrainer, DetectionValidator


def load_coverage(path, nc=10):
    rows=json.loads(Path(path).read_text())
    result={}
    for name, classes in rows.items():
        if Path(name).name!=name or not classes or len(set(classes))!=len(classes):
            raise ValueError('Invalid coverage manifest key/classes: '+name)
        if any(type(c) is not int or not 0<=c<nc for c in classes):
            raise ValueError('Invalid coverage class: '+name)
        result[name]=tuple(sorted(classes))
    return result


def coverage_mask(files, manifest, nc, device):
    mask=torch.zeros((len(files),1,nc),device=device)
    for i,file in enumerate(files):
        name=Path(file).name
        if name not in manifest: raise ValueError('Missing coverage: '+name)
        mask[i,0,list(manifest[name])]=1
    return mask


class CoverageBCE(nn.Module):
    def __init__(self):
        super().__init__();self.base=nn.BCEWithLogitsLoss(reduction='none');self.mask=None

    def forward(self,logits,targets):
        if self.mask is None or self.mask.shape!=(logits.shape[0],1,logits.shape[-1]):
            raise ValueError('Coverage mask shape does not match prediction batch')
        if ((targets>0)&(self.mask==0)).any():
            raise ValueError('Positive target assigned to an unknown class')
        return self.base(logits,targets)*self.mask.to(dtype=logits.dtype)


class CoverageLoss(v8DetectionLoss):
    def __init__(self,model,manifest):
        super().__init__(model);self.manifest=manifest;self.bce=CoverageBCE()

    def __call__(self,preds,batch):
        self.bce.mask=coverage_mask(batch['im_file'],self.manifest,self.nc,self.device)
        # Reject inconsistent positive labels before target assignment as well.
        if len(batch['cls']):
            bi=batch['batch_idx'].reshape(-1).long();cls=batch['cls'].reshape(-1).long()
            if not self.bce.mask[bi,0,cls].all():
                raise ValueError('Source label is outside declared coverage')
        return super().__call__(preds,batch)


class CoverageValidator(DetectionValidator):
    def __init__(self,*args,coverage=None,**kwargs):
        self.coverage=coverage
        super().__init__(*args,**kwargs)

    def update_metrics(self,preds,batch):
        masks=coverage_mask(batch['im_file'],self.coverage,self.nc,self.device)
        filtered=[]
        for i,pred in enumerate(preds):
            keep=masks[i,0,pred['cls'].long()].bool()
            filtered.append({k:v[keep] if isinstance(v,torch.Tensor) and v.ndim and len(v)==len(keep) else v for k,v in pred.items()})
        return super().update_metrics(filtered,batch)


class CoverageTrainer(DetectionTrainer):
    """Attach training-only criterion after EMA construction; save plain models."""
    coverage_manifest=None
    coverage_class_count=10

    def __init__(self,*args,**kwargs):
        if self.coverage_manifest is None: raise ValueError('Set coverage_manifest first')
        self.coverage=load_coverage(self.coverage_manifest,nc=self.coverage_class_count)
        super().__init__(*args,**kwargs)
        for name in ['mosaic','mixup','cutmix','copy_paste']:
            if getattr(self.args,name,0): raise ValueError('Mixed-source augmentation prohibited: '+name)
        if self.args.multi_scale: raise ValueError('Use fixed 640 input for initial candidate')

    def preprocess_batch(self,batch):
        batch=super().preprocess_batch(batch)
        if not isinstance(getattr(self.model,'criterion',None),CoverageLoss):
            self.model.criterion=CoverageLoss(self.model,self.coverage)
        return batch

    def get_validator(self):
        import copy
        self.loss_names='box_loss','cls_loss','dfl_loss'
        return CoverageValidator(self.test_loader,save_dir=self.save_dir,
          args=copy.copy(self.args),_callbacks=self.callbacks,coverage=self.coverage)

    def save_model(self):
        # Defensive: custom Python classes must never enter deployment checkpoints.
        ema=self.ema.ema
        criterion=getattr(ema,'criterion',None)
        if criterion is not None:delattr(ema,'criterion')
        try:return super().save_model()
        finally:
            if criterion is not None:ema.criterion=criterion
