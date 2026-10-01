// 模型清单：模型下发的单位是「模型 + 它的类别映射」。
//
// 这里守的是本项目最容易踩的静默故障：模型与映射不同步时，每个框的名字
// 都是错的，**而且不报错**。所以校验必须严格——任何一项不合法都返回失败原因，
// 绝不降级猜一个。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/labels.dart';
import 'package:pathguide/vision/model_manifest.dart';

// 合成清单：字段全合法，但 sha256 是「真实模型哈希的前 16 位 + 48 个 0」。
// 用假哈希不是为了偷懒，而是让这份 fixture 不依赖某个具体模型文件——
// 真实模型的清单由下面「防漂移」那组测试直接读盘校验。
const String _valid = '''
{
  "format": 1,
  "version": "2026-09-30.1",
  "file": "detector.tflite",
  "bytes": 2871365,
  "sha256": "38e56bdd46f90d8f000000000000000000000000000000000000000000000000",
  "inputSize": 416,
  "modelClassCount": 3,
  "modelClassIds": [6, 11, 7],
  "trainedAt": "2026-09-30",
  "map50": 0.744
}
''';

void main() {
  group('合法清单', () {
    test('解析出全部字段', () {
      final r = parseModelManifest(_valid);
      expect(r.ok, isTrue, reason: r.error);
      final m = r.manifest!;
      expect(m.format, 1);
      expect(m.version, '2026-09-30.1');
      expect(m.modelClassCount, 3);
      expect(m.modelClassIds, <int>[6, 11, 7]);
      expect(m.inputSize, 416);
      expect(m.bytes, 2871365);
      expect(m.map50, closeTo(0.744, 1e-9));
    });

    test('转成映射后逐项正确', () {
      final m = parseModelManifest(_valid).manifest!;
      final map = m.toMapping();
      expect(map.appIdFor(0), 6);
      expect(map.appIdFor(1), 11);
      expect(map.appIdFor(2), 7);
      expect(labelOf(map.appIdFor(0)!)!.nameEn, 'pedestrian');
      expect(labelOf(map.appIdFor(2)!)!.nameEn, 'bin');
    });

    test('说明文字含版本、类别与 id', () {
      final d = parseModelManifest(_valid).manifest!.describe();
      expect(d, contains('2026-09-30.1'));
      expect(d, contains('pedestrian'));
      expect(d, contains('bin'));
    });
  });

  group('拒绝不合法的清单（宁可失败也不猜）', () {
    String withField(String json) => json;

    test('不是 JSON', () {
      expect(parseModelManifest('不是 json').ok, isFalse);
    });

    test('format 不认（必须报错而不是忽略未知字段）', () {
      final r = parseModelManifest(withField(_valid.replaceAll('"format": 1', '"format": 2')));
      expect(r.ok, isFalse);
      expect(r.error, contains('format'));
    });

    test('缺 version / file / inputSize / modelClassCount', () {
      for (final key in <String>['version', 'file', 'inputSize', 'modelClassCount']) {
        final broken = _valid.replaceAll(RegExp('"$key":\\s*("[^"]*"|\\d+),?\\n'), '');
        final r = parseModelManifest(broken);
        expect(r.ok, isFalse, reason: '缺 $key 时必须失败');
      }
    });

    test('映射表长度与类别数不符', () {
      final r = parseModelManifest(
          _valid.replaceAll('[6, 11, 7]', '[6, 11]'));
      expect(r.ok, isFalse);
      expect(r.error, contains('长度'));
    });

    test('映射表里有超出类别表的 id', () {
      final r = parseModelManifest(_valid.replaceAll('[6, 11, 7]', '[6, 11, 999]'));
      expect(r.ok, isFalse);
      expect(r.error, contains('超出类别表'));
    });

    test('映射表里有重复 id', () {
      final r = parseModelManifest(_valid.replaceAll('[6, 11, 7]', '[7, 7, 6]'));
      expect(r.ok, isFalse);
      expect(r.error, contains('重复'));
    });

    test('空映射表只在模型类别数等于类别表时成立', () {
      final ok = parseModelManifest(
          _valid.replaceAll('"modelClassCount": 3', '"modelClassCount": $kNumClasses')
                .replaceAll('[6, 11, 7]', '[]'));
      expect(ok.ok, isTrue, reason: ok.error);
      expect(ok.manifest!.toMapping().identity, isTrue);

      final bad = parseModelManifest(_valid.replaceAll('[6, 11, 7]', '[]'));
      expect(bad.ok, isFalse);
    });

    test('sha256 格式不对', () {
      final r = parseModelManifest(_valid.replaceAll('38e56bdd', 'ZZZZ'));
      expect(r.ok, isFalse);
      expect(r.error, contains('sha256'));
    });
  });

  group('内置清单与内置模型必须同步（防漂移）', () {
    // 这条守的是「换了模型但忘了重生成清单」——那会让 App 把每个框标错类。
    // 字节数对不上就说明两者不是同一次导出的产物。
    final manifestPath = File('assets/models/detector.json');
    final modelPath = File('assets/models/detector.tflite');

    test('两个文件都在', () {
      expect(manifestPath.existsSync(), isTrue,
          reason: 'app/assets/models/detector.json 缺失；'
              '它由 scripts/export_tflite.py 生成');
      expect(modelPath.existsSync(), isTrue);
    });

    test('清单能通过校验', () {
      final r = parseModelManifest(manifestPath.readAsStringSync());
      expect(r.ok, isTrue, reason: r.error);
    });

    test('清单的 bytes 与模型文件大小一致', () {
      final m = parseModelManifest(manifestPath.readAsStringSync()).manifest!;
      expect(m.bytes, modelPath.lengthSync(),
          reason: '清单记的是 ${m.bytes} 字节，模型实际 ${modelPath.lengthSync()} 字节：'
              '两者不是同一次导出的产物，需重新跑 scripts/export_tflite.py');
    });

    test('清单的类别映射在类别表内且与类别数相符', () {
      final m = parseModelManifest(manifestPath.readAsStringSync()).manifest!;
      expect(m.modelClassIds.length, m.modelClassCount);
      for (final id in m.modelClassIds) {
        expect(labelOf(id), isNotNull);
      }
    });
  });
}
