import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/vision/labels.dart';
import 'package:pathguide/vision/single_class_map.dart';

void main() {
  test('多类模型偏移为 0', () {
    final m = resolveMapping(
      modelClassCount: kNumClasses,
      singleClassOriginalId: 7,
    );
    expect(m, isNotNull);
    expect(m!.isSingleClass, isFalse);
    expect(m.classOffset, 0);
  });

  test('单类模型偏移到配置的原始 id', () {
    final m = resolveMapping(
      modelClassCount: 1,
      singleClassOriginalId: 7,
      singleClassName: 'bin',
    );
    expect(m, isNotNull);
    expect(m!.isSingleClass, isTrue);
    expect(m.classOffset, 7);
  });

  test('单类但未声明原始 id 时拒绝猜测', () {
    expect(
      resolveMapping(modelClassCount: 1, singleClassOriginalId: null),
      isNull,
    );
  });
}
