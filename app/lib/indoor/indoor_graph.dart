import 'dart:collection';

String landmarkKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s_\-，。,:：／/（）()]'), '');

class LandmarkObject {
  LandmarkObject({required this.id, required Iterable<String> aliases})
    : aliases = Set.unmodifiable(aliases.map(landmarkKey));
  final String id;
  final Set<String> aliases;
  bool observed(Set<String> keys) =>
      keys.contains(landmarkKey(id)) || keys.intersection(aliases).isNotEmpty;
}

/// Identity is a fixed place. Content and approved name aliases are versioned.
/// This schema deliberately contains no metric coordinates or inferred edges.
class IndoorNode {
  IndoorNode({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.contentVersion,
    required Iterable<LandmarkObject> objects,
  }) : objects = List.unmodifiable(objects);
  final String id, nameZh, nameEn, contentVersion;
  final List<LandmarkObject> objects;
}

class IndoorEdge {
  const IndoorEdge(this.from, this.to, {this.open = true});
  final String from, to;
  final bool open;
}

class IndoorGraph {
  IndoorGraph({
    required this.id,
    required this.version,
    required this.floor,
    required Iterable<IndoorNode> nodes,
    required Iterable<IndoorEdge> edges,
  }) : nodes = Map.unmodifiable({for (final node in nodes) node.id: node}),
       edges = List.unmodifiable(edges) {
    if (this.nodes.isEmpty || this.nodes.length != nodes.length) {
      throw ArgumentError('Nodes must have unique IDs and cannot be empty.');
    }
    final pairs = <String>{};
    for (final node in this.nodes.values) {
      if (node.id.isEmpty ||
          node.contentVersion.isEmpty ||
          node.objects.map((o) => o.id).toSet().length != node.objects.length) {
        throw ArgumentError('Invalid node content.');
      }
      final evidenceKeys = <String>{};
      for (final object in node.objects) {
        final keys = {landmarkKey(object.id), ...object.aliases};
        if (keys.any((key) => key.isEmpty || !evidenceKeys.add(key))) {
          throw ArgumentError(
            'Objects in one node must have distinct evidence keys.',
          );
        }
      }
    }
    for (final edge in this.edges) {
      final pair = [edge.from, edge.to]..sort();
      if (!this.nodes.containsKey(edge.from) ||
          !this.nodes.containsKey(edge.to) ||
          edge.from == edge.to ||
          !pairs.add(pair.join('\u0000'))) {
        throw ArgumentError('Invalid or duplicate edge.');
      }
    }
  }
  final String id, version, floor;
  final Map<String, IndoorNode> nodes;
  final List<IndoorEdge> edges;

  Iterable<String> neighbors(String id) sync* {
    for (final edge in edges) {
      if (!edge.open) continue;
      if (edge.from == id) yield edge.to;
      if (edge.to == id) yield edge.from;
    }
  }

  Set<String> neighborhood(String start, {int hops = 5}) {
    if (!nodes.containsKey(start) || hops < 0) return {};
    final visited = <String>{start};
    var frontier = <String>{start};
    for (var i = 0; i < hops; i++) {
      frontier = {
        for (final node in frontier)
          for (final next in neighbors(node))
            if (!visited.contains(next)) next,
      };
      visited.addAll(frontier);
    }
    return visited;
  }

  /// Fewest open edges, not metres or a guaranteed accessible walking route.
  List<String> route(String start, String destination) {
    if (!nodes.containsKey(start) || !nodes.containsKey(destination)) return [];
    final previous = <String, String?>{start: null};
    final queue = Queue<String>()..add(start);
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      if (current == destination) {
        final path = <String>[];
        String? at = current;
        while (at != null) {
          path.add(at);
          at = previous[at];
        }
        return path.reversed.toList(growable: false);
      }
      for (final next in neighbors(current)) {
        if (previous.containsKey(next)) continue;
        previous[next] = current;
        queue.add(next);
      }
    }
    return [];
  }
}

class LandmarkObservation {
  LandmarkObservation({
    required this.sessionId,
    required this.sequence,
    required this.graphId,
    required this.mapVersion,
    required this.floor,
    required this.capturedAt,
    required Iterable<String> landmarks,
  }) : landmarks = Set.unmodifiable(landmarks.map(landmarkKey));
  final String sessionId, graphId, mapVersion, floor;
  final int sequence;
  final DateTime capturedAt;
  final Set<String> landmarks;
}

enum MatchState {
  matched,
  unknown,
  ambiguous,
  confirming,
  ignored,
  outOfScope,
  expired,
}

class LandmarkMatch {
  const LandmarkMatch(
    this.state, {
    this.nodeId,
    this.candidates = const [],
    this.matchedObjects = 0,
    this.expectedNode,
    this.repeated = false,
    this.relocalized = false,
  });
  final MatchState state;
  final String? nodeId, expectedNode;
  final List<String> candidates;
  final int matchedObjects;
  final bool repeated, relocalized;
}

/// Deterministic replay of annotated evidence. This is not image localization.
/// Unknown observations never create nodes or edit approved map content.
class GraphReplaySession {
  GraphReplaySession({
    required this.graph,
    required this.sessionId,
    required this.destination,
    this.neighborHops = 5,
    this.maxAge = const Duration(seconds: 15),
    this.anchorLifetime = const Duration(seconds: 30),
  }) {
    if (sessionId.trim().isEmpty ||
        !graph.nodes.containsKey(destination) ||
        neighborHops < 0 ||
        maxAge <= Duration.zero ||
        anchorLifetime <= Duration.zero) {
      throw ArgumentError('Invalid replay session configuration.');
    }
  }
  final IndoorGraph graph;
  final String sessionId, destination;
  final int neighborHops;
  final Duration maxAge, anchorLifetime;
  final List<LandmarkObservation> _queue = [];
  List<LandmarkObservation> get observations => List.unmodifiable(_queue);
  String? _currentNode, _lastTrustedNode, _pendingNode;
  String? get currentNode => _currentNode;
  String? get lastTrustedNode => _lastTrustedNode;
  LandmarkMatch get latest => _latest;
  DateTime? _trustedAt, _lastCaptured;
  int _lastSequence = 0;
  bool _hasLocalized = false;
  DateTime? _pendingCaptured;
  LandmarkMatch _latest = const LandmarkMatch(MatchState.unknown);
  List<String> get path =>
      _currentNode == null ? [] : graph.route(_currentNode!, destination);
  String? get expectedNext => path.length > 1 ? path[1] : null;

  LandmarkMatch _unknown(
    MatchState state, {
    List<String> candidates = const [],
  }) {
    _currentNode = null;
    _pendingNode = null;
    _pendingCaptured = null;
    return _latest = LandmarkMatch(
      state,
      candidates: List.unmodifiable(candidates),
    );
  }

  LandmarkMatch observe(
    LandmarkObservation observation, {
    required DateTime receivedAt,
  }) {
    if (observation.sessionId != sessionId || observation.sequence <= 0) {
      return const LandmarkMatch(MatchState.ignored);
    }
    if (!_queue.any((item) => item.sequence == observation.sequence)) {
      _queue.add(observation);
      _queue.sort((a, b) => a.sequence.compareTo(b.sequence));
      if (_queue.length > 50) _queue.removeAt(0);
    }
    if (observation.sequence <= _lastSequence) {
      return const LandmarkMatch(MatchState.ignored);
    }
    _lastSequence = observation.sequence;
    if (observation.graphId != graph.id ||
        observation.mapVersion != graph.version ||
        observation.floor != graph.floor) {
      _lastTrustedNode = null;
      _trustedAt = null;
      return _unknown(MatchState.outOfScope);
    }
    if (receivedAt.difference(observation.capturedAt) > maxAge ||
        observation.capturedAt.isAfter(receivedAt) ||
        (_lastCaptured != null &&
            observation.capturedAt.isBefore(_lastCaptured!))) {
      _lastTrustedNode = null;
      _trustedAt = null;
      return _unknown(MatchState.expired);
    }
    _lastCaptured = observation.capturedAt;
    final expected = expectedNext;
    final counts = <String, int>{
      for (final node in graph.nodes.values)
        node.id: node.objects
            .where((o) => o.observed(observation.landmarks))
            .length,
    };
    final maximum = counts.values.fold<int>(
      0,
      (best, n) => n > best ? n : best,
    );
    if (maximum < 2) return _unknown(MatchState.unknown);
    final best = counts.entries
        .where((e) => e.value == maximum)
        .map((e) => e.key)
        .toList();
    if (best.length != 1) {
      return _unknown(MatchState.ambiguous, candidates: best);
    }
    final node = best.single;
    final freshAnchor =
        _lastTrustedNode != null &&
        _trustedAt != null &&
        receivedAt.difference(_trustedAt!) <= anchorLifetime;
    final nearby =
        freshAnchor &&
        graph
            .neighborhood(_lastTrustedNode!, hops: neighborHops)
            .contains(node);
    // After losing an established position, a global jump requires two
    // consecutive, independently sequenced observations of the same candidate.
    final needsConfirmation = _hasLocalized && !nearby;
    if (needsConfirmation &&
        (_pendingNode != node ||
            _pendingCaptured == null ||
            !observation.capturedAt.isAfter(_pendingCaptured!))) {
      _pendingNode = node;
      _pendingCaptured = observation.capturedAt;
      _currentNode = null;
      return _latest = LandmarkMatch(
        MatchState.confirming,
        candidates: [node],
        matchedObjects: maximum,
      );
    }
    final repeated = _currentNode == node;
    _currentNode = node;
    _lastTrustedNode = node;
    _hasLocalized = true;
    _trustedAt = observation.capturedAt;
    _pendingNode = null;
    _pendingCaptured = null;
    return _latest = LandmarkMatch(
      MatchState.matched,
      nodeId: node,
      candidates: List.unmodifiable(best),
      matchedObjects: maximum,
      expectedNode: expected,
      repeated: repeated,
      relocalized: needsConfirmation,
    );
  }
}
