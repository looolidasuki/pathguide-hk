import 'package:flutter_test/flutter_test.dart';

import 'dart:async';

import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/labels.dart';

/// Latest-frame summaries with class deduplication and repeat cooldown.
///
/// 这块逻辑在真机上极难验证——你不可能一边举着手机一边数「刚才那句话该不该说」。
/// 所以时钟做成可注入的，用测试把取舍全钉死。
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
class _DelayedStopSpeaker extends _FakeSpeaker {
  final pendingStop = Completer<void>();
  @override
  Future<void> stop() => pendingStop.future;
}

class _Clock {
  DateTime now = DateTime(2026, 9, 22, 10, 0, 0);
  void advance(Duration d) => now = now.add(d);
  DateTime call() => now;
}

Detection _det(int id, {double score = 0.9}) =>
    Detection(id: id, score: score, cx: 0.5, cy: 0.5, w: 0.2, h: 0.2);

/// `bin`（id=7，P0）作为锚点类。
final int _binP0Id = kLabels.firstWhere((l) => l.nameEn == 'bin').id;

/// 「另一个可播报类」，用于验证跨类的全局冷却。
final int _otherAnnouncedId = kLabels
    .firstWhere((l) => l.announced && l.id != _binP0Id)
    .id;

void main() {
  test(
    'disabling speech cancels an announcement waiting for interruption',
    () async {
      final delayed = _DelayedStopSpeaker();
      final announcer = Announcer(speaker: delayed);
      announcer.onFrame([_det(_binP0Id)]);
      final pending = announcer.lastSpeech;
      announcer.enabled = false;
      announcer.enabled = true;
      delayed.pendingStop.complete();
      await pending;
      expect(delayed.spoken, isEmpty);
    },
  );
  late _FakeSpeaker speaker;
  late _Clock clock;
  late Announcer announcer;

  setUp(() {
    speaker = _FakeSpeaker();
    clock = _Clock();
    announcer = Announcer(speaker: speaker, clock: clock.call);
  });

  /// 送一帧并**等待播报真正发生**。
  ///
  /// 必须等：`onFrame` 内部是 fire-and-forget 的（它由相机帧回调驱动，
  /// 在里面阻塞会掉帧），不等就会看到空的 spoken 列表——
  /// 这正是本项目第一次跑测试时的失败原因，也是 [Announcer.lastSpeech] 存在的原因。
  Future<Announcement?> announce(
    List<Detection> dets, {
    bool force = false,
  }) async {
    final a = announcer.onFrame(dets, force: force);
    if (a != null) {
      await announcer.lastSpeech;
    }
    return a;
  }

  test('首幀即播報', () async {
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, kLabels[_binP0Id].nameZh);
  });

  test('同一類在冷卻期内不重複播報', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 1));
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNull);
    expect(speaker.spoken, hasLength(1), reason: '1 秒 < 5 秒同類冷卻');
  });

  test('同類冷卻過後可以再播', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 6)); // 同时越过全局冷却
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(2));
  });

  test('新類別不會被全局冷卻阻擋', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 3)); // 越过同类冷却，未越全局冷却
    final a = await announce(<Detection>[_det(_otherAnnouncedId)]);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(2));
  });

  test('force 可以绕過冷卻', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(milliseconds: 100));
    final a = await announce(<Detection>[_det(_binP0Id)], force: true);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(2));
  });

  test('空幀不播報', () async {
    expect(await announce(const <Detection>[]), isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('不可播報的類別被忽略（如 streetlight：到处都有、又不可行動）', () async {
    final id = kLabels.firstWhere((l) => !l.announced).id;
    expect(await announce(<Detection>[_det(id)]), isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('未知類別 id 不會崩，也不會播報', () async {
    expect(await announce(<Detection>[_det(999)]), isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('同類多個候选只播一次', () async {
    await announce(<Detection>[
      _det(_binP0Id, score: 0.6),
      _det(_binP0Id, score: 0.95),
      _det(_binP0Id, score: 0.8),
    ]);
    expect(speaker.spoken, hasLength(1));
  });

  test('记下跳過原因，便於現场解释', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 1));
    await announce(<Detection>[_det(_binP0Id)]);
    expect(announcer.history, hasLength(2));
    expect(announcer.history.last.reason, contains('跳過'));
  });

  group('分數門檻：低分只画框，不開口', () {
    test('低於門檻的檢出不被播報，但决策被记錄', () async {
      // 误报的代价是不对称的：屏幕上多一个框无害，说出口会让用户
      // 对空无一物做出动作。所以低分必须「看得见但不说话」。
      expect(await announce(<Detection>[_det(_binP0Id, score: 0.35)]), isNull);
      expect(speaker.spoken, isEmpty, reason: '低分不應该发聲');
      expect(announcer.history, hasLength(1), reason: '仍要留下决策记錄');
      expect(announcer.history.single.reason, contains('播報門檻'));
      expect(announcer.history.single.reason, contains('0.35'));
    });

    test('刚好达到門檻就播報', () async {
      // 边界取 >=：门槛值本身应当算作「够格」，否则调参时会出现
      // 「设成 0.70 却永远播不出 0.70」这种说不清的行为。
      final a = await announce(<Detection>[
        _det(_binP0Id, score: kMinSpeakScore),
      ]);
      expect(a, isNotNull);
      expect(speaker.spoken, hasLength(1));
    });

    test('force 不能绕過分數門檻（force 只管时機，不管真假）', () async {
      // force 的语义是「别被冷却挡住」，用于演示与测试；
      // 若它能绕过分数门槛，就等于留了一个「逢低分也照念」的后门。
      expect(
        await announce(<Detection>[_det(_binP0Id, score: 0.35)], force: true),
        isNull,
      );
      expect(speaker.spoken, isEmpty);
    });

    test('低分候选被跳過时，後面的高分候选仍能播報', () async {
      // 候选按优先级排序，低分的 P0 不应该把高分的其他类一起挡掉。
      final a = await announce(<Detection>[
        _det(_binP0Id, score: 0.40), // 低于门槛，跳过
        _det(_otherAnnouncedId, score: 0.95), // 应当接上
      ]);
      expect(a, isNotNull);
      expect(a!.label.id, _otherAnnouncedId);
      expect(speaker.spoken, hasLength(1));
    });

    test('門檻可注入，便於按模型重新標定', () async {
      final strict = Announcer(speaker: speaker, minSpeakScore: 0.99);
      expect(strict.onFrame(<Detection>[_det(_binP0Id, score: 0.95)]), isNull);
      final loose = Announcer(speaker: speaker, minSpeakScore: 0.10);
      expect(
        loose.onFrame(<Detection>[_det(_binP0Id, score: 0.95)]),
        isNotNull,
      );
    });
  });

  test('reset 清空冷卻，新场景第一個目標不會被旧冷卻压掉', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(milliseconds: 100));
    announcer.reset();
    expect(await announce(<Detection>[_det(_binP0Id)]), isNotNull);
    expect(announcer.history, hasLength(1));
  });

  test('禁播时不说，但仍然记錄决策', () async {
    announcer.enabled = false;
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull, reason: '决策仍然产生，只是不发聲');
    expect(speaker.spoken, isEmpty);
  });

  test('每句最多三類，下一幀只選最新而不補讀過期結果', () async {
    await announce([_det(6), _det(7), _det(8), _det(9)]);
    expect(speaker.spoken.single.split('、'), hasLength(3));
    await announce([_det(11)]);
    expect(speaker.spoken.last, kLabels[11].nameZh);
    expect(speaker.spoken.last, isNot(contains(kLabels[9].nameZh)));
  });

  test('同類五秒內不重播，五秒後可以重播', () async {
    await announce([_det(7)]);
    clock.advance(const Duration(seconds: 4));
    expect(await announce([_det(7)]), isNull);
    clock.advance(const Duration(seconds: 1));
    expect(await announce([_det(7)]), isNotNull);
  });

  test('播報未完成時不打斷也不排隊', () async {
    final delayed = _DelayedStopSpeaker();
    final busy = Announcer(speaker: delayed);
    busy.onFrame([_det(7)]);
    final speech = busy.lastSpeech;
    expect(busy.onFrame([_det(8)]), isNull);
    delayed.pendingStop.complete();
    await speech;
    expect(delayed.spoken, [kLabels[7].nameZh]);
    busy.onFrame([_det(9)]);
    await busy.lastSpeech;
    expect(delayed.spoken.last, kLabels[9].nameZh);
  });

  test('播報文本就是類別中文名，不加修饰語', () {
    final label = kLabels[_binP0Id];
    expect(announceTextFor(label), label.nameZh);
  });
}
