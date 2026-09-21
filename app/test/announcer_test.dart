import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/labels.dart';

/// 播报调度：两级冷却 + 优先级插队。
///
/// 这块逻辑在真机上极难验证——你不可能一边举着手机一边数「刚才那句话
/// 该不该说」。所以把时钟做成可注入的，用测试把取舍全钉死。
class _FakeSpeaker implements Speaker {
  final List<String> spoken = <String>[];
  int stops = 0;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<List<String>> languages() async => const <String>['yue-HK'];
}

/// 可手动推进的时钟。
class _Clock {
  DateTime now = DateTime(2026, 9, 22, 10, 0, 0);
  void advance(Duration d) => now = now.add(d);
  DateTime call() => now;
}

Detection _det(int id, {double score = 0.9}) => Detection(
      id: id,
      score: score,
      cx: 0.5,
      cy: 0.5,
      w: 0.2,
      h: 0.2,
    );

/// `bin` = id 7，P0（见 configs/classes.json）。测试用它作锚点。
final int _binId = kLabels.firstWhere((l) => l.nameEn == 'bin').id;
final int _binP0Id =
    kLabels.firstWhere((l) => l.priority == 'P0' && l.announced).id;

/// 一个**可播报**且与锚点类不同的 id，用来验证全局冷却。
final int _otherAnnouncedId = kLabels
    .firstWhere((l) => l.announced && l.id != _binP0Id)
    .id;

void main() {
  late _FakeSpeaker speaker;
  late _Clock clock;
  late Announcer announcer;

  setUp(() {
    speaker = _FakeSpeaker();
    clock = _Clock();
    announcer = Announcer(speaker: speaker, clock: clock.call);
  });

  test('首帧即播报', () {
    final a = announcer.onFrame(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(1));
  });

  test('同一类在冷却期内不重复播报', () {
    announcer.onFrame(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 1));
    final a = announcer.onFrame(<Detection>[_det(_binP0Id)]);
    expect(a, isNull);
    expect(speaker.spoken, hasLength(1), reason: '1 秒 < 2 秒同类冷却');
  });

  test('同类冷却过后可以再播', () {
    announcer.onFrame(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 6)); // 同时越过全局冷却
    final a = announcer.onFrame(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(2));
  });

  test('全局冷却会压掉不同类的播报', () {
    announcer.onFrame(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 3)); // 越过同类冷却，未越全局冷却
    final a = announcer.onFrame(<Detection>[_det(_otherAnnouncedId)]);
    expect(a, isNull, reason: '3 秒 < 5 秒全局冷却');
    expect(speaker.spoken, hasLength(1));
  });

  test('force 可以绕过冷却', () {
    announcer.onFrame(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(milliseconds: 100));
    final a = announcer.onFrame(<Detection>[_det(_binP0Id)], force: true);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(2));
  });

  test('空帧不播报', () {
    expect(announcer.onFrame(const <Detection>[]), isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('不可播报的类别被忽略（ambiguous_vertical 是训练期占位类）', () {
    final id = kLabels.firstWhere((l) => !l.announced).id;
    final a = announcer.onFrame(<Detection>[_det(id)]);
    expect(a, isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('未知类别 id 不会崩，也不会播报', () {
    final a = announcer.onFrame(<Detection>[_det(999)]);
    expect(a, isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('同类多个候选只播一次', () {
    announcer.onFrame(<Detection>[
      _det(_binP0Id, score: 0.6),
      _det(_binP0Id, score: 0.95),
      _det(_binP0Id, score: 0.8),
    ]);
    expect(speaker.spoken, hasLength(1));
  });

  test('记下跳过原因，便于现场解释', () {
    announcer.onFrame(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 1));
    announcer.onFrame(<Detection>[_det(_binP0Id)]);
    expect(announcer.history, hasLength(2));
    expect(announcer.history.last.reason, contains('跳过'));
  });

  test('reset 清空冷却，新场景第一个目标不会被旧冷却压掉', () {
    announcer.onFrame(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(milliseconds: 100));
    announcer.reset();
    final a = announcer.onFrame(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull);
    expect(announcer.history, hasLength(1));
  });

  test('禁播时不说，但仍然记录决策', () {
    announcer.enabled = false;
    final a = announcer.onFrame(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull, reason: '决策仍然产生，只是不发声');
    expect(speaker.spoken, isEmpty);
  });

  test('播报文本就是类别中文名，不加修饰语', () {
    final label = kLabels.firstWhere((l) => l.id == _binId);
    expect(announceTextFor(label), label.nameZh);
  });
}
