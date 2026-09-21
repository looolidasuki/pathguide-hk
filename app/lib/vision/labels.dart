// 本文件由 scripts/gen_dart_labels.py 从 configs/classes.json 生成，请勿手工编辑。
// 手工改动会在下次生成时被覆盖；要改类别请改 configs/classes.json。

/// 一个检测类别。`id` 必须与 YOLO 标签索引一致。
class Label {
  const Label({
    required this.id,
    required this.nameEn,
    required this.nameZh,
    required this.group,
    required this.priority,
    required this.announced,
  });

  final int id;
  final String nameEn;
  final String nameZh;
  final String group;

  /// P0 表示可能危险，播报可插队；P1 排队播。
  final String priority;

  /// false 表示这是训练期占位类（如 ambiguous_vertical），不进播报。
  final bool announced;

  @override
  String toString() => 'Label($id, $nameEn, $nameZh)';
}

/// 全部类别，按 id 升序。
const List<Label> kLabels = <Label>[
  Label(
    id: 0,
    nameEn: 'footbridge_entrance',
    nameZh: '天橋入口',
    group: 'footbridge',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 1,
    nameEn: 'stairs',
    nameZh: '樓梯',
    group: 'footbridge',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 2,
    nameEn: 'escalator_outdoor',
    nameZh: '戶外扶梯',
    group: 'footbridge',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 3,
    nameEn: 'elevator',
    nameZh: '升降機',
    group: 'footbridge',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 4,
    nameEn: 'ramp',
    nameZh: '斜道',
    group: 'footbridge',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 5,
    nameEn: 'footbridge_railing',
    nameZh: '天橋欄杆',
    group: 'footbridge',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 6,
    nameEn: 'pedestrian',
    nameZh: '行人',
    group: 'obstacle',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 7,
    nameEn: 'bin',
    nameZh: '垃圾桶',
    group: 'obstacle',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 8,
    nameEn: 'bollard',
    nameZh: '護柱',
    group: 'obstacle',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 9,
    nameEn: 'traffic_cone',
    nameZh: '交通錐',
    group: 'obstacle',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 10,
    nameEn: 'barrier_water',
    nameZh: '水馬',
    group: 'obstacle',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 11,
    nameEn: 'bicycle',
    nameZh: '單車',
    group: 'obstacle',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 12,
    nameEn: 'scooter',
    nameZh: '滑板車',
    group: 'obstacle',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 13,
    nameEn: 'cart_trolley',
    nameZh: '手推車',
    group: 'obstacle',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 14,
    nameEn: 'step',
    nameZh: '台階',
    group: 'obstacle',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 15,
    nameEn: 'tactile_paving',
    nameZh: '盲道',
    group: 'guide',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 16,
    nameEn: 'zebra_crossing',
    nameZh: '斑馬線',
    group: 'guide',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 17,
    nameEn: 'glass_door',
    nameZh: '玻璃門',
    group: 'indoor',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 18,
    nameEn: 'door',
    nameZh: '推拉門',
    group: 'indoor',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 19,
    nameEn: 'escalator_indoor',
    nameZh: '商場扶梯',
    group: 'indoor',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 20,
    nameEn: 'sign_pictogram',
    nameZh: '指示牌',
    group: 'indoor',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 21,
    nameEn: 'glass_door_indoor',
    nameZh: '商場玻璃門',
    group: 'indoor',
    priority: 'P0',
    announced: true,
  ),
  Label(
    id: 22,
    nameEn: 'shop_front',
    nameZh: '店鋪門面',
    group: 'classifier',
    priority: 'P1',
    announced: true,
  ),
  Label(
    id: 23,
    nameEn: 'ambiguous_vertical',
    nameZh: '垂直設施不明',
    group: 'train_only',
    priority: 'P0',
    announced: false,
  ),
];

/// 模型输出维度。推理结果长度与之不符即为模型与类别表不匹配。
const int kNumClasses = 24;

/// 播报优先级顺序（先 announced，再 P0 → P1，再 id）。
const List<int> kAnnouncementOrder = <int>[
  0, 1, 2, 3, 4, 6, 7, 8, 9, 11, 14, 17, 19, 21, 5, 10, 12, 13, 15, 16, 18, 20, 22, 23,
];

/// 按 id 取类别。id 越界时返回 null —— 不要静默回退到 0，那会掩盖模型/类别表不匹配。
Label? labelOf(int id) => (id >= 0 && id < kLabels.length) ? kLabels[id] : null;
