import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../vision/model_manifest.dart';
import '../vision/platform_vision.dart'
    show defaultModelAssetKey, defaultModelManifestKey;

/// The depth trial uses the bundled shared model and its exact mapping only.
/// No personal weights or network downloads enter this camera session.
Future<Map<String, Object>> prepareDepthModel({
  AssetBundle? bundle,
  Future<Directory> Function()? directory,
}) async {
  final assets = bundle ?? rootBundle;
  final parsed = parseModelManifest(
    await assets.loadString(defaultModelManifestKey),
  );
  if (!parsed.ok) throw StateError('Invalid model manifest');
  final manifest = parsed.manifest!;
  final data = await assets.load(defaultModelAssetKey);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  if (manifest.bytes != bytes.length ||
      manifest.sha256 != sha256.convert(bytes).toString()) {
    throw StateError('Model checksum mismatch');
  }
  final root = await (directory ?? getApplicationSupportDirectory)();
  final cache = Directory('${root.path}/PathGuideDepth');
  await cache.create(recursive: true);
  final file = File('${cache.path}/${manifest.sha256}.tflite');
  if (!await file.exists() ||
      sha256.convert(await file.readAsBytes()).toString() != manifest.sha256) {
    // Private application cache; native loading happens only after this completes.
    await file.writeAsBytes(bytes, flush: true);
  }
  return {
    'model': file.path,
    'sha256': manifest.sha256!,
    'bytes': manifest.bytes!,
    'classIds': manifest.modelClassIds.isEmpty
        ? List<int>.generate(manifest.modelClassCount, (index) => index)
        : manifest.modelClassIds,
    'inputSize': manifest.inputSize,
    'classes': manifest.modelClassCount,
    'version': manifest.version,
  };
}
