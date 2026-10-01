# 外部数据现状与一个把采集脚本弄坏的 BOM

**日期：** 2026-10-02
**起因：** 要补 `bicycle`（13 帧/15 框）与 `scooter`（唯一零检出类）的数据，
先查 Roboflow 能不能下，结果查出两件更要紧的事。
**结论：**
1. Roboflow 的 key 已被吊销（HTTP 401），**不能下载**，需要换 key 或手工下 zip。
2. `data/raw/external/` 里**已经有 901 张外部图**（16 个类，含 bicycle 60 张、
   scooter 60 张），但**从未被任何数据集使用过**。
3. `configs/commons_sources.json` 带 UTF-8 BOM，导致采集脚本
   `fetch_commons_by_class.py` **直接跑不起来**——已修，并加了测试。

---

## 1. Roboflow：确认吊销，不是网络问题

```
读到 key：21 字符，以 KJsR… 开头
鉴权结果：失败 HTTP 401
  响应: {"error":{"message":"This API key does not exist (or has been revoked).",
         "status":401,"type":"OAuthException"}}
```

`api_key="unauthorized"` 是**占位符**，不是真 key。三条出路（都需要你操作）：
换一把有效 key 填进 `.env.secret.ps1`；把 dataset 设为可协作访问；
或手工下载 zip 丢进 `data/raw/` 再跑 `scripts/import_roboflow.py --zip <文件>`。

---

## 2. 已经有 901 张外部图，而且没用过

```
data/raw/external/
  banner 57   bench 60   bicycle 60   cardboard 59   cart_trolley 60
  chair 57    fire_hydrant 26   goods_on_street 45   scaffold 59
  scooter 60  sign_pictogram 60  step 68  table 55
  traffic_cone 60  tree 59  zebra_crossing 56
  attribution.jsonl（889 条）  fetch_summary.json
```

来源是 **Wikimedia Commons**（字段：`title` / `thumburl` / `artist` / `license` /
`class_or_target` / `tier`），许可证以 CC BY-SA 4.0（499）、CC BY-SA 3.0（132）、
CC0（76）为主。

**关键事实：没有任何数据集的 `manifest.csv` 提到 `external`**——
即这 901 张图抓下来之后**一直躺着**，没有进过任何一次训练。

`fetch_summary.json` 还停留在只记 3 个类（bicycle / bench / traffic_cone），
说明后续又抓了 13 个类但没更新它——**这份 summary 不可作为现状依据**。

### 但是：它们不能直接当训练标签用

这些是**整图单物件**照片（一张图一个物体，Commons 上给该物件拍的照片），
**没有框**。所以：

- ❌ 不能直接丢进检测训练集；
- ⚠️ 也不能「整图当一个框」——街景里一图多物，那样训出来的框是错的；
- ✅ 正确用法是喂给**老师预标链**（GDINO 出框 → SAM 精修 → VLM 验证 → 抽样质检），
  这正是 `scripts/pipeline/` 那三段，而它**目前接的还是 YOLO-World**（9 类零召回）。

### 还有一个域偏移问题，必须写清楚

采集脚本自己就写了「香港分类优先」，理由是全球图街道风格偏移。
实测这次探针也印证了：

```
bicycle   3 张（香港 3 / 全球 0）
scooter   3 张（香港 0 / 全球 3）   ← scooter 在香港 Commons 里几乎没有
```

所以 Commons 数据能**让一个类存在**，但**不能保证它在香港街景里可用**。
必须与实拍街景帧混着训，并且**分开评测**，否则会得到一个
「在 Commons 上很好、在调景岭不好」的模型。

---

## 3. 那个 BOM：一个配置文件被另存一次，采集脚本就全废

`configs/commons_sources.json` 开头有 `EF BB BF`（UTF-8 BOM），
而 `fetch_commons_by_class.py` 用 `encoding="utf-8"` 读它：

```
json.decoder.JSONDecodeError: Unexpected UTF-8 BOM (decode using utf-8-sig):
line 1 column 1 (char 0)
```

**为什么值得单独记一笔**：这个报错
① 不提 BOM，② 不提是编码问题，③ 不提是哪个文件被谁怎么改的。
看的人第一反应是「JSON 内容写坏了」，于是会去翻内容——而内容根本没问题。
实际原因只是某次编辑/`Set-Content -Encoding utf8` 顺手加了 BOM。

**取证：全仓库扫描带 BOM 的文件，8 个**：

| 文件 | 有害？ |
|---|---|
| `configs/commons_sources.json` | ⚠️ **有害**：被 `json.load` 按 utf-8 读 |
| 其余 7 个（`.py` 源码） | 无害：Python 3 容忍源码 BOM，且实测 259 条测试全过 |

所以问题**只在「数据文件 + 严格解码器」这个组合**上，不是「BOM 一律有害」。

### 修法：治本 + 兜底，两个都要

- **治本**：把文件重新存成 UTF-8 无 BOM（并先 `json.loads` 验证内容合法再写回，
  避免把坏文件洗成另一个坏文件）。
- **兜底**：读取方改成 `encoding="utf-8-sig"`——它对「有 BOM」和「没 BOM」
  都能读，是纯收益。因为 Windows 上 BOM 会**再被加回来**
  （记事本、PowerShell `Set-Content -Encoding utf8` 都默认加）。

新增 `tests/test_config_encoding.py`：
① `configs/**/*.json` 一律不得带 BOM 且必须能按普通 utf-8 解析（参数化，逐文件）；
② 采集脚本必须继续用 `utf-8-sig` 读那份配置。
这样「配置文件被另存过一次」会**当场测试失败**，而不是过几天
「采集脚本神秘跑不动」。

验证：修复后实跑探针，链路通了——

```
bicycle  3 张（香港 3 / 全球 0）
scooter  3 张（香港 0 / 全球 3）
```

---

## 4. 顺带确认的另一件事

`data/raw/external` 的存在说明**Commons 这条取数通道是可用的、不需要任何凭据**。
在拿到有效 Roboflow key 之前，这是唯一能立刻推进的补数据途径
（配合 `--only <类名> --per-class <n>` 定向扩量）。
