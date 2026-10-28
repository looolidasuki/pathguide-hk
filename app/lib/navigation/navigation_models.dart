import 'dart:math' as math;

enum MapProvider { apple, google }

class NavigationFailure implements Exception {
  const NavigationFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

class Coordinate {
  const Coordinate(this.latitude, this.longitude);
  final double latitude, longitude;
  bool get valid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180;
  factory Coordinate.fromMap(Map value) {
    final c = Coordinate(
      (value['latitude'] as num).toDouble(),
      (value['longitude'] as num).toDouble(),
    );
    if (!c.valid) throw const NavigationFailure('invalid_data', '地圖座標無效，請重試。');
    return c;
  }
  Map<String, double> toMap() => {'latitude': latitude, 'longitude': longitude};
  double distanceTo(Coordinate b) {
    const r = 6371000.0;
    final x =
        (b.longitude - longitude) *
        math.pi /
        180 *
        math.cos((latitude + b.latitude) * math.pi / 360);
    final y = (b.latitude - latitude) * math.pi / 180;
    return math.sqrt(x * x + y * y) * r;
  }
}

class Place {
  const Place({
    required this.provider,
    required this.id,
    required this.name,
    required this.address,
    required this.coordinate,
  });
  final MapProvider provider;
  final String id, name, address;
  final Coordinate coordinate;
  factory Place.fromMap(Map m) => Place(
    provider: MapProvider.values.byName(m['provider'] as String),
    id: m['id'] as String,
    name: m['name'] as String,
    address: m['address'] as String? ?? '',
    coordinate: Coordinate.fromMap(m['coordinate'] as Map),
  );
  Map<String, Object> toMap() => {
    'provider': provider.name,
    'id': id,
    'name': name,
    'address': address,
    'coordinate': coordinate.toMap(),
  };
}

class RouteStep {
  const RouteStep({
    required this.instructions,
    required this.polyline,
    this.notice = '',
    this.maneuver = 'unknown',
  });
  final String instructions, notice, maneuver;
  final List<Coordinate> polyline;
  factory RouteStep.fromMap(Map m) => RouteStep(
    instructions: m['instructions'] as String? ?? '',
    notice: m['notice'] as String? ?? '',
    maneuver: m['maneuver'] as String? ?? 'unknown',
    polyline: coordinates(m['polyline']),
  );
  Map<String, Object> toMap() => {
    'instructions': instructions,
    'notice': notice,
    'maneuver': maneuver,
    'polyline': polyline.map((p) => p.toMap()).toList(),
  };
}

List<Coordinate> coordinates(Object? value) => (value as List)
    .map((p) => Coordinate.fromMap(p as Map))
    .toList(growable: false);

class WalkingRoute {
  const WalkingRoute({
    required this.provider,
    required this.id,
    required this.polyline,
    required this.steps,
    required this.distance,
    required this.duration,
    this.notices = const [],
  });
  final MapProvider provider;
  final String id;
  final List<Coordinate> polyline;
  final List<RouteStep> steps;
  final double distance, duration;
  final List<String> notices;
  factory WalkingRoute.fromMap(Map m) {
    final route = WalkingRoute(
      provider: MapProvider.values.byName(m['provider'] as String),
      id: m['id'] as String,
      polyline: coordinates(m['polyline']),
      steps: (m['steps'] as List)
          .map((s) => RouteStep.fromMap(s as Map))
          .toList(),
      distance: (m['distance'] as num).toDouble(),
      duration: (m['duration'] as num).toDouble(),
      notices: (m['notices'] as List? ?? []).cast<String>(),
    );
    if (route.polyline.length < 2 ||
        route.steps.isEmpty ||
        !route.distance.isFinite ||
        route.distance <= 0 ||
        !route.duration.isFinite ||
        route.duration < 0) {
      throw const NavigationFailure('no_route', '未取得完整步行路線，請重試。');
    }
    return route;
  }
  Map<String, Object> toMap() => {
    'provider': provider.name,
    'id': id,
    'polyline': polyline.map((p) => p.toMap()).toList(),
    'steps': steps.map((s) => s.toMap()).toList(),
    'distance': distance,
    'duration': duration,
    'notices': notices,
  };
}

class LocationFix {
  const LocationFix({
    required this.coordinate,
    required this.accuracy,
    required this.receivedAt,
    this.ageSeconds = 0,
    this.course,
  });
  final Coordinate coordinate;
  final double accuracy, ageSeconds;
  final Duration receivedAt;
  final double? course;
  bool usable(Duration now, NavigationRules rules) =>
      coordinate.valid &&
      accuracy.isFinite &&
      accuracy >= 0 &&
      accuracy <= rules.maxAccuracy &&
      ageSeconds.isFinite &&
      ageSeconds >= 0 &&
      ageSeconds + (now - receivedAt).inMilliseconds / 1000 <=
          rules.maxAge.inSeconds;
}

/// Versioned engineering defaults, not an assertion of real-world GPS accuracy.
class NavigationRules {
  const NavigationRules();
  final int version = 1;
  final double maxAccuracy = 25, nearAccuracy = 15, advanceMetres = 5;
  final double advanceNotice = 50, nearNotice = 15, offRouteMetres = 35;
  final double arrivalRadius = 25, arrivalRemaining = 35;
  final Duration maxAge = const Duration(seconds: 10),
      deviationTime = const Duration(seconds: 10),
      recalculateCooldown = const Duration(seconds: 30);
}

enum NavigationState {
  idle,
  searching,
  locating,
  calculating,
  preview,
  navigating,
  locationPoor,
  rerouting,
  paused,
  nearby,
  failed,
}

class NavigationSession {
  const NavigationSession({
    required this.id,
    required this.destination,
    required this.route,
  });
  final int id;
  final Place destination;
  final WalkingRoute route;
}
