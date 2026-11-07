import 'package:flutter/foundation.dart';

import 'cross_floor_contract.dart';
import 'route_package.dart' show RouteDocument;

enum RouteMatchState {
  unknown,
  candidate,
  ambiguous,
  wrongFloor,
  wrongDirection,
  wrongNode,
  incompatible,
  stale,
}

class RouteLandmarkIdentity {
  const RouteLandmarkIdentity(
    this.nodeId,
    this.floor,
    this.viewIds, {
    this.exitForConnectors = const [],
  });
  final String nodeId;
  final FloorRef floor;
  final List<String> viewIds, exitForConnectors;
}

class RouteViewDistance {
  const RouteViewDistance(this.nodeId, this.viewId, this.distance);
  final String nodeId, viewId;
  final double distance;
}

class RouteLocalizationTicket {
  RouteLocalizationTicket._(
    this.owner,
    this.generation,
    this.sequence,
    this.capturedAt,
  );
  final RouteLocalizer owner;
  final int generation, sequence;
  final Duration capturedAt;
}

/// Candidate-only engineering profile. Distances are not probabilities and
/// these thresholds do not authorize automatic walking instructions.
class RouteLocalizer extends ChangeNotifier {
  RouteLocalizer({
    required this.routeId,
    required this.routeVersion,
    required List<RouteLandmarkIdentity> landmarks,
    Duration Function()? elapsed,
  }) : landmarks = List.unmodifiable(
         landmarks.map(
           (n) => RouteLandmarkIdentity(
             n.nodeId,
             n.floor,
             List.unmodifiable(n.viewIds),
             exitForConnectors: List.unmodifiable(n.exitForConnectors),
           ),
         ),
       ) {
    final watch = Stopwatch()..start();
    _elapsed = elapsed ?? (() => watch.elapsed);
    if (routeId.isEmpty ||
        routeVersion < 1 ||
        landmarks.isEmpty ||
        landmarks.map((n) => n.nodeId).toSet().length != landmarks.length ||
        landmarks.any(
          (n) =>
              !RouteDocument.validId(n.nodeId) ||
              !RouteDocument.validId(n.floor.id) ||
              !RouteDocument.validId(n.floor.buildingId) ||
              n.floor.label.isEmpty ||
              n.floor.label.length > 40 ||
              n.viewIds.any((id) => !RouteDocument.validId(id)) ||
              n.exitForConnectors.length > 64 ||
              n.exitForConnectors.any((id) => !RouteDocument.validId(id)) ||
              n.exitForConnectors.toSet().length !=
                  n.exitForConnectors.length ||
              n.viewIds.isEmpty ||
              n.viewIds.length > 4 ||
              n.viewIds.toSet().length != n.viewIds.length ||
              n.floor.buildingId != landmarks.first.floor.buildingId,
        ) ||
        landmarks.fold<int>(0, (sum, n) => sum + n.viewIds.length) > 64) {
      throw ArgumentError('Invalid landmarks');
    }
  }
  static const featureRevision = 'vision-featureprint-v1',
      preprocessRevision = 'upright-jpeg-v1';
  static const maxDistance = 8.0, minGap = 2.0, validity = Duration(seconds: 5);
  final String routeId;
  final int routeVersion;
  final List<RouteLandmarkIdentity> landmarks;
  late final Duration Function() _elapsed;
  int _generation = 0, _sequence = 0, _acceptedSequence = 0;
  bool _foreground = true, _disposed = false, _floorConfirmed = false;
  RouteLocalizationTicket? _ticket;
  RouteLandmarkIdentity? _candidate, _actual;
  FloorRef? _expected;
  String? _expectedExit, _expectedConnector;
  RouteMatchState _result = RouteMatchState.unknown;
  bool get _fresh =>
      _ticket != null &&
      _elapsed() >= _ticket!.capturedAt &&
      _elapsed() - _ticket!.capturedAt <= validity;
  RouteMatchState get result =>
      _ticket != null && !_fresh ? RouteMatchState.stale : _result;
  FloorRef? get expectedFloor => _expected;
  FloorRef? get candidateFloor => _fresh ? _candidate?.floor : null;
  FloorRef? get actualFloor => _fresh ? _actual?.floor : null;
  String? get actualNodeId => _fresh ? _actual?.nodeId : null;
  void _clear() {
    _candidate = _actual = null;
    _floorConfirmed = false;
    _result = RouteMatchState.unknown;
  }

  void expectFloor(FloorRef? floor, {String? exitNodeId, String? connectorId}) {
    if (_disposed) return;
    _generation++;
    _ticket = null;
    _expected = null;
    _expectedExit = _expectedConnector = null;
    _clear();
    try {
      if (floor == null) {
        if (exitNodeId != null || connectorId != null) {
          throw ArgumentError('Recovery has no expected connector');
        }
      } else {
        final nodes = landmarks.where((n) => n.nodeId == exitNodeId).toList();
        if (nodes.length != 1 ||
            nodes.single.floor != floor ||
            connectorId == null ||
            !nodes.single.exitForConnectors.contains(connectorId)) {
          throw ArgumentError('Unknown recorded exit/connector');
        }
      }
      _expectedExit = exitNodeId;
      _expectedConnector = connectorId;
      _expected = floor == null
          ? null
          : landmarks.firstWhere((n) => n.floor == floor).floor;
    } finally {
      notifyListeners();
    }
  }

  RouteLocalizationTicket beginObservation({required Duration frameAge}) {
    if (_disposed || !_foreground || frameAge.isNegative) {
      throw StateError('Inactive observation');
    }
    _clear();
    _ticket = RouteLocalizationTicket._(
      this,
      _generation,
      ++_sequence,
      _elapsed() - frameAge,
    );
    notifyListeners();
    return _ticket!;
  }

  void accept(
    RouteLocalizationTicket ticket,
    List<RouteViewDistance> distances, {
    required String feature,
    required String preprocess,
    List<String> ocr = const [],
  }) {
    if (_disposed ||
        !_foreground ||
        !identical(ticket, _ticket) ||
        ticket.owner != this ||
        ticket.generation != _generation ||
        ticket.sequence <= _acceptedSequence) {
      return;
    }
    _acceptedSequence = ticket.sequence;
    _clear();
    if (!_fresh) {
      _result = RouteMatchState.stale;
      notifyListeners();
      return;
    }
    if (feature != featureRevision || preprocess != preprocessRevision) {
      _result = RouteMatchState.incompatible;
      notifyListeners();
      return;
    }
    if (ocr.length > 32 || ocr.any((text) => text.length > 120)) {
      notifyListeners();
      return;
    }
    final expected = {
      for (final n in landmarks)
        for (final v in n.viewIds) '${n.nodeId}/$v',
    };
    final seen = <String>{}, best = <String, double>{};
    for (final d in distances) {
      final key = '${d.nodeId}/${d.viewId}';
      if (!expected.contains(key) ||
          !seen.add(key) ||
          !d.distance.isFinite ||
          d.distance < 0) {
        notifyListeners();
        return;
      }
      final old = best[d.nodeId];
      if (old == null || d.distance < old) best[d.nodeId] = d.distance;
    }
    // A missing rival view cannot manufacture a uniquely matching candidate.
    if (seen.length != expected.length) {
      notifyListeners();
      return;
    }
    final ranked = best.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (ranked.isEmpty || ranked.first.value > maxDistance) {
      notifyListeners();
      return;
    }
    if (ranked.length > 1 && ranked[1].value - ranked.first.value < minGap) {
      _result = RouteMatchState.ambiguous;
      notifyListeners();
      return;
    }
    final node = landmarks.firstWhere((n) => n.nodeId == ranked.first.key);
    String normalize(String s) =>
        s.trim().toUpperCase().replaceAll(RegExp(r'[\s/]'), '');
    final hints = {
      for (final n in landmarks)
        if (ocr.any((text) => normalize(text) == normalize(n.floor.label)))
          n.floor,
    };
    final floorToken = RegExp(
      r'^(?:[BL]?\d{1,2}F|G|GF|UG|LG|M|[0-9一二三四五六七八九十百零]{1,5}樓)$',
    );
    final unfamiliarFloor = ocr
        .map(normalize)
        .any(
          (text) =>
              floorToken.hasMatch(text) &&
              !landmarks.any((n) => normalize(n.floor.label) == text),
        );
    if (unfamiliarFloor) {
      _result = RouteMatchState.ambiguous;
      notifyListeners();
      return;
    }
    if (hints.isNotEmpty &&
        (hints.length != 1 || !hints.contains(node.floor))) {
      _result = RouteMatchState.ambiguous;
      notifyListeners();
      return;
    }
    _candidate = node;
    _result = _expected != null && node.floor != _expected
        ? RouteMatchState.wrongFloor
        : _expectedExit != null && node.nodeId != _expectedExit
        ? RouteMatchState.wrongNode
        : RouteMatchState.candidate;
    notifyListeners();
  }

  bool confirmFloor(FloorRef floor) {
    if (_disposed ||
        !_foreground ||
        !_fresh ||
        _result != RouteMatchState.candidate ||
        _candidate?.floor != floor) {
      return false;
    }
    _floorConfirmed = true;
    notifyListeners();
    return true;
  }

  bool confirmExit({required bool directionConfirmed}) {
    if (_disposed ||
        !_foreground ||
        !_fresh ||
        !_floorConfirmed ||
        _result != RouteMatchState.candidate) {
      return false;
    }
    if (!directionConfirmed) {
      _clear();
      _result = RouteMatchState.wrongDirection;
      notifyListeners();
      return false;
    }
    if (_expected != null &&
        (_candidate?.nodeId != _expectedExit ||
            !_candidate!.exitForConnectors.contains(_expectedConnector))) {
      return false;
    }
    _actual = _candidate;
    notifyListeners();
    return true;
  }

  void pause() {
    if (_disposed) return;
    _generation++;
    _ticket = null;
    _clear();
    notifyListeners();
  }

  void setForeground(bool foreground) {
    if (_disposed) return;
    _foreground = foreground;
    if (!foreground) pause();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _ticket = null;
    _clear();
    super.dispose();
  }
}
