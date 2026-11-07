import 'package:flutter/foundation.dart';

/// P0 synthetic contracts. No sensor, storage, TTS or positioning implementation.
@immutable
class FloorRef {
  const FloorRef(this.buildingId, this.id, this.label);
  final String buildingId, id, label;
  @override
  bool operator ==(Object other) =>
      other is FloorRef && buildingId == other.buildingId && id == other.id;
  @override
  int get hashCode => Object.hash(buildingId, id);
}

@immutable
class FloorNode {
  const FloorNode(this.id, this.floor, this.nameZh, this.nameEn);
  final String id, nameZh, nameEn;
  final FloorRef floor;
}

enum ConnectorMode { walk, elevator, stairs, escalator }

@immutable
class FloorEdge {
  const FloorEdge(this.fromId, this.toId, this.mode, {this.connectorId});
  final String fromId, toId;
  final ConnectorMode mode;
  final String? connectorId;
}

/// One recorded direction, immutable; reverse traversal is never inferred.
class FloorRoute {
  FloorRoute({
    required this.id,
    required this.version,
    required List<FloorNode> nodes,
    required List<FloorEdge> edges,
  }) : nodes = List.unmodifiable(nodes),
       edges = List.unmodifiable(edges) {
    if (id.isEmpty ||
        version < 1 ||
        nodes.length < 2 ||
        edges.length != nodes.length - 1 ||
        nodes.map((n) => n.id).toSet().length != nodes.length) {
      throw ArgumentError('Invalid directed route');
    }
    for (var i = 0; i < edges.length; i++) {
      final edge = edges[i];
      if (edge.fromId != nodes[i].id ||
          edge.toId != nodes[i + 1].id ||
          nodes[i].floor.buildingId != nodes[i + 1].floor.buildingId ||
          (edge.mode == ConnectorMode.walk &&
              nodes[i].floor != nodes[i + 1].floor) ||
          (edge.mode != ConnectorMode.walk &&
              (edge.connectorId == null || edge.connectorId!.isEmpty))) {
        throw ArgumentError('Unconfirmed/cross-floor walk or broken edge');
      }
    }
  }
  final String id;
  final int version;
  final List<FloorNode> nodes;
  final List<FloorEdge> edges;
}

enum FloorPhase {
  idle,
  walkingOnFloor,
  approachingConnector,
  transitioning,
  awaitingFloorConfirmation,
  relocalizingExit,
  unknown,
  paused,
  arrival,
  finished,
  deleted,
}

enum EvidenceChannel { location, perception }

enum FloorMatch { matched, unknown, ambiguous, wrongDirection }

enum PerceptionState { noAlert, object, urgent, unavailable }

enum GuidanceKind { navigation, floorConfirmation, object, critical, hold }

/// A monotonic epoch + generation prevents wall-clock jumps and old callbacks.
@immutable
class FloorObservation {
  const FloorObservation({
    required this.journeyId,
    required this.generation,
    required this.sequence,
    required this.routeId,
    required this.routeVersion,
    required this.clockEpoch,
    required this.capturedAt,
    required this.channel,
    this.featureRevision = 'p0-synthetic-v1',
    this.direction = 'recorded',
  });
  final String journeyId, routeId, clockEpoch, featureRevision, direction;
  final int generation, sequence, routeVersion;
  final Duration capturedAt;
  final EvidenceChannel channel;
}

@immutable
class PerceptionFrame {
  const PerceptionFrame(
    this.ticket,
    this.state, {
    this.objectLabel,
    this.distanceMeters,
    this.depthValid = false,
  });
  final FloorObservation ticket;
  final PerceptionState state;
  final String? objectLabel;
  final double? distanceMeters;
  final bool depthValid;
}

/// Controlled reason codes and parameters; never free-text AI directions.
@immutable
class GuidanceEvent {
  const GuidanceEvent({
    required this.id,
    required this.generation,
    required this.routeVersion,
    required this.kind,
    required this.priority,
    required this.reason,
    required this.expiresAt,
    this.node,
    this.floor,
    this.sourceSequence,
    this.objectLabel,
    this.distanceMeters,
  });
  final String id, reason;
  final int generation, routeVersion, priority;
  final GuidanceKind kind;
  final Duration expiresAt;
  final FloorNode? node;
  final FloorRef? floor;
  final int? sourceSequence;
  final String? objectLabel;
  final double? distanceMeters;
}

/// Sol-owned offline state machine and arbitration. Durations are fixture
/// validity windows, not validated walking latency/safety thresholds.
class CrossFloorController extends ChangeNotifier {
  CrossFloorController({required this.route, Duration Function()? elapsed}) {
    final watch = Stopwatch()..start();
    _elapsed = elapsed ?? (() => watch.elapsed);
  }
  final FloorRoute route;
  late final Duration Function() _elapsed;
  static int _identities = 0;
  final String journeyId = 'p0-${++_identities}';
  final String clockEpoch = UniqueKey().toString();
  static const locationWindow = Duration(seconds: 2);
  static const perceptionWindow = Duration(milliseconds: 500);
  FloorPhase _phase = FloorPhase.idle;
  FloorRef? _actualFloor, _candidateFloor;
  FloorObservation? _exitTicket, _locationTicket;
  PerceptionFrame? _perception;
  int _generation = 0,
      _sequence = 0,
      _locationSequence = 0,
      _perceptionSequence = 0,
      _index = 0,
      _eventSerial = 0;
  bool _foreground = true, _disposed = false;
  String _issue = 'none';
  GuidanceEvent? _guidance;

  FloorPhase get phase => _phase;
  FloorRef? get actualFloor => _actualFloor;
  FloorRef? get candidateFloor => _candidateFloor;
  FloorRef? get expectedFloor =>
      _connector != null && _connector!.mode != ConnectorMode.walk
      ? route.nodes[_index + 1].floor
      : null;
  FloorEdge? get _connector =>
      _index < route.edges.length ? route.edges[_index] : null;
  FloorNode? get nextNode =>
      _phase == FloorPhase.walkingOnFloor && _index + 1 < route.nodes.length
      ? route.nodes[_index + 1]
      : null;
  String get issue => _issue;
  bool get foreground => _foreground;
  int get generation => _generation;
  GuidanceEvent? get guidance => _guidance;
  PerceptionFrame? get currentPerception =>
      _perception != null && _fresh(_perception!.ticket, perceptionWindow)
      ? _perception
      : null;
  bool get canConfirmFloor =>
      _phase == FloorPhase.awaitingFloorConfirmation &&
      _candidateFloor != null &&
      _candidateFloor == expectedFloor &&
      _fresh(_exitTicket, locationWindow);

  bool _fresh(FloorObservation? t, Duration window) =>
      t != null &&
      _elapsed() >= t.capturedAt &&
      _elapsed() - t.capturedAt <= window;

  void _invalidate() {
    _generation++;
    _sequence = _locationSequence = _perceptionSequence = 0;
    _exitTicket = _locationTicket = null;
    _candidateFloor = null;
    _perception = null;
    _guidance = null;
  }

  bool get _active =>
      !_disposed &&
      _foreground &&
      !{
        FloorPhase.idle,
        FloorPhase.paused,
        FloorPhase.deleted,
        FloorPhase.finished,
      }.contains(_phase);

  /// Explicit synthetic start/re-localization, including a confirmed 3F exit.
  /// A real adapter must supply fresh floor/landmark/direction evidence in P3.
  void startAt(
    String nodeId, {
    required bool floorConfirmed,
    required bool directionConfirmed,
  }) {
    if (_disposed ||
        !_foreground ||
        !floorConfirmed ||
        !directionConfirmed ||
        !{
          FloorPhase.idle,
          FloorPhase.paused,
          FloorPhase.unknown,
        }.contains(_phase)) {
      return;
    }
    final index = route.nodes.indexWhere((n) => n.id == nodeId);
    if (index < 0 || index == route.nodes.length - 1) return;
    _invalidate();
    _index = index;
    _actualFloor = route.nodes[index].floor;
    _phase = _connector?.mode == ConnectorMode.walk
        ? FloorPhase.walkingOnFloor
        : FloorPhase.approachingConnector;
    _issue = 'none';
    _locationTicket = observe(EvidenceChannel.location);
    _publish();
  }

  FloorObservation? observe(EvidenceChannel channel) {
    if (!_active) return null;
    return FloorObservation(
      journeyId: journeyId,
      generation: _generation,
      sequence: ++_sequence,
      routeId: route.id,
      routeVersion: route.version,
      clockEpoch: clockEpoch,
      capturedAt: _elapsed(),
      channel: channel,
    );
  }

  bool _accept(FloorObservation t, EvidenceChannel channel) {
    if (!_active ||
        t.journeyId != journeyId ||
        t.generation != _generation ||
        t.channel != channel ||
        t.sequence > _sequence ||
        t.sequence <= 0) {
      return false;
    }
    final previous = channel == EvidenceChannel.location
        ? _locationSequence
        : _perceptionSequence;
    if (t.sequence <= previous) return false;
    if (channel == EvidenceChannel.location) {
      _locationSequence = t.sequence;
    } else {
      _perceptionSequence = t.sequence;
    }
    if (t.routeId != route.id ||
        t.routeVersion != route.version ||
        t.clockEpoch != clockEpoch ||
        t.featureRevision != 'p0-synthetic-v1' ||
        t.direction != 'recorded' ||
        !_fresh(
          t,
          channel == EvidenceChannel.location
              ? locationWindow
              : perceptionWindow,
        )) {
      if (channel == EvidenceChannel.location) {
        _unknown('invalidLocation');
      } else {
        _perception = null;
        _publish();
      }
      return false;
    }
    return true;
  }

  void match(
    FloorObservation ticket,
    FloorMatch result, {
    String? nodeId,
    FloorRef? floor,
  }) {
    if (!_accept(ticket, EvidenceChannel.location)) return;
    if (result != FloorMatch.matched) {
      _unknown(result.name);
      return;
    }
    if (_phase != FloorPhase.walkingOnFloor ||
        nodeId != nextNode?.id ||
        floor != _actualFloor ||
        floor != nextNode?.floor) {
      _unknown('wrongNodeOrFloor');
      return;
    }
    _index++;
    _locationTicket = ticket;
    _issue = 'none';
    if (_index == route.nodes.length - 1) {
      _phase = FloorPhase.arrival;
    } else if (_connector?.mode != ConnectorMode.walk) {
      _phase = FloorPhase.approachingConnector;
    }
    _publish();
  }

  void enterConnector() {
    if (!_active ||
        _phase != FloorPhase.approachingConnector ||
        !_fresh(_locationTicket, locationWindow)) {
      return;
    }
    // No old floor instructions survive entering the elevator/staircase.
    _invalidate();
    _actualFloor = null;
    _phase = FloorPhase.transitioning;
    _publish();
  }

  /// OCR/altitude alone must never invoke this as a confirmed floor.
  void proposeExit(
    FloorObservation ticket,
    FloorRef? floor, {
    bool ambiguous = false,
  }) {
    if (!_active ||
        !{
          FloorPhase.transitioning,
          FloorPhase.awaitingFloorConfirmation,
        }.contains(_phase)) {
      return;
    }
    if (!_accept(ticket, EvidenceChannel.location)) return;
    _phase = FloorPhase.awaitingFloorConfirmation;
    _actualFloor = null;
    _candidateFloor = ambiguous ? null : floor;
    _exitTicket = ticket;
    _issue = ambiguous
        ? 'ambiguousExit'
        : floor == expectedFloor
        ? 'confirmFloor'
        : 'wrongFloor';
    _publish();
  }

  void confirmFloor() {
    if (!_active || !canConfirmFloor) return;
    _phase = FloorPhase.relocalizingExit;
    _issue = 'confirmExitAndDirection';
    // Expected floor is still not actual until fresh landmark + direction.
    _publish();
  }

  void confirmExit(
    FloorObservation ticket, {
    required String nodeId,
    required FloorRef floor,
    required bool directionConfirmed,
    bool ambiguous = false,
  }) {
    if (!_active || _phase != FloorPhase.relocalizingExit) return;
    if (!_accept(ticket, EvidenceChannel.location)) return;
    if (ambiguous ||
        !directionConfirmed ||
        floor != expectedFloor ||
        floor != _candidateFloor ||
        nodeId != route.nodes[_index + 1].id ||
        !_fresh(_exitTicket, locationWindow)) {
      _unknown(ambiguous ? 'ambiguousExit' : 'wrongExitOrDirection');
      return;
    }
    _index++;
    _actualFloor = floor;
    _locationTicket = ticket;
    _exitTicket = null;
    _candidateFloor = null;
    _issue = 'none';
    _phase = _index == route.nodes.length - 1
        ? FloorPhase.arrival
        : _connector?.mode == ConnectorMode.walk
        ? FloorPhase.walkingOnFloor
        : FloorPhase.approachingConnector;
    _publish();
  }

  void perceive(PerceptionFrame frame) {
    if (!_accept(frame.ticket, EvidenceChannel.perception)) return;
    final d = frame.distanceMeters;
    if (d != null && (!frame.depthValid || !d.isFinite || d <= 0)) {
      _perception = null;
    } else {
      _perception = frame;
    }
    _publish();
  }

  void _unknown(String reason) {
    _invalidate();
    _actualFloor = null;
    _phase = FloorPhase.unknown;
    _issue = reason;
    _publish();
  }

  void pause() {
    if (_disposed ||
        {
          FloorPhase.idle,
          FloorPhase.deleted,
          FloorPhase.finished,
          FloorPhase.paused,
        }.contains(_phase)) {
      return;
    }
    _invalidate();
    _actualFloor = null;
    _phase = FloorPhase.paused;
    _issue = 'manualReconfirmationRequired';
    _publish();
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) pause();
    // Refresh enabled controls on return, without resuming the journey.
    _publish();
  }

  void deleteRoute() {
    if (_disposed) return;
    _invalidate();
    _actualFloor = null;
    _phase = FloorPhase.deleted;
    _publish();
  }

  void confirmArrival() {
    if (!_active ||
        _phase != FloorPhase.arrival ||
        !_fresh(_locationTicket, locationWindow)) {
      return;
    }
    _invalidate();
    _phase = FloorPhase.finished;
    _publish();
  }

  /// The UI timer only expires mock state; never grants a floor or arrival.
  void refresh() {
    if (_active) _publish();
  }

  void _publish() {
    if (_disposed) return;
    GuidanceKind kind = GuidanceKind.hold;
    var reason = _phase.name;
    var priority = 2;
    FloorNode? node;
    FloorRef? floor;
    PerceptionFrame? source;
    if (_active) {
      if (_perception == null ||
          !_fresh(_perception!.ticket, perceptionWindow) ||
          _perception!.state == PerceptionState.unavailable) {
        kind = GuidanceKind.critical;
        reason = 'perceptionUnavailable';
        priority = 3;
      } else if (_perception!.state == PerceptionState.urgent) {
        source = _perception;
        kind = GuidanceKind.critical;
        reason = 'syntheticObstacle';
        priority = 3;
      } else if (_phase == FloorPhase.walkingOnFloor &&
          _fresh(_locationTicket, locationWindow)) {
        kind = GuidanceKind.navigation;
        reason = 'nextLandmark';
        node = nextNode;
        floor = _actualFloor;
      } else if ({
        FloorPhase.approachingConnector,
        FloorPhase.transitioning,
        FloorPhase.awaitingFloorConfirmation,
        FloorPhase.relocalizingExit,
      }.contains(_phase)) {
        kind = GuidanceKind.floorConfirmation;
        reason = _phase == FloorPhase.awaitingFloorConfirmation
            ? _issue
            : _phase.name;
        floor = expectedFloor;
      } else if (_phase == FloorPhase.walkingOnFloor) {
        reason = 'locationExpired';
      }
      // Object descriptions have lower priority and cannot replace a route cue.
      if (kind == GuidanceKind.hold &&
          _phase == FloorPhase.arrival &&
          _fresh(_locationTicket, locationWindow)) {
        reason = 'confirmArrival';
      }
    }
    final key =
        '$kind/$reason/${node?.id}/${floor?.id}/'
        '${source?.objectLabel}/${source?.distanceMeters}/$_generation';
    final old = _guidance;
    final oldKey = old == null
        ? null
        : '${old.kind}/${old.reason}/${old.node?.id}/'
              '${old.floor?.id}/${old.objectLabel}/${old.distanceMeters}/${old.generation}';
    _guidance = GuidanceEvent(
      id: key == oldKey ? old!.id : '$journeyId-${++_eventSerial}',
      generation: _generation,
      routeVersion: route.version,
      kind: kind,
      priority: priority,
      reason: reason,
      expiresAt: _elapsed() + perceptionWindow,
      node: node,
      floor: floor,
      sourceSequence: source?.ticket.sequence ?? _locationTicket?.sequence,
      objectLabel: source?.objectLabel,
      distanceMeters: source?.distanceMeters,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _invalidate();
    _disposed = true;
    super.dispose();
  }
}
