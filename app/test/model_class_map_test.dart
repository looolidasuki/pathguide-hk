// 模型本地索引 -> 项目类别真实 id 的映射。
//
// 本文件守的是本项目最贵的一类错误：类别索引错位。
// 它不会崩、不会报错，只会让每个框的名字是另一个类——训练时看着「指标还行」，
// 演示时看着「框都画出来了」。所以每条规则都钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/labels.dart';
import 'package:pathguide/vision/model_class_map.dart';

void main() {
  group('identity：模型类别数已等于项目类别表', () {
    test('不需要映射，输出即真实 id', () {
      // 类别数正好等于项目表时，声明表可以留空——空表只在这个条件下合法。
      final m = resolveMapping(modelClassCount: kNumClasses, declared: const <int>[])!;
      expect(m.identity, isTrue);
      expect(m.ids, isEmpty);
      for (final id in <int>[0, 6, 7, 47]) {
        expect(m.appIdFor(id), id);
      }
    });

    test('越界返回 null 而不是原样放行', () {
      final m = resolveMapping(modelClassCount: kNumClasses, declared: const <int>[])!;
      expect(m.appIdFor(-1), isNull);
      expect(m.appIdFor(kNumClasses), isNull);
    });
  });

  group('映射表：模型类别数少于项目类别表', () {
    test('按声明表逐项映射（当前 3 类模型的真实声明）', () {
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

    test('单类模型是长度 1 的特例（旧的偏移机制）', () {
      final m = resolveMapping(modelClassCount: 1, declared: const <int>[7])!;
      expect(m.appIdFor(0), 7);
      expect(labelOf(7)!.nameEn, 'bin');
    });

    test('本地索引越界返回 null，调用方应丢弃该框', () {
      final m = resolveMapping(modelClassCount: 3, declared: const <int>[6, 11, 7])!;
      expect(m.appIdFor(3), isNull);
      expect(m.appIdFor(-1), isNull);
    });

    test('说明文字里写出映射结果与「其余类别不会出框」', () {
      final m = resolveMapping(modelClassCount: 3, declared: const <int>[6, 11, 7])!;
      final d = m.describe();
      expect(d, contains('pedestrian'));
      expect(d, contains('bin'));
      expect(d, contains('${kNumClasses - 3}'));
    });
  });

  group('拒绝猜测（宁可失败也不映射错）', () {
    test('声明表长度与模型类别数不符 -> null', () {
      expect(resolveMapping(modelClassCount: 3, declared: const <int>[6, 11]), isNull);
      expect(resolveMapping(modelClassCount: 3, declared: const <int>[6, 11, 7, 9]),
          isNull);
    });

    test('类别数不等于项目表却又没给声明 -> null', () {
      expect(resolveMapping(modelClassCount: 3, declared: const <int>[]), isNull);
    });

    test('声明里有超出类别表的 id -> null', () {
      expect(
        resolveMapping(modelClassCount: 2, declared: const <int>[6, kNumClasses]),
        isNull,
      );
    });

    test('声明里有重复 id -> null（重复意味着漏了一类）', () {
      expect(resolveMapping(modelClassCount: 2, declared: const <int>[7, 7]), isNull);
    });

  });

  // 映射表本身（「模型是用哪些 id 训的」）已移到**模型清单**里，
  // 由 app/test/model_manifest_test.dart 校验——它必须跟着模型走，
  // 而不是写死在 Dart 源码里，否则服务端换类别集时 App 会静默标错类。
}
