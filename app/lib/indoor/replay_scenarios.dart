import 'indoor_graph.dart';

IndoorNode _node(
  String id,
  String zh,
  String en,
  List<List<String>> aliases, {
  String version = '1',
}) => IndoorNode(
  id: id,
  nameZh: zh,
  nameEn: en,
  contentVersion: version,
  objects: [
    for (var i = 0; i < aliases.length; i++)
      LandmarkObject(id: '$id-object-$i', aliases: aliases[i]),
  ],
);

// Entirely fictional, hand-annotated data. Layout is schematic, not surveyed XY.
final demoIndoorGraph = IndoorGraph(
  id: 'sample-building',
  version: 'demo-graph-1',
  floor: 'F1',
  nodes: [
    _node('N01', '樣例入口', 'Sample entrance', [
      ['入口牌', 'entrance sign'],
      ['藍色門', 'blue door'],
      ['入口地磚', 'entrance tiles'],
    ]),
    _node('N02', '方柱旁', 'Square pillar', [
      ['方柱', 'square pillar'],
      ['壁畫甲', 'mural A'],
    ]),
    _node('N03', '分岔路口', 'Junction', [
      ['分岔牌', 'junction sign'],
      ['圓柱', 'round pillar'],
    ]),
    _node('N04', '玻璃窗咖啡店', 'Window cafe', [
      ['咖啡店', 'cafe'],
      ['玻璃門', 'glass door'],
      ['長窗', 'long window'],
    ]),
    _node('N05', '轉角', 'Corner', [
      ['轉角牌', 'corner sign'],
      ['紅牆', 'red wall'],
    ]),
    _node('N06', '課室門前', 'Classroom door', [
      ['課室牌', 'classroom sign'],
      ['綠色門', 'green door'],
    ]),
    _node('N07', '樣例課室終點', 'Sample classroom destination', [
      ['終點牌', 'destination sign'],
      ['課室壁畫', 'classroom mural'],
    ]),
    _node('N08', '轉角咖啡店（已核准改名）', 'Corner cafe (approved rename)', [
      ['咖啡店', 'cafe', '舊角落咖啡', 'Old Corner Cafe', '新角落咖啡', 'New Corner Cafe'],
      ['玻璃門', 'glass door'],
      ['馬賽克牆', 'mosaic wall'],
    ], version: '2'),
    _node('N09', '升降機大堂', 'Lift lobby', [
      ['升降機牌', 'lift sign'],
      ['金屬柱', 'metal pillar'],
    ]),
    _node('N10', '洗手間路口', 'Toilet junction', [
      ['洗手間牌', 'toilet sign'],
      ['條紋牆', 'striped wall'],
    ]),
    _node('N11', '樓梯口', 'Stair landing', [
      ['樓梯牌', 'stairs sign'],
      ['三角窗', 'triangle window'],
    ]),
    _node('N12', '另一樣例入口', 'Other sample entrance', [
      ['另一入口牌', 'other entrance sign'],
      ['黃色門', 'yellow door'],
    ]),
  ],
  edges: const [
    IndoorEdge('N01', 'N02'),
    IndoorEdge('N02', 'N03'),
    IndoorEdge('N03', 'N04'),
    IndoorEdge('N04', 'N05'),
    IndoorEdge('N05', 'N06'),
    IndoorEdge('N06', 'N07'),
    IndoorEdge('N03', 'N08'),
    IndoorEdge('N08', 'N09'),
    IndoorEdge('N09', 'N10'),
    IndoorEdge('N05', 'N11'),
    IndoorEdge('N11', 'N12'),
    IndoorEdge('N04', 'N08', open: false),
  ],
);

const demoGraphLayout = <String, (double, double)>{
  'N01': (.08, .78),
  'N02': (.23, .78),
  'N03': (.39, .78),
  'N04': (.55, .78),
  'N05': (.72, .78),
  'N06': (.87, .78),
  'N07': (.87, .52),
  'N08': (.39, .52),
  'N09': (.23, .30),
  'N10': (.08, .30),
  'N11': (.72, .52),
  'N12': (.72, .22),
};

class ReplayEvent {
  const ReplayEvent(this.observation, this.receivedAt);
  final LandmarkObservation observation;
  final DateTime receivedAt;
}

class ReplayScenario {
  const ReplayScenario({
    required this.id,
    required this.titleZh,
    required this.titleEn,
    required this.descriptionZh,
    required this.descriptionEn,
    required this.events,
    this.destination = 'N07',
  });
  final String id, titleZh, titleEn, descriptionZh, descriptionEn, destination;
  final List<ReplayEvent> events;
}

final _baseTime = DateTime.utc(2026, 1, 1);
List<String> sampleEvidence(String node) => switch (node) {
  'N01' => ['入口牌', '藍色門'],
  'N02' => ['方柱', '壁畫甲'],
  'N03' => ['分岔牌', '圓柱'],
  'N04' => ['咖啡店', '玻璃門', '長窗'],
  'N05' => ['轉角牌', '紅牆'],
  'N06' => ['課室牌', '綠色門'],
  'N07' => ['終點牌', '課室壁畫'],
  'N08' => ['咖啡店', '玻璃門', '馬賽克牆'],
  'N09' => ['升降機牌', '金屬柱'],
  'N10' => ['洗手間牌', '條紋牆'],
  'N11' => ['樓梯牌', '三角窗'],
  'N12' => ['另一入口牌', '黃色門'],
  _ => [],
};
ReplayEvent sampleEvent(
  String session,
  int sequence,
  List<String> evidence, {
  String floor = 'F1',
  int? captureSeconds,
  int? receiveSeconds,
}) {
  final capture = captureSeconds ?? sequence * 5;
  return ReplayEvent(
    LandmarkObservation(
      sessionId: session,
      sequence: sequence,
      graphId: demoIndoorGraph.id,
      mapVersion: demoIndoorGraph.version,
      floor: floor,
      capturedAt: _baseTime.add(Duration(seconds: capture)),
      landmarks: evidence,
    ),
    _baseTime.add(Duration(seconds: receiveSeconds ?? capture)),
  );
}

ReplayScenario _sequence(
  String id,
  String zh,
  String en,
  String descriptionZh,
  String descriptionEn,
  List<String> nodes,
) => ReplayScenario(
  id: id,
  titleZh: zh,
  titleEn: en,
  descriptionZh: descriptionZh,
  descriptionEn: descriptionEn,
  events: [
    for (var i = 0; i < nodes.length; i++)
      sampleEvent(id, i + 1, sampleEvidence(nodes[i])),
  ],
);

final replayScenarios = <ReplayScenario>[
  _sequence(
    'forward',
    '順行',
    'Forward walk',
    '沿手動連線依序對照；只顯示節點路線，不發轉向指令。',
    'Follow annotated connections. Shows graph nodes without turn instructions.',
    ['N01', 'N02', 'N03', 'N04', 'N05', 'N06', 'N07'],
  ),
  _sequence(
    'dwell',
    '同一位置停留',
    'Stay at one place',
    '多筆觀察可以對應同一node，不會新增永久節點。',
    'Repeated observations can refer to the same node without creating places.',
    ['N03', 'N04', 'N04', 'N04', 'N05'],
  ),
  _sequence(
    'skip',
    '行快／漏拍',
    'Skipped observations',
    '容許跳過中間節點，連通性由graph檢查。',
    'Skipped intermediate observations use graph connectivity.',
    ['N01', 'N03', 'N05', 'N07'],
  ),
  _sequence(
    'reverse',
    '倒行／折返',
    'Reverse walk',
    '已核准雙向連線可反向對照。',
    'Approved bidirectional edges can be followed backwards.',
    ['N07', 'N06', 'N05', 'N04', 'N03', 'N02', 'N01'],
  ),
  _sequence(
    'fork',
    '改行分岔',
    'Take a branch',
    '離開原先預期路線時，對照其他可達node，唔硬拉回原路。',
    'Match a reachable branch without forcing the expected next node.',
    ['N01', 'N02', 'N03', 'N08', 'N09', 'N10'],
  ),
  ReplayScenario(
    id: 'ambiguous',
    titleZh: '重複店面／不確定',
    titleEn: 'Similar storefronts',
    descriptionZh: '兩間店共有咖啡店與玻璃門；未見獨有路標時拒絕選位置。',
    descriptionEn: 'Both cafes share a shop sign and glass door. Distinct evidence is required.',
    events: [
      sampleEvent('ambiguous', 1, sampleEvidence('N03')),
      sampleEvent('ambiguous', 2, ['咖啡店', '玻璃門']),
      sampleEvent('ambiguous', 3, sampleEvidence('N08')),
    ],
  ),
  ReplayScenario(
    id: 'rename',
    titleZh: '已核准別名／未核准改名',
    titleEn: 'Approved and unknown names',
    descriptionZh: '已核准新舊店名指向同一N08；未知招牌不會自行改寫內容。',
    descriptionEn:
        'Approved names share N08. An unknown sign never edits the map.',
    events: [
      sampleEvent('rename', 1, ['舊角落咖啡', '馬賽克牆']),
      sampleEvent('rename', 2, ['新角落咖啡', '馬賽克牆']),
      sampleEvent('rename', 3, ['未核准新招牌', '馬賽克牆']),
    ],
  ),
  ReplayScenario(
    id: 'unknown',
    titleZh: '未知／錯樓層',
    titleEn: 'Unknown and wrong floor',
    descriptionZh: '認唔到或樓層不符就撤回目前位置，不把無框當安全。',
    descriptionEn:
        'Unknown evidence or a wrong floor withdraws the current position.',
    events: [
      sampleEvent('unknown', 1, sampleEvidence('N05')),
      sampleEvent('unknown', 2, ['行人', '流動攤位']),
      sampleEvent('unknown', 3, sampleEvidence('N06'), floor: 'F2'),
    ],
  ),
  ReplayScenario(
    id: 'late',
    titleZh: '遲到回覆／過期',
    titleEn: 'Late and expired responses',
    descriptionZh: '按拍攝序號保存觀察，遲到回覆不覆蓋較新位置；過期資料撤回。',
    descriptionEn: 'Keep observations ordered; late responses cannot replace a newer position.',
    events: [
      sampleEvent('late', 1, sampleEvidence('N01')),
      sampleEvent('late', 3, sampleEvidence('N03'), receiveSeconds: 16),
      sampleEvent('late', 2, sampleEvidence('N02'), receiveSeconds: 17),
      sampleEvent('late', 4, sampleEvidence('N04'), receiveSeconds: 50),
    ],
  ),
  _sequence(
    'relocalize',
    '遠處重新對照',
    'Confirm a distant match',
    '超出五條邊的候選需連續兩筆新觀察，先保留未確認。',
    'A candidate beyond five edges requires two successive fresh observations.',
    ['N01', 'N12', 'N12', 'N11', 'N05'],
  ),
];
