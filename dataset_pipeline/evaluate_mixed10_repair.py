from pathlib import Path
from collections import Counter
import hashlib,json,time,os
import cv2,numpy as np,torch
from ultralytics import YOLO
from ultralytics.utils.metrics import ap_per_class

out=Path(os.environ['PATHGUIDE_JOB_WORKSPACE'])
NAMES=['person','bicycle','bin','bollard','traffic_cone','caution_slippery','stairs','escalator','fence','door']
records=json.loads((out/'source-index.json').read_text());patches=json.loads((out/'absence-review.json').read_text())
validation=[r for r in records if r['split']=='val']
diagnostic=[{**r,'coverage':sorted(set(r['coverage']+patches[r['id']]['add_absent_classes']))} for r in records if r['id'] in patches]
assert len(validation)==1403 and len(diagnostic)==18

def overlap(a,b):
 a=np.asarray(a,np.float32).reshape(-1,4);b=np.asarray(b,np.float32).reshape(-1,4)
 size=np.maximum(0,np.minimum(a[:,None,2:],b[None,:,2:])-np.maximum(a[:,None,:2],b[None,:,:2]))
 inter=size.prod(2);areaA=np.maximum(0,a[:,2:]-a[:,:2]).prod(1);areaB=np.maximum(0,b[:,2:]-b[:,:2]).prod(1)
 return inter/np.maximum(1e-12,areaA[:,None]+areaB[None,:]-inter)

def prepare(r):
 raw=cv2.imread(r['path']);assert raw is not None,r['id']
 rgb=cv2.cvtColor(raw,cv2.COLOR_BGR2RGB).astype(np.float32)/255
 h,w=rgb.shape[:2];scale=min(640/w,640/h);sw,sh=round(w*scale),round(h*scale);px,py=(640-sw)//2,(640-sh)//2
 frame=np.full((640,640,3),114/255,np.float32)
 frame[py:py+sh,px:px+sw]=cv2.resize(rgb,(sw,sh),interpolation=cv2.INTER_LINEAR)
 return frame.transpose(2,0,1),(sw,sh,px,py)

def decode(values,geo):
 sw,sh,px,py=geo;cls=values[4:].argmax(0);scores=values[4:].max(0)
 mask=(scores>=np.float32(.001))&(values[2]>0)&(values[3]>0)
 xywh=values[:4,mask].T;cls=cls[mask];scores=scores[mask]
 corners=np.concatenate([xywh[:,:2]-xywh[:,2:]/2,xywh[:,:2]+xywh[:,2:]/2],1)
 boxes=np.clip((corners-np.array([px,py,px,py],np.float32))/np.array([sw,sh,sw,sh],np.float32),0,1)
 good=np.all(boxes[:,2:]>boxes[:,:2],1);boxes=boxes[good];cls=cls[good];scores=scores[good]
 order=np.argsort(-scores,kind='stable');kept=[]
 while len(order) and len(kept)<100:
  first=order[0];kept.append(first);rest=order[1:]
  suppress=(cls[rest]==cls[first])&(overlap(boxes[first:first+1],boxes[rest])[0]>.45)
  order=rest[~suppress]
 return boxes[kept],scores[kept],cls[kept]

def blank():return {n:{'tp':0,'fp':0,'fn':0,'ground_truth':0} for n in NAMES}
def counts(pred,r,target):
 boxes,scores,classes=pred;gt=r['boxes'];used=set()
 for b in gt:target[NAMES[b['class_id']]]['ground_truth']+=1
 for box,score,cls in zip(boxes,scores,classes):
  if int(cls) not in r['coverage']:continue
  possible=[(float(overlap([box],[g['xyxy']])[0,0]),j) for j,g in enumerate(gt) if j not in used and g['class_id']==int(cls)]
  if possible and max(possible)[0]>=.5:target[NAMES[int(cls)]]['tp']+=1;used.add(max(possible)[1])
  else:target[NAMES[int(cls)]]['fp']+=1
 for j,b in enumerate(gt):
  if j not in used:target[NAMES[b['class_id']]]['fn']+=1

def ap_stats(pred,r):
 boxes,scores,classes=pred;known=np.isin(classes,r['coverage']);boxes=boxes[known];scores=scores[known];classes=classes[known]
 gt=np.array([b['xyxy'] for b in r['boxes']],np.float32).reshape(-1,4);gc=np.array([b['class_id'] for b in r['boxes']],np.int64)
 matrix=overlap(gt,boxes)*(gc[:,None]==classes[None,:]);correct=np.zeros((len(classes),10),bool)
 for i,threshold in enumerate(np.linspace(.5,.95,10)):
  matches=np.array(np.nonzero(matrix>=threshold)).T
  if len(matches):
   if len(matches)>1:
    matches=matches[np.argsort(-matrix[matches[:,0],matches[:,1]])]
    matches=matches[np.unique(matches[:,1],return_index=True)[1]]
    matches=matches[np.unique(matches[:,0],return_index=True)[1]]
   correct[matches[:,1],i]=True
 return correct,scores,classes,gc

def evaluate(arm,path):
 print('EVALUATING',arm,flush=True);started=time.monotonic()
 model=YOLO(str(path)).model.float().eval();model.fuse();model.to('cuda')
 metrics={dataset:{str(c):blank() for c in [.3,.7]} for dataset in ['validation','training_diagnostic','fresh_validation','original_validation']}
 stats=[];old_stats=[];false_frames={str(c):Counter() for c in [.3,.7]};examples=[]
 fresh_absent_frames={str(c):Counter() for c in [.3,.7]}
 fresh_absent_denominators=Counter()
 for r in validation:
  if r['id'].startswith('fresh-'):
   for cls in [0,8]:
    if cls in r['coverage'] and not any(b['class_id']==cls for b in r['boxes']):fresh_absent_denominators[NAMES[cls]]+=1
 for dataset,rows in [('validation',validation),('training_diagnostic',diagnostic)]:
  with torch.inference_mode():
   for start in range(0,len(rows),8):
    batch=rows[start:start+8];prepared=[prepare(r) for r in batch]
    tensor=torch.from_numpy(np.stack([p[0] for p in prepared])).to('cuda')
    prediction=model(tensor);prediction=(prediction[0] if isinstance(prediction,(tuple,list)) else prediction).float().cpu().numpy()
    assert np.isfinite(prediction).all()
    for r,raw,(_,geo) in zip(batch,prediction,prepared):
     pred=decode(raw,geo)
     if dataset=='validation':
      sample_stats=ap_stats(pred,r);stats.append(sample_stats)
      if not r['id'].startswith('fresh-'):old_stats.append(sample_stats)
     for conf in [.3,.7]:
      mask=pred[1]>=np.float32(conf);selected=(pred[0][mask],pred[1][mask],pred[2][mask]);counts(selected,r,metrics[dataset][str(conf)])
      if dataset=='validation':counts(selected,r,metrics['fresh_validation' if r['id'].startswith('fresh-') else 'original_validation'][str(conf)])
      if dataset=='validation' and r['id'].startswith('fresh-'):
       for cls in [0,8]:
        if cls in r['coverage'] and not any(b['class_id']==cls for b in r['boxes']) and np.any(selected[2]==cls):fresh_absent_frames[str(conf)][NAMES[cls]]+=1
      if dataset=='training_diagnostic':
       for cls in patches[r['id']]['add_absent_classes']:
        if np.any(selected[2]==cls):false_frames[str(conf)][NAMES[cls]]+=1
     if r['id']=='oid-96b573942e14da60':examples.append({'id':r['id'],'max_person':float(raw[4].max()),'max_fence':float(raw[12].max()),'max_door':float(raw[13].max())})
    if start%256==0:print(arm,dataset,min(start+8,len(rows)),'/',len(rows),flush=True)
 for dataset in metrics.values():
  for table in dataset.values():
   for value in table.values():
    value['precision']=value['tp']/(value['tp']+value['fp']) if value['tp']+value['fp'] else None
    value['recall']=value['tp']/value['ground_truth'] if value['ground_truth'] else None
 def make_ap(samples):
  tp,conf,predcls,targetcls=(np.concatenate([s[k] for s in samples],0) for k in range(4))
  values=ap_per_class(tp,conf,predcls,targetcls,plot=False,names=dict(enumerate(NAMES)))
  return {NAMES[int(c)]:{'AP50':float(values[5][i,0]),'AP50_95':float(values[5][i].mean())} for i,c in enumerate(values[6])}
 ap=make_ap(stats);old_ap=make_ap(old_stats)
 result={'arm':arm,'checkpoint_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'metrics':metrics,
  'validation_ap':ap,'original_validation_ap':old_ap,'validation_gt_classes':len(ap),'diagnostic_false_positive_frames':{k:dict(v) for k,v in false_frames.items()},
  'fresh_known_absent_frames':dict(fresh_absent_denominators),'fresh_false_positive_frames':{k:dict(v) for k,v in fresh_absent_frames.items()},
  'public_bed_example':examples,'wall_seconds':time.monotonic()-started}
 (out/f'evaluation-{arm}.json').write_text(json.dumps(result,indent=2)+'\n')
 print('EVALUATION_COMPLETE',arm,'door@.7',metrics['validation']['0.7']['door'],'diagnosticFPframes',result['diagnostic_false_positive_frames'],flush=True)
 del model;torch.cuda.empty_cache()
 return result

if __name__=='__main__':
 assert torch.cuda.is_available()
 arms={'baseline':Path(os.environ['PATHGUIDE_SOURCE_PT'])}
 for arm in ['repair']:
  saved=json.loads((out/f'{arm}-result.json').read_text());path=Path(saved['checkpoint'])
  assert hashlib.sha256(path.read_bytes()).hexdigest()==saved['checkpoint_sha256'];arms[arm]=path
 results={arm:evaluate(arm,path) for arm,path in arms.items()}
 report={'settings':{'input':'independent float RGB half-pixel/rounded 640 letterbox; not NV12 capture','argmax_before_coverage_filter':True,
  'native_equivalent_box_clipping_before_nms':True,'nms_iou':.45,'maximum':100,'ap_min_confidence':.001,'fixed_confidences':[.3,.7],
  'AP_matching':'IoU-descending unique detection then unique GT; fixed-threshold matching is confidence-descending'},
  'validation_images':1403,'training_diagnostic_images':18,'training_diagnostic_person_absences':18,'training_diagnostic_fence_absences':11,
  'results':results,'old_class_AP50_drops_vs_baseline':{arm:{n:results['baseline']['original_validation_ap'][n]['AP50']-results[arm]['original_validation_ap'][n]['AP50'] for n in NAMES[:8]} for arm in ['repair']},
  'limits':['Single-seed exploratory CUDA experiment; no bitwise reproducibility or generalization claim','Diagnostics use previously trained same-facility photos, not independent generalization','No independent fence-positive validation, source legacy validation exposure already exists','Absence reviews are by assistant, not independent human adjudication','Original source test split was not inferred','No automatic deployment or quality-pass claim'],
  'quality_gate_passed':False,'deployment_performed':False}
 (out/'controlled-report.json').write_text(json.dumps(report,indent=2)+'\n')
 print('REPORT',out/'controlled-report.json',flush=True)
