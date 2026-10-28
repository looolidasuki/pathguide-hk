import '../menu/menu_reader.dart';
import 'navigation_models.dart';

abstract interface class PlaceSearchService {
  MapProvider get provider;
  Future<List<Place>> search(String text);
  Future<Place> resolve(SavedDestination destination);
  Future<void> cancelSearch();
}

abstract interface class WalkingRouteService {
  Future<WalkingRoute> calculate(Coordinate origin, Place destination);
  Future<void> cancelRoute();
}

abstract interface class LocationService {
  Future<LocationFix> current();
  Stream<LocationFix> get updates;
  Future<void> start();
  Future<void> stop();
  Future<String?> address(Coordinate coordinate);
  Future<void> keepAwake(bool enabled);
}

/// Shared speech contract; menu's existing native recognizer remains the iOS implementation.
abstract interface class SpeechInputService {
  Future<MenuSpeechResult> listen({
    required bool allowNetwork,
    required void Function(String) onPartial,
    required void Function(MenuSpeechPhase) onPhase,
  });
  Future<void> cancel();
  void dispose();
}

class MenuSpeechInput implements SpeechInputService {
  MenuSpeechInput(this.reader);
  final MenuReader reader;
  @override
  Future<MenuSpeechResult> listen({
    required bool allowNetwork,
    required void Function(String) onPartial,
    required void Function(MenuSpeechPhase) onPhase,
  }) => reader.listen(
    allowNetwork: allowNetwork,
    onPartial: onPartial,
    onPhase: onPhase,
  );
  @override
  Future<void> cancel() => reader.cancel();
  @override
  void dispose() => reader.dispose();
}

class SavedDestination {
  const SavedDestination({
    required this.provider,
    required this.id,
    required this.label,
    required this.savedAt,
    this.applePlace,
  });
  final MapProvider provider;
  final String id, label;
  final DateTime savedAt;
  // Google content is resolved afresh using the place ID, never stored here.
  final Place? applePlace;
  factory SavedDestination.fromPlace(Place place, String label) =>
      SavedDestination(
        provider: place.provider,
        id: place.id,
        label: label,
        savedAt: DateTime.now().toUtc(),
        applePlace: place.provider == MapProvider.apple ? place : null,
      );
  factory SavedDestination.fromMap(Map m) => SavedDestination(
    provider: MapProvider.values.byName(m['provider'] as String),
    id: m['id'] as String,
    label: m['label'] as String,
    savedAt: DateTime.parse(m['savedAt'] as String),
    applePlace: m['provider'] == 'apple' && m['place'] != null
        ? Place.fromMap(m['place'] as Map)
        : null,
  );
  Map<String, Object> toMap() => {
    'provider': provider.name,
    'id': id,
    'label': label,
    'savedAt': savedAt.toIso8601String(),
    if (provider == MapProvider.apple && applePlace != null)
      'place': applePlace!.toMap(),
  };
}

abstract interface class DestinationStore {
  Future<({List<SavedDestination> favorites, List<SavedDestination> recent})>
  load();
  Future<void> save(
    List<SavedDestination> favorites,
    List<SavedDestination> recent,
  );
}
