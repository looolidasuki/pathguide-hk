import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathguide/depth/depth_model.dart';

class ModelAssets extends CachingAssetBundle {
  List<int> model = [1, 2, 3, 4];
  late Map<String, Object> manifest = {
    'format': 1,
    'version': 'fixture',
    'file': 'detector.tflite',
    'modelClassCount': 1,
    'modelClassIds': [7],
    'inputSize': 640,
    'bytes': 4,
    'sha256': sha256.convert(model).toString(),
  };
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
    Uint8List.fromList(
      key.endsWith('.json') ? utf8.encode(jsonEncode(manifest)) : model,
    ),
  );
}

void main() {
  late Directory folder;
  setUp(
    () async => folder = await Directory.systemTemp.createTemp(
      'pathguide-depth-model-test-',
    ),
  );
  tearDown(() async => folder.delete(recursive: true));
  test('loads only checksum-verified asset and carries its mapping', () async {
    final assets = ModelAssets();
    final prepared = await prepareDepthModel(
      bundle: assets,
      directory: () async => folder,
    );
    expect(prepared['classIds'], [7]);
    expect(prepared['version'], 'fixture');
    expect(await File(prepared['model'] as String).readAsBytes(), assets.model);
  });
  test('same-size corrupt cache is repaired from verified asset', () async {
    final assets = ModelAssets();
    final first = await prepareDepthModel(
      bundle: assets,
      directory: () async => folder,
    );
    await File(first['model'] as String).writeAsBytes([9, 9, 9, 9]);
    final next = await prepareDepthModel(
      bundle: assets,
      directory: () async => folder,
    );
    expect(await File(next['model'] as String).readAsBytes(), assets.model);
  });
  test('asset checksum mismatch cannot produce an offer', () async {
    final assets = ModelAssets();
    assets.manifest['sha256'] = '0' * 64;
    await expectLater(
      prepareDepthModel(bundle: assets, directory: () async => folder),
      throwsStateError,
    );
    expect(await folder.list().isEmpty, isTrue);
  });
  test('invalid class mapping is rejected before a cache is created', () async {
    final assets = ModelAssets();
    assets.manifest['modelClassIds'] = [999];
    await expectLater(
      prepareDepthModel(bundle: assets, directory: () async => folder),
      throwsStateError,
    );
    expect(await folder.list().isEmpty, isTrue);
  });
}
