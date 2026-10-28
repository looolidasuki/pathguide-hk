import 'dart:math' as math;

import 'navigation_models.dart';

class RouteProjection {
  const RouteProjection(this.along, this.distance);
  final double along, distance;
}

class RouteGeometry {
  RouteGeometry(this.points) {
    for (var i = 1; i < points.length; i++) {
      cumulative.add(cumulative.last + points[i - 1].distanceTo(points[i]));
    }
  }
  final List<Coordinate> points;
  final List<double> cumulative = [0];
  double get length => cumulative.last;
  List<RouteProjection> projections(Coordinate p) {
    const scale = 6371000 * math.pi / 180;
    final cos = math.cos(p.latitude * math.pi / 180);
    final result = <RouteProjection>[];
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      final ax = (a.longitude - p.longitude) * scale * cos,
          ay = (a.latitude - p.latitude) * scale;
      final dx = (b.longitude - a.longitude) * scale * cos,
          dy = (b.latitude - a.latitude) * scale;
      final square = dx * dx + dy * dy;
      if (square < 0.0001) continue;
      final t = (-(ax * dx + ay * dy) / square).clamp(0.0, 1.0);
      result.add(
        RouteProjection(
          cumulative[i - 1] + t * (cumulative[i] - cumulative[i - 1]),
          math.sqrt(math.pow(ax + t * dx, 2) + math.pow(ay + t * dy, 2)),
        ),
      );
    }
    result.sort((a, b) => a.distance.compareTo(b.distance));
    return result;
  }

  double align(Coordinate p, double minimum) {
    final candidates = projections(p)
        .where((c) => c.along >= minimum - 2)
        .toList();
    return candidates.isEmpty
        ? minimum
        : math.max(minimum, candidates.first.along);
  }
}

class ProgressUpdate {
  const ProgressUpdate({
    this.message,
    this.deviated = false,
    this.nearby = false,
    this.uncertain = false,
  });
  final String? message;
  final bool deviated, nearby, uncertain;
}

class RouteProgress {
  RouteProgress(
    this.route,
    this.destination, {
    this.rules = const NavigationRules(),
  }) : geometry = RouteGeometry(route.polyline) {
    var previous = 0.0;
    for (final step in route.steps) {
      final start = step.polyline.isEmpty
          ? previous
          : geometry.align(step.polyline.first, previous);
      starts.add(start);
      previous = start;
    }
    // Providers may prepend an empty, zero-length departure marker.
    while (stepIndex + 1 < route.steps.length &&
        route.steps[stepIndex].instructions.trim().isEmpty &&
        route.steps[stepIndex].notice.trim().isEmpty &&
        starts[stepIndex + 1] - starts[stepIndex] < 1) {
      stepIndex++;
    }
  }
  final WalkingRoute route;
  final Coordinate destination;
  final NavigationRules rules;
  final RouteGeometry geometry;
  final List<double> starts = [];
  final Set<String> _announced = {};
  int stepIndex = 0,
      _nextEvidence = 0,
      _nearEvidence = 0,
      _arrivalEvidence = 0,
      _offEvidence = 0;
  Duration? _offSince, _lastAt, _lastObservation;
  double along = 0;
  double get remaining => math.max(0, geometry.length - along);
  double get nextDistance => math.max(
    0,
    (stepIndex + 1 < starts.length ? starts[stepIndex + 1] : geometry.length) -
        along,
  );
  String _text(int index) {
    final step = route.steps[index];
    final text = step.instructions.trim(), notice = step.notice.trim();
    return '${text.isEmpty ? '沿目前路線前進。' : text}${notice.isEmpty ? '' : ' $notice'}';
  }

  String get instruction => _text(stepIndex);
  void resetEvidence() {
    _nextEvidence = _nearEvidence = _arrivalEvidence = _offEvidence = 0;
    _offSince = null;
  }

  ProgressUpdate update(LocationFix fix, Duration now) {
    if (!fix.usable(now, rules)) {
      resetEvidence();
      return const ProgressUpdate(uncertain: true);
    }
    final observation =
        fix.receivedAt -
        Duration(microseconds: (fix.ageSeconds * 1000000).round());
    if (_lastObservation != null && observation <= _lastObservation!) {
      return const ProgressUpdate(uncertain: true);
    }
    _lastObservation = observation;
    final candidates = geometry.projections(fix.coordinate);
    if (candidates.isEmpty) return const ProgressUpdate(uncertain: true);
    final best = candidates.first;
    if (best.distance > math.max(rules.offRouteMetres, 2 * fix.accuracy)) {
      _nextEvidence = _nearEvidence = _arrivalEvidence = 0;
      _offSince ??= now;
      _offEvidence++;
      return ProgressUpdate(
        deviated: _offEvidence >= 3 && now - _offSince! >= rules.deviationTime,
        uncertain: true,
      );
    }
    _offSince = null;
    _offEvidence = 0;
    final local = candidates
        .where((p) => p.along >= along - 20 && p.along <= along + 120)
        .toList();
    if (local.isEmpty) {
      resetEvidence();
      return const ProgressUpdate(uncertain: true);
    }
    final selected = local.first;
    final ambiguous = candidates.any(
      (p) =>
          (p.along - selected.along).abs() > 40 &&
          p.distance <= selected.distance + 5 &&
          p.distance <= math.max(10, fix.accuracy),
    );
    final elapsed = _lastAt == null
        ? 10.0
        : (now - _lastAt!).inMilliseconds / 1000;
    if (ambiguous || selected.along - along > math.max(30, elapsed * 3)) {
      resetEvidence();
      return const ProgressUpdate(uncertain: true);
    }
    _lastAt = now;
    along = math.max(along, selected.along);
    String? advancedInstruction;
    if (stepIndex + 1 < starts.length &&
        selected.along >= starts[stepIndex + 1] + rules.advanceMetres) {
      if (++_nextEvidence >= 2) {
        stepIndex++;
        _nextEvidence = _nearEvidence = 0;
        advancedInstruction = instruction;
      }
    } else {
      _nextEvidence = 0;
    }
    if (remaining <= rules.arrivalRemaining &&
        fix.coordinate.distanceTo(destination) <= rules.arrivalRadius) {
      if (++_arrivalEvidence >= 2) {
        return const ProgressUpdate(nearby: true, message: '已接近目的地，請確認入口。');
      }
    } else {
      _arrivalEvidence = 0;
    }
    if (advancedInstruction != null) {
      return ProgressUpdate(message: advancedInstruction);
    }
    final next = stepIndex + 1;
    if (next < starts.length) {
      if (nextDistance <= rules.nearNotice &&
          fix.accuracy <= rules.nearAccuracy) {
        if (++_nearEvidence >= 2 && _announced.add('$next:near')) {
          return ProgressUpdate(
            message: '約 ${nextDistance.round()} 米後，${_text(next)}',
          );
        }
      } else {
        _nearEvidence = 0;
      }
      if (nextDistance > rules.nearNotice &&
          nextDistance <= rules.advanceNotice &&
          starts[next] - starts[stepIndex] > rules.advanceNotice &&
          _announced.add('$next:advance')) {
        return ProgressUpdate(
          message: '約 ${nextDistance.round()} 米後，${_text(next)}',
        );
      }
    }
    return const ProgressUpdate();
  }
}
