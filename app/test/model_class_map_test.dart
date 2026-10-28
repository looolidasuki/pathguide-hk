// 模型本地索引 -> 项目类别真实 id 的映射。
//
// 本文件守的是本项目最贵的一类错误：类别索引错位。
// 它不会崩、不会报错，只会让每个框的名字是另一个类——训练时看着「指标还行」，
// 演示时看着「框都画出来了」。所以每条规则都钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/labels.dart';
import 'package:pathguide/vision/model_class_map.dart';

void main() {
  test('HKDI 十類模型映射保留合併樓梯、圍欄及通用門', () {
    final mapping = resolveMapping(
      modelClassCount: 10,
      declared: const [6, 11, 7, 8, 9, 24, 1, 49, 26, 18],
    )!;
    expect(List.generate(10, (i) => labelOf(mapping.appIdFor(i)!)!.nameEn), [
      'pedestrian', 'bicycle', 'bin', 'bollard', 'traffic_cone',
      'caution_slippery', 'stairs', 'escalator', 'fence', 'door',
    ]);
    expect(labelOf(mapping.appIdFor(6)!)!.nameZh, '樓梯');
    expect(labelOf(mapping.appIdFor(9)!)!.nameZh, '門');
    expect(mapping.appIdFor(10), isNull);
  });
  test('香港九類映射保留上下樓梯及既有類別語義', () {
    final mapping = resolveMapping(
      modelClassCount: 9,
      declared: const [11, 7, 8, 50, 49, 6, 9, 51, 24],
    )!;
    final names = List.generate(
      9,
      (i) => labelOf(mapping.appIdFor(i)!)!.nameEn,
    );
    expect(names, [
      'bicycle',
      'bin',
      'bollard',
      'downstairs',
      'escalator',
      'pedestrian',
      'traffic_cone',
      'upstairs',
      'caution_slippery',
    ]);
    expect(labelOf(mapping.appIdFor(3)!)!.nameZh, '落樓梯');
    expect(labelOf(mapping.appIdFor(7)!)!.nameZh, '上樓梯');
    expect(mapping.appIdFor(9), isNull);
  });
  group('identity：模型類別數已等於項目類別表', () {
    test('不需要映射，輸出即真實 id', () {
      // 类别数正好等于项目表时，声明表可以留空——空表只在这个条件下合法。
      final m = resolveMapping(
        modelClassCount: kNumClasses,
        declared: const <int>[],
      )!;
      expect(m.identity, isTrue);
      expect(m.ids, isEmpty);
      for (final id in <int>[0, 6, 7, 47]) {
        expect(m.appIdFor(id), id);
      }
    });

    test('越界返回 null 而不是原样放行', () {
      final m = resolveMapping(
        modelClassCount: kNumClasses,
        declared: const <int>[],
      )!;
      expect(m.appIdFor(-1), isNull);
      expect(m.appIdFor(kNumClasses), isNull);
    });
  });

  group('映射表：模型類別數少於項目類別表', () {
    test('按聲明表逐項映射（歷史 3 類模型的聲明）', () {
      final m = resolveMapping(
        modelClassCount: 3,
        declared: const <int>[6, 11, 7], // pedestrian / bicycle / bin
      )!;
      expect(m.identity, isFalse);
      expect(m.appIdFor(0), 6);
      expect(m.appIdFor(1), 11);
      expect(m.appIdFor(2), 7);
      // 关键反例：不映射的话 0 会指向 footbridge_entrance（天橋入口），
      // 于是垃圾桶被念成「天橋入口」。
      expect(m.appIdFor(0), isNot(0));
      expect(labelOf(m.appIdFor(0)!)!.nameEn, 'pedestrian');
      expect(labelOf(m.appIdFor(2)!)!.nameEn, 'bin');
    });

    test('單類模型是長度 1 的特例（旧的偏移機製）', () {
      final m = resolveMapping(modelClassCount: 1, declared: const <int>[7])!;
      expect(m.appIdFor(0), 7);
      expect(labelOf(7)!.nameEn, 'bin');
    });

    test('本地索引越界返回 null，调用方應丢弃该框', () {
      final m = resolveMapping(
        modelClassCount: 3,
        declared: const <int>[6, 11, 7],
      )!;
      expect(m.appIdFor(3), isNull);
      expect(m.appIdFor(-1), isNull);
    });

    test('说明文字裏寫出映射结果與「其餘類別不會出框」', () {
      final m = resolveMapping(
        modelClassCount: 3,
        declared: const <int>[6, 11, 7],
      )!;
      final d = m.describe();
      expect(d, contains('行人'));
      expect(d, contains('垃圾桶'));
      expect(d, contains('${kNumClasses - 3}'));
    });
  });

  group('拒绝猜測（宁可失敗也不映射錯）', () {
    test('聲明表長度與模型類別數不符 -> null', () {
      expect(
        resolveMapping(modelClassCount: 3, declared: const <int>[6, 11]),
        isNull,
      );
      expect(
        resolveMapping(modelClassCount: 3, declared: const <int>[6, 11, 7, 9]),
        isNull,
      );
    });

    test('類別數不等於項目表卻又没给聲明 -> null', () {
      expect(
        resolveMapping(modelClassCount: 3, declared: const <int>[]),
        isNull,
      );
    });

    test('聲明裏有超出類別表的 id -> null', () {
      expect(
        resolveMapping(
          modelClassCount: 2,
          declared: const <int>[6, kNumClasses],
        ),
        isNull,
      );
    });

    test('聲明裏有重複 id -> null（重複意味著漏了一類）', () {
      expect(
        resolveMapping(modelClassCount: 2, declared: const <int>[7, 7]),
        isNull,
      );
    });
  });

  // 映射表本身（「模型是用哪些 id 训的」）已移到**模型清单**里，
  // 由 app/test/model_manifest_test.dart 校验——它必须跟着模型走，
  // 而不是写死在 Dart 源码里，否则服务端换类别集时 App 会静默标错类。
}
