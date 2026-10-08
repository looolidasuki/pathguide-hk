import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/l10n/app_locale.dart';
import 'package:pathguide/tts/announcer.dart';
import 'package:pathguide/vision/detection.dart';
import 'package:pathguide/vision/labels.dart';

/// 播报调度：两级冷却 + 优先级插队。
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

/// `bin`（id=7，P0）作为锚点类。
final int _binP0Id = kLabels.firstWhere((l) => l.nameEn == 'bin').id;

/// 「另一个可播报类」，用于验证跨类的全局冷却。
final int _otherAnnouncedId =
    kLabels.firstWhere((l) => l.announced && l.id != _binP0Id).id;

void main() {
  late _FakeSpeaker speaker;
  late _Clock clock;
  late Announcer announcer;

  setUp(() {
    // Tests assert Chinese UI/TTS copy; pin the zh pack regardless of host OS.
    AppLocale.current = AppLanguage.zh;
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

  test('首帧即播报', () async {
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, kLabels[_binP0Id].nameZh);
  });

  test('同一类在冷却期内不重复播报', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 1));
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNull);
    expect(speaker.spoken, hasLength(1), reason: '1 秒 < 2 秒同类冷却');
  });

  test('同类冷却过后可以再播', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 6)); // 同时越过全局冷却
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(2));
  });

  test('全局冷却会压掉不同类的播报', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 3)); // 越过同类冷却，未越全局冷却
    final a = await announce(<Detection>[_det(_otherAnnouncedId)]);
    expect(a, isNull, reason: '3 秒 < 5 秒全局冷却');
    expect(speaker.spoken, hasLength(1));
  });

  test('force 可以绕过冷却', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(milliseconds: 100));
    final a = await announce(<Detection>[_det(_binP0Id)], force: true);
    expect(a, isNotNull);
    expect(speaker.spoken, hasLength(2));
  });

  test('空帧不播报', () async {
    expect(await announce(const <Detection>[]), isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('不可播报的类别被忽略（如 streetlight：到处都有、又不可行动）', () async {
    final id = kLabels.firstWhere((l) => !l.announced).id;
    expect(await announce(<Detection>[_det(id)]), isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('未知类别 id 不会崩，也不会播报', () async {
    expect(await announce(<Detection>[_det(999)]), isNull);
    expect(speaker.spoken, isEmpty);
  });

  test('同类多个候选只播一次', () async {
    await announce(<Detection>[
      _det(_binP0Id, score: 0.6),
      _det(_binP0Id, score: 0.95),
      _det(_binP0Id, score: 0.8),
    ]);
    expect(speaker.spoken, hasLength(1));
  });

  test('记下跳过原因，便于现场解释', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(seconds: 1));
    await announce(<Detection>[_det(_binP0Id)]);
    expect(announcer.history, hasLength(2));
    expect(
      announcer.history.last.reason,
      anyOf(contains('跳過'), contains('跳过'), contains('skip')),
    );
  });

  group('分数门槛：低分只画框，不开口', () {
    test('低于门槛的检出不被播报，但决策被记录', () async {
      // 误报的代价是不对称的：屏幕上多一个框无害，说出口会让用户
      // 对空无一物做出动作。所以低分必须「看得见但不说话」。
      expect(await announce(<Detection>[_det(_binP0Id, score: 0.35)]), isNull);
      expect(speaker.spoken, isEmpty, reason: '低分不应该发声');
      expect(announcer.history, hasLength(1), reason: '仍要留下决策记录');
      expect(announcer.history.single.reason, contains('播報門檻'));
      expect(announcer.history.single.reason, contains('0.35'));
    });

    test('刚好达到门槛就播报', () async {
      // 边界取 >=：门槛值本身应当算作「够格」，否则调参时会出现
      // 「设成 0.70 却永远播不出 0.70」这种说不清的行为。
      final a = await announce(
        <Detection>[_det(_binP0Id, score: kMinSpeakScore)],
      );
      expect(a, isNotNull);
      expect(speaker.spoken, hasLength(1));
    });

    test('force 不能绕过分数门槛（force 只管时机，不管真假）', () async {
      // force 的语义是「别被冷却挡住」，用于演示与测试；
      // 若它能绕过分数门槛，就等于留了一个「逢低分也照念」的后门。
      expect(
        await announce(<Detection>[_det(_binP0Id, score: 0.35)], force: true),
        isNull,
      );
      expect(speaker.spoken, isEmpty);
    });

    test('低分候选被跳过时，后面的高分候选仍能播报', () async {
      // 候选按优先级排序，低分的 P0 不应该把高分的其他类一起挡掉。
      final a = await announce(<Detection>[
        _det(_binP0Id, score: 0.40), // 低于门槛，跳过
        _det(_otherAnnouncedId, score: 0.95), // 应当接上
      ]);
      expect(a, isNotNull);
      expect(a!.label.id, _otherAnnouncedId);
      expect(speaker.spoken, hasLength(1));
    });

    test('门槛可注入，便于按模型重新标定', () async {
      final strict = Announcer(speaker: speaker, minSpeakScore: 0.99);
      expect(strict.onFrame(<Detection>[_det(_binP0Id, score: 0.95)]), isNull);
      final loose = Announcer(speaker: speaker, minSpeakScore: 0.10);
      expect(loose.onFrame(<Detection>[_det(_binP0Id, score: 0.95)]), isNotNull);
    });
  });

  test('reset 清空冷却，新场景第一个目标不会被旧冷却压掉', () async {
    await announce(<Detection>[_det(_binP0Id)]);
    clock.advance(const Duration(milliseconds: 100));
    announcer.reset();
    expect(await announce(<Detection>[_det(_binP0Id)]), isNotNull);
    expect(announcer.history, hasLength(1));
  });

  test('禁播时不说，但仍然记录决策', () async {
    announcer.enabled = false;
    final a = await announce(<Detection>[_det(_binP0Id)]);
    expect(a, isNotNull, reason: '决策仍然产生，只是不发声');
    expect(speaker.spoken, isEmpty);
  });

  test('播报文本就是类别中文名，不加修饰语', () {
    final label = kLabels[_binP0Id];
    expect(announceTextFor(label), label.nameZh);
  });
}

