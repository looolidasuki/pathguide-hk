import 'package:flutter/foundation.dart';

/// N0 synthetic interaction only. No camera, persistence, account or network.
enum RoutePhase {
  idle,
  recording,
  pausedRecording,
  review,
  saved,
  confirming,
  replaying,
  unknown,
  ambiguous,
  pausedReplay,
  arrival,
  finished,
  deleted,
}

enum MockMatch { matched, unknown, ambiguous, wrongDirection }

enum RouteIssue { none, unknown, ambiguous, direction, stale, incompatible }

@immutable
class LandmarkNode {
  const LandmarkNode(this.id, this.nameZh, this.nameEn);
  final String id, nameZh, nameEn;
}

@immutable
class RouteMemory {
  RouteMemory({
    required this.id,
    required this.name,
    required List<LandmarkNode> nodes,
  }) : nodes = List.unmodifiable(nodes);
  final String id, name;
  final List<LandmarkNode> nodes;
  int get version => 1;
  String get direction => 'recorded';
  // Only consecutive, recorded directed links; never inferred reverse edges.
  List<(String, String)> get edges => List.unmodifiable([
    for (var i = 1; i < nodes.length; i++) (nodes[i - 1].id, nodes[i].id),
  ]);
}

@immutable
class ObservationTicket {
  const ObservationTicket({
    required this.session,
    required this.sequence,
    required this.routeId,
    required this.routeVersion,
    required this.capturedAt,
    this.featureRevision = 'synthetic-v1',
    this.direction = 'recorded',
  });
  final int session, sequence, routeVersion;
  final String routeId, featureRevision, direction;
  final DateTime capturedAt;
}

/// Sol-owned lifecycle/transition boundary, deliberately separate from sample graph.
class RouteMemoryController extends ChangeNotifier {
  RouteMemoryController({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final List<RouteMemory> _routes = [];
  final List<LandmarkNode> _draft = [];
  RoutePhase _phase = RoutePhase.idle;
  RouteIssue _issue = RouteIssue.none;
  RouteMemory? _selected;
  bool _startConfirmed = false, _directionConfirmed = false;
  bool _foreground = true, _disposed = false;
  int _session = 0, _sequence = 0, _accepted = 0, _position = 0, _routeId = 0;
  LandmarkNode? _next;

  RoutePhase get phase => _phase;
  RouteIssue get issue => _issue;
  List<RouteMemory> get routes => List.unmodifiable(_routes);
  List<LandmarkNode> get draft => List.unmodifiable(_draft);
  RouteMemory? get selected => _selected;
  bool get startConfirmed => _startConfirmed;
  bool get directionConfirmed => _directionConfirmed;
  bool get foreground => _foreground;
  bool get canStartReplay =>
      !_disposed &&
      _foreground &&
      _phase == RoutePhase.confirming &&
      _selected != null &&
      _startConfirmed &&
      _directionConfirmed;
  LandmarkNode? get nextLandmark =>
      _phase == RoutePhase.replaying ? _next : null;
  int get position => _position;

  void _invalidate() {
    _session++;
    _sequence = _accepted = 0;
    _next = null;
  }

  void _change(RoutePhase phase, {RouteIssue issue = RouteIssue.none}) {
    _phase = phase;
    _issue = issue;
    if (!_disposed) notifyListeners();
  }

  void startRecording() {
    if (_disposed ||
        !_foreground ||
        !{
          RoutePhase.idle,
          RoutePhase.saved,
          RoutePhase.finished,
          RoutePhase.deleted,
        }.contains(_phase)) {
      return;
    }
    _invalidate();
    _draft.clear();
    _selected = null;
    _change(RoutePhase.recording);
  }

  void recordLandmark(LandmarkNode node) {
    if (_disposed ||
        !_foreground ||
        _phase != RoutePhase.recording ||
        node.id.isEmpty ||
        _draft.any((n) => n.id == node.id)) {
      return;
    }
    _draft.add(node);
    notifyListeners();
  }

  void finishRecording() {
    if (_disposed ||
        !_foreground ||
        _phase != RoutePhase.recording ||
        _draft.length < 2) {
      return;
    }
    _invalidate();
    _change(RoutePhase.review);
  }

  void saveRoute(String name) {
    if (_disposed ||
        !_foreground ||
        _phase != RoutePhase.review ||
        name.trim().isEmpty) {
      return;
    }
    final route = RouteMemory(
      id: 'mock-route-${++_routeId}',
      name: name.trim(),
      nodes: _draft,
    );
    _routes.add(route);
    _selected = route;
    _draft.clear();
    _change(RoutePhase.saved);
  }

  void selectRoute(String id) {
    if (_disposed ||
        !_foreground ||
        !{
          RoutePhase.idle,
          RoutePhase.saved,
          RoutePhase.finished,
          RoutePhase.deleted,
        }.contains(_phase)) {
      return;
    }
    final matches = _routes.where((r) => r.id == id);
    if (matches.isEmpty) return;
    _selected = matches.first;
    _invalidate();
    _position = 0;
    _startConfirmed = _directionConfirmed = false;
    _change(RoutePhase.confirming);
  }

  void confirmStart(bool value) {
    if (_disposed || !_foreground || _phase != RoutePhase.confirming) return;
    _startConfirmed = value;
    notifyListeners();
  }

  void confirmDirection(bool value) {
    if (_disposed || !_foreground || _phase != RoutePhase.confirming) return;
    _directionConfirmed = value;
    notifyListeners();
  }

  void startReplay() {
    if (!canStartReplay) return;
    _invalidate();
    _position = 0;
    // This is explicit synthetic start confirmation, never a real location fix.
    _next = _selected!.nodes[1];
    _change(RoutePhase.replaying);
  }

  ObservationTicket? beginObservation() {
    if (_disposed || !_foreground || _phase != RoutePhase.replaying) {
      return null;
    }
    return ObservationTicket(
      session: _session,
      sequence: ++_sequence,
      routeId: _selected!.id,
      routeVersion: _selected!.version,
      capturedAt: _clock(),
    );
  }

  /// A late result from another generation is ignored, including after deletion.
  /// A fresh but invalid observation withdraws the current synthetic instruction.
  void acceptObservation(
    ObservationTicket ticket,
    MockMatch match, {
    String? nodeId,
  }) {
    if (_disposed ||
        !_foreground ||
        _phase != RoutePhase.replaying ||
        ticket.session != _session ||
        ticket.sequence <= _accepted ||
        ticket.sequence > _sequence) {
      return;
    }
    _accepted = ticket.sequence;
    final age = _clock().difference(ticket.capturedAt);
    if (ticket.routeId != _selected!.id ||
        ticket.routeVersion != _selected!.version ||
        ticket.featureRevision != 'synthetic-v1') {
      _withdraw(RouteIssue.incompatible);
    } else if (age.isNegative || age > const Duration(seconds: 15)) {
      _withdraw(RouteIssue.stale);
    } else if (ticket.direction != 'recorded' ||
        match == MockMatch.wrongDirection) {
      _withdraw(RouteIssue.direction);
    } else if (match == MockMatch.unknown) {
      _withdraw(RouteIssue.unknown);
    } else if (match == MockMatch.ambiguous) {
      _withdraw(RouteIssue.ambiguous);
    } else if (nodeId != _next?.id) {
      _withdraw(RouteIssue.unknown);
    } else {
      _position++;
      if (_position == _selected!.nodes.length - 1) {
        _invalidate();
        _change(RoutePhase.arrival);
      } else {
        _next = _selected!.nodes[_position + 1];
        notifyListeners();
      }
    }
  }

  void _withdraw(RouteIssue issue) {
    _invalidate();
    _change(
      issue == RouteIssue.ambiguous ? RoutePhase.ambiguous : RoutePhase.unknown,
      issue: issue,
    );
  }

  void pause() {
    if (_disposed) return;
    if (_phase == RoutePhase.recording) {
      _invalidate();
      _change(RoutePhase.pausedRecording);
    } else if ({
      RoutePhase.replaying,
      RoutePhase.unknown,
      RoutePhase.ambiguous,
      RoutePhase.confirming,
      RoutePhase.arrival,
    }.contains(_phase)) {
      _invalidate();
      _startConfirmed = _directionConfirmed = false;
      _change(RoutePhase.pausedReplay);
    }
  }

  void resumeRecording() {
    if (_disposed || !_foreground || _phase != RoutePhase.pausedRecording) {
      return;
    }
    _invalidate();
    _change(RoutePhase.recording);
  }

  void reconfirm() {
    if (_disposed ||
        !_foreground ||
        _selected == null ||
        !{
          RoutePhase.unknown,
          RoutePhase.ambiguous,
          RoutePhase.pausedReplay,
        }.contains(_phase)) {
      return;
    }
    _invalidate();
    _position = 0;
    _startConfirmed = _directionConfirmed = false;
    _change(RoutePhase.confirming);
  }

  void confirmArrival() {
    if (_disposed || !_foreground || _phase != RoutePhase.arrival) return;
    _invalidate();
    _change(RoutePhase.finished);
  }

  void deleteRoute(String id) {
    if (_disposed || !_foreground || !_routes.any((r) => r.id == id)) return;
    _routes.removeWhere((r) => r.id == id);
    if (_selected?.id == id) {
      _invalidate();
      _selected = null;
      _position = 0;
      _startConfirmed = _directionConfirmed = false;
      _change(RoutePhase.deleted);
    } else {
      notifyListeners();
    }
  }

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    if (!value) pause();
    notifyListeners();
  }

  void stop() {
    if (_disposed) return;
    _invalidate();
    _draft.clear();
    _startConfirmed = _directionConfirmed = false;
    _change(_routes.isEmpty ? RoutePhase.idle : RoutePhase.saved);
  }

  @override
  void dispose() {
    _invalidate();
    _disposed = true;
    super.dispose();
  }
}
