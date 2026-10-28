import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'navigation_models.dart';
import 'navigation_services.dart';

class SecureDestinationStore implements DestinationStore {
  static const key = 'navigation_destinations_v1';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  @override
  Future<({List<SavedDestination> favorites, List<SavedDestination> recent})>
  load() async {
    final raw = await _storage.read(key: key);
    if (raw == null) {
      return (favorites: <SavedDestination>[], recent: <SavedDestination>[]);
    }
    try {
      final m = jsonDecode(raw) as Map;
      if (m['schemaVersion'] != 1) throw const FormatException();
      return (
        favorites: (m['favorites'] as List)
            .map((x) => SavedDestination.fromMap(x as Map))
            .toList(),
        recent: (m['recent'] as List)
            .take(10)
            .map((x) => SavedDestination.fromMap(x as Map))
            .toList(),
      );
    } catch (_) {
      throw const NavigationFailure('storage', '本機收藏未能讀取；可清除本機地點後重試。');
    }
  }

  @override
  Future<void> save(
    List<SavedDestination> favorites,
    List<SavedDestination> recent,
  ) => _storage.write(
    key: key,
    value: jsonEncode({
      'schemaVersion': 1,
      'favorites': favorites.map((p) => p.toMap()).toList(),
      'recent': recent.take(10).map((p) => p.toMap()).toList(),
    }),
  );
}
