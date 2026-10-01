# 里程碑：模型清单（把类别映射从代码里搬进模型）

**日期：** 2026-10-02
**目标：** 让「模型是用哪些类别 id 训的」这份信息**跟着模型走**，
而不是写死在 App 源码里；并让清单与模型不同步时**拒绝启动**而不是猜。
**结论：** 已完成。清单 `detector.json` 与模型一起打进 APK，
Dart 侧严格校验后才建映射，原生侧拿到 `classIds` 再解本地索引。
新增 13 条 Dart 测试 + 6 条 Python 测试守住这条不变量。

---

## 1. 为什么要做：一个不报错的错

TFLite 文件里**没有**「这个模型是用哪些 class-id 训的」这个元数据。
`model_class_map.dart` 里那份映射是一个常量：

```dart
const List<int> modelClassIds = <int>[6, 11, 7]; // pedestrian, bicycle, bin
```

本地开发这样没问题：训练和 App 在同一台机器上，改模型时顺手改常量。
但只要模型能从服务器下发，就出现了一个**沉默的失败**：

> 服务端换了一批类别训练新模型 → App 还是旧的常量 →
> **每个框的名字都是另一个类** → 不崩溃、不报错、不抛异常。

这和本项目此前踩过的六处解码缺陷是同一类问题：**不崩，只是安静地错**。
所以处置方式也一样——不是「小心一点」，而是**把不变量做成机器能检查的东西**。

---

## 2. 设计：清单是模型的同伴，不是模型的附注

```
app/assets/models/detector.tflite   2,871,365 B
app/assets/models/detector.json       434 B     ← 必须一起走
```

| 字段 | 作用 |
|---|---|
| `format` | 清单格式版本，必须 `== 1`；**不认识就报错，不忽略未知字段** |
| `version` / `trainedAt` | 版本比对，决定要不要下载 |
| `file` / `bytes` / `sha256` | 完整性：字节数 + 哈希，两处都对才认 |
| `inputSize` | 输入边长 |
| `modelClassCount` / `modelClassIds` | **核心**：本地索引 → 项目 id |
| `map50` | 训练/验证指标，供人看 |

**`modelClassIds` 的来源不是手写**，而是训练数据集的 `classes.json`
（那份文件的 `original_id` 就是真实 id）。手写就是又制造一个可以忘记改的地方。

### 空映射表只在一种条件下合法

`modelClassCount == kNumClasses`（48）时，本地索引就是项目 id，不需要映射。
其余情况给空表 → **直接失败**。这条规则的用意是：
**宁可起不来，也不要带着错误的映射跑起来。**

---

## 3. 拒绝启动，而不是降级

`platform_vision.dart` 的启动顺序改成了：

```
读清单 → 严格校验 → 失败则 return 状态(ok:false, message)
      → 成功则先用空映射加载模型，问出真实类别数
      → resolveMapping(declared: 清单里的 ids)
      → 若不是恒等映射，用 ids 重新加载
```

失败时界面显示 **`模型清单有问题`** 或 **`模型与清单不符`**，而不是继续跑。
两个错误信息刻意写得让人能直接去查文件，而不是显示一个错误码。

**为什么不用「猜一个」**：猜错的代价是每一帧的标签都错，
而用户是视障人士——他会照着错误的名字**做动作**。宁可让他知道现在不能用。

---

## 4. 删掉的东西

`model_class_map.dart` 里的 `const modelClassIds` **已删除**。
这一点很重要：如果留着它作为「默认值」，清单坏了就会静默回退到它，
于是这次改动等于没做。

对应的测试也一并重写：原来那条「当前声明表与类别表一致（换模型时必须同步改这里）」
测的是常量，现在映射的正确性由 `app/test/model_manifest_test.dart` 直接对
**内置清单文件**校验（读盘、比对内置模型的字节数）。

---

## 5. 顺带发现的一个真问题

`scripts/export_tflite.py` 的默认权重指向
`runs/pg_review_v0/weights/best.pt` —— 那是一个 **24 类**模型，
而类别表后来扩到 48 类、旧表已作废。

于是一条最普通的 `python scripts/export_tflite.py` 会导出一个
类别数与 `configs/classes.json` 对不上的模型，**而且不报错**。
已改为指向当前发布的 `runs/pg_poc3`（3 类），并加了一条测试：

```python
# tests/test_published_model.py
def test_默认导出源就是端上那一份():
    """DEFAULT_WEIGHTS 那次导出必须与打进 APK 的模型逐字节相同。"""
```

这条测试同时给出了一个**之前没有的能力**：
能自动发现「重训了、重导了，但忘了拷进 assets」这种漂移。

## 5.1 清单里不放数据集路径

第一版清单里带了 `"sourceDataset": "C:\\Users\\user\\..."`。
清单是要下发到手机上的资产，里面出现开发机绝对路径既没意义又泄露布局，
已移除；追溯信息改为导出时打到日志里（`映射来源数据集：dataset_poc3`）。

---

## 6. 验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | **0 问题** |
| `flutter test` | **77 全过**（原 64，新增 13 条清单测试） |
| `pytest` | **254 全过**（原 248，新增 6 条发布模型测试） |
| `check_kotlin_compiles.py` | 通过 |
| `check_tflite_decode.py` | 通过（布局 ↔ Kotlin ↔ 坐标换算三者一致） |
| APK | 构建成功（75.39 MB）；包内 `detector.json` 434 B + `detector.tflite` 2,871,365 B，**字节数与清单一致** |
| 逐类指标 | 重跑 val 落盘 `artifacts/metrics/pg_poc3_val.json`：总体 mAP50 **0.7445**（=清单里的 0.744），pedestrian 0.790(242)、bin 0.948(19)、bicycle 0.496(**仅 2** 实例，不可引用) |
| 真机复测 | ⏳ **未做**（手机未连接）。清单改动前的真机 HUD 是 `classes=3 / 映射 [6, 11, 7] / invalid=0` |

### 修过的三个自查错误（记下来，别重犯）

1. **测试里写了 `String.replace`** —— Dart 只有 `replaceAll` / `replaceFirst`。
2. **`rootBundle` 从 `widgets.dart` 导入** —— 它在 `services.dart` 里；
   改的时候把一个已有的 `services.dart` 导入搞成了重复导入，连带
   `MethodChannel` / `EventChannel` / `PlatformException` 全部"未定义"。
3. **fixture 里的 sha256 写成了 66 位** —— 正则要求 64 位，
   于是四条「合法清单」的测试全挂。数字类 fixture 必须用程序生成、不能手敲。

---

## 7. 遗留

- **下发通道未建**：清单格式已定，但「服务器 → 手机」的下载路径还没有，
  当前模型是随 APK 打包的。
- **真机复测待补**：手机连上后跑 `scripts/verify_on_device.ps1`，
  HUD 上应仍看到 `classes=3`、`映射 [6, 11, 7]`、`invalid=0`。
- 换模型的完整步骤见 `docs/MODELS.md` §5。
